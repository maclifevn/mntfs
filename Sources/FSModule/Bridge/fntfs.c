/*
 * fntfs.c — FastNTFS bridge implementation over libntfs-3g.
 *
 * Threading model: one big lock per volume. libntfs-3g is not thread-safe;
 * every public entry point takes the volume mutex. Device callbacks are only
 * invoked with the mutex held.
 *
 * Inode instance discipline: at most one open ntfs_inode exists per MFT
 * record at any time. Regular-file inodes used for I/O live in a small cache
 * (with their $DATA attribute kept open); every other operation opens and
 * closes inodes within the call. Before any namespace operation (remove,
 * rename, truncate-via-fresh-handle) the cache entry is evicted.
 */

#include "fntfs.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/stat.h>
#include <unistd.h>

#include "types.h"
#include "device.h"
#include "volume.h"
#include "inode.h"
#include "dir.h"
#include "attrib.h"
#include "unistr.h"
#include "ntfstime.h"
#include "layout.h"
#include "logfile.h"

/*
 * Ghost names: temporary directory entries the bridge creates for two jobs —
 * parking the target of an overwrite-rename until the move succeeds
 * (".mntfs-mv-…"), and keeping deleted-but-still-open files alive
 * (".mntfs-del-…"). "del" ghosts are invisible to fntfs_readdir; both kinds
 * are swept from the root directory on the next read-write mount, so a crash
 * can't leak them forever.
 */
#define GHOST_MV_PREFIX  ".mntfs-mv-"
#define GHOST_DEL_PREFIX ".mntfs-del-"

/* ---------------------------------------------------------------- device */

typedef struct {
    void           *swift_ctx;
    fntfs_pread_cb  pread_cb;
    fntfs_pwrite_cb pwrite_cb;
    fntfs_flush_cb  flush_cb;
    int64_t         size;      /* device size, bytes  */
    uint32_t        sector;    /* alignment unit      */
    int64_t         pos;       /* for seek/read/write */
    bool            readonly;
} fntfs_dev_ctx;

/* Cap on any single bounce allocation used for unaligned I/O. A multiple of
   both common sector sizes (512, 4096); large unaligned requests are processed
   in chunks of this size instead of one giant malloc. */
enum { BOUNCE_CHUNK = 1 << 20 };   /* 1 MiB */

static int64_t dev_pread_aligned(fntfs_dev_ctx *c, void *buf, int64_t count,
                                 int64_t offset)
{
    if (offset < 0 || count < 0) return -EINVAL;
    if (offset >= c->size) return 0;
    if (count > c->size - offset) count = c->size - offset;   /* overflow-safe */
    if (count == 0) return 0;

    const uint32_t ss = c->sector;
    if ((offset % ss) == 0 && (count % ss) == 0)
        return c->pread_cb(c->swift_ctx, buf, count, offset);

    /* Unaligned: bounce through a size-capped aligned buffer, chunk by chunk.
       The aligned span covers only the remaining request (rounded to sectors),
       so a tiny unaligned read costs one sector of I/O, not a whole chunk. */
    char *tmp = malloc(BOUNCE_CHUNK);
    if (!tmp) return -ENOMEM;
    int64_t done = 0;
    while (done < count) {
        int64_t o = offset + done;
        int64_t astart = (o / ss) * ss;                 /* align down */
        int64_t alen = ((o - astart) + (count - done) + ss - 1) / ss * ss;
        if (alen > BOUNCE_CHUNK) alen = BOUNCE_CHUNK;    /* ss divides 1 MiB */
        if (astart + alen > c->size) alen = c->size - astart;
        int64_t r = c->pread_cb(c->swift_ctx, tmp, alen, astart);
        if (r < 0) { free(tmp); return done ? done : r; }
        int64_t skip = o - astart;                       /* 0 .. ss-1 */
        int64_t avail = r - skip;
        if (avail <= 0) break;                            /* short read / EOF */
        int64_t chunk = count - done;
        if (chunk > avail) chunk = avail;
        memcpy((char *)buf + done, tmp + skip, (size_t)chunk);
        done += chunk;
        if (r < alen) break;                              /* EOF inside span */
    }
    free(tmp);
    return done;
}

static int64_t dev_pwrite_aligned(fntfs_dev_ctx *c, const void *buf,
                                  int64_t count, int64_t offset)
{
    if (c->readonly || !c->pwrite_cb) return -EROFS;
    if (offset < 0 || count < 0) return -EINVAL;
    if (offset >= c->size || count > c->size - offset) return -EIO;  /* overflow-safe */
    if (count == 0) return 0;

    const uint32_t ss = c->sector;
    if ((offset % ss) == 0 && (count % ss) == 0)
        return c->pwrite_cb(c->swift_ctx, buf, count, offset);

    /* Unaligned: read-modify-write the aligned span that covers the remaining
       request (capped at BOUNCE_CHUNK per pass), so a tiny unaligned write
       costs one sector of read-modify-write, not a whole chunk. */
    char *tmp = malloc(BOUNCE_CHUNK);
    if (!tmp) return -ENOMEM;
    int64_t done = 0;
    while (done < count) {
        int64_t o = offset + done;
        int64_t astart = (o / ss) * ss;
        int64_t alen = ((o - astart) + (count - done) + ss - 1) / ss * ss;
        if (alen > BOUNCE_CHUNK) alen = BOUNCE_CHUNK;    /* ss divides 1 MiB */
        if (astart + alen > c->size) alen = c->size - astart;
        int64_t skip = o - astart;
        int64_t chunk = count - done;
        if (chunk > alen - skip) chunk = alen - skip;
        int64_t r = c->pread_cb(c->swift_ctx, tmp, alen, astart);
        if (r < alen) { free(tmp); return done ? done : (r < 0 ? r : -EIO); }
        memcpy(tmp + skip, (const char *)buf + done, (size_t)chunk);
        int64_t w = c->pwrite_cb(c->swift_ctx, tmp, alen, astart);
        if (w < alen) { free(tmp); return done ? done : (w < 0 ? w : -EIO); }
        done += chunk;
    }
    free(tmp);
    return done;
}

/* errno-style adapters for ntfs_device_operations */

static int fdev_open(struct ntfs_device *dev, int flags)
{
    fntfs_dev_ctx *c = dev->d_private;
    if (((flags & O_ACCMODE) != O_RDONLY) && c->readonly) {
        errno = EROFS;
        return -1;
    }
    if ((flags & O_ACCMODE) == O_RDONLY)
        NDevSetReadOnly(dev);
    NDevSetBlock(dev);
    NDevSetOpen(dev);
    return 0;
}

static int fdev_close(struct ntfs_device *dev)
{
    NDevClearOpen(dev);
    return 0;
}

static s64 fdev_seek(struct ntfs_device *dev, s64 offset, int whence)
{
    fntfs_dev_ctx *c = dev->d_private;
    s64 npos;
    switch (whence) {
    case SEEK_SET: npos = offset; break;
    case SEEK_CUR: npos = c->pos + offset; break;
    case SEEK_END: npos = c->size + offset; break;
    default: errno = EINVAL; return -1;
    }
    if (npos < 0) { errno = EINVAL; return -1; }
    c->pos = npos;
    return npos;
}

static s64 fdev_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset)
{
    int64_t r = dev_pread_aligned(dev->d_private, buf, count, offset);
    if (r < 0) { errno = (int)-r; return -1; }
    return r;
}

static s64 fdev_pwrite(struct ntfs_device *dev, const void *buf, s64 count,
                       s64 offset)
{
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    int64_t r = dev_pwrite_aligned(dev->d_private, buf, count, offset);
    if (r < 0) { errno = (int)-r; return -1; }
    NDevSetDirty(dev);
    return r;
}

static s64 fdev_read(struct ntfs_device *dev, void *buf, s64 count)
{
    fntfs_dev_ctx *c = dev->d_private;
    s64 r = fdev_pread(dev, buf, count, c->pos);
    if (r > 0) c->pos += r;
    return r;
}

static s64 fdev_write(struct ntfs_device *dev, const void *buf, s64 count)
{
    fntfs_dev_ctx *c = dev->d_private;
    s64 r = fdev_pwrite(dev, buf, count, c->pos);
    if (r > 0) c->pos += r;
    return r;
}

static int fdev_sync(struct ntfs_device *dev)
{
    fntfs_dev_ctx *c = dev->d_private;
    if (c->flush_cb) {
        int r = c->flush_cb(c->swift_ctx);
        if (r < 0) { errno = -r; return -1; }
    }
    NDevClearDirty(dev);
    return 0;
}

static int fdev_stat(struct ntfs_device *dev, struct stat *buf)
{
    fntfs_dev_ctx *c = dev->d_private;
    memset(buf, 0, sizeof(*buf));
    buf->st_mode = S_IFBLK;
    buf->st_size = c->size;
    return 0;
}

static int fdev_ioctl(struct ntfs_device *dev, unsigned long request, void *argp)
{
    fntfs_dev_ctx *c = dev->d_private;
    switch (request) {
    case DKIOCGETBLOCKSIZE:
        *(uint32_t *)argp = c->sector;
        return 0;
    case DKIOCGETBLOCKCOUNT:
        *(uint64_t *)argp = (uint64_t)c->size / c->sector;
        return 0;
    default:
        errno = ENOTTY;
        return -1;
    }
}

static struct ntfs_device_operations fntfs_dops = {
    .open   = fdev_open,
    .close  = fdev_close,
    .seek   = fdev_seek,
    .read   = fdev_read,
    .write  = fdev_write,
    .pread  = fdev_pread,
    .pwrite = fdev_pwrite,
    .sync   = fdev_sync,
    .stat   = fdev_stat,
    .ioctl  = fdev_ioctl,
};

/* ---------------------------------------------------------------- volume */

#define FCACHE_SIZE 8

typedef struct {
    uint64_t    inum;   /* 0 == empty slot */
    ntfs_inode *ni;
    ntfs_attr  *na;     /* unnamed $DATA */
    uint64_t    stamp;  /* LRU clock */
} fcache_ent;

struct fntfs_vol {
    ntfs_volume       *vol;
    struct ntfs_device *dev;
    fntfs_dev_ctx      devctx;
    pthread_mutex_t    lock;
    fcache_ent         cache[FCACHE_SIZE];
    uint64_t           clock;
};

#define LOCK(v)   pthread_mutex_lock(&(v)->lock)
#define UNLOCK(v) pthread_mutex_unlock(&(v)->lock)

uint64_t fntfs_root_inum(void) { return FILE_root; }

/* --- open-file cache ---------------------------------------------------- */

/* Returns 0, or -errno if the entry's dirty state failed to reach the disk.
   The slot is emptied either way (the handles are gone), but the caller must
   surface the error instead of silently losing data. */
static int fcache_drop_ent(fcache_ent *e)
{
    if (!e->inum) return 0;
    int err = 0;
    if (e->ni && ntfs_inode_sync(e->ni))
        err = -errno;
    if (e->na) ntfs_attr_close(e->na);
    if (e->ni && ntfs_inode_close(e->ni) && !err)
        err = -errno;
    e->inum = 0; e->ni = NULL; e->na = NULL;
    return err;
}

static int fcache_drop(fntfs_vol *v, uint64_t inum)
{
    int err = 0;
    for (int i = 0; i < FCACHE_SIZE; i++)
        if (v->cache[i].inum == inum) {
            int r = fcache_drop_ent(&v->cache[i]);
            if (r && !err) err = r;
        }
    return err;
}

static int fcache_drop_all(fntfs_vol *v)
{
    int err = 0;
    for (int i = 0; i < FCACHE_SIZE; i++) {
        int r = fcache_drop_ent(&v->cache[i]);
        if (r && !err) err = r;
    }
    return err;
}

/* Get an open (ni, na) pair for a regular file, from cache or fresh. */
static int fcache_get(fntfs_vol *v, uint64_t inum, ntfs_inode **nip,
                      ntfs_attr **nap)
{
    for (int i = 0; i < FCACHE_SIZE; i++) {
        if (v->cache[i].inum == inum) {
            v->cache[i].stamp = ++v->clock;
            *nip = v->cache[i].ni;
            *nap = v->cache[i].na;
            return 0;
        }
    }
    ntfs_inode *ni = ntfs_inode_open(v->vol, MK_MREF(inum, 0));
    if (!ni) return -errno;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        int e = errno;
        ntfs_inode_close(ni);
        return -e;
    }
    /* Evict LRU. If the victim's dirty state can't be flushed, fail this
       operation rather than silently dropping the victim's data. */
    int victim = 0;
    for (int i = 1; i < FCACHE_SIZE; i++) {
        if (!v->cache[i].inum) { victim = i; break; }
        if (v->cache[i].stamp < v->cache[victim].stamp) victim = i;
    }
    int derr = fcache_drop_ent(&v->cache[victim]);
    if (derr) {
        ntfs_attr_close(na);
        ntfs_inode_close(ni);
        return derr;
    }
    v->cache[victim] = (fcache_ent){ inum, ni, na, ++v->clock };
    *nip = ni;
    *nap = na;
    return 0;
}

/*
 * Open an inode for a metadata operation. If the file is in the I/O cache,
 * reuse that instance (never two ntfs_inode for one MFT record); the caller
 * must then NOT close it. Sets *cached accordingly.
 */
static ntfs_inode *inode_get(fntfs_vol *v, uint64_t inum, bool *cached)
{
    for (int i = 0; i < FCACHE_SIZE; i++) {
        if (v->cache[i].inum == inum) {
            *cached = true;
            return v->cache[i].ni;
        }
    }
    *cached = false;
    return ntfs_inode_open(v->vol, MK_MREF(inum, 0));
}

static void inode_put(ntfs_inode *ni, bool cached)
{
    if (!cached && ni)
        ntfs_inode_close(ni);
}

/* --- attrs --------------------------------------------------------------- */

static void set_ts(int64_t *sec, int32_t *nsec, ntfs_time t)
{
    struct timespec ts = ntfs2timespec(t);
    *sec = ts.tv_sec;
    *nsec = (int32_t)ts.tv_nsec;
}

static void fill_attrs(ntfs_inode *ni, fntfs_attrs *out)
{
    memset(out, 0, sizeof(*out));
    out->inum = ni->mft_no;
    bool isdir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != 0;
    out->type = isdir ? FNTFS_TYPE_DIR : FNTFS_TYPE_FILE;
    out->nlink = le16_to_cpu(ni->mrec->link_count);
    if (!isdir) {
        out->size = (uint64_t)ni->data_size;
        out->alloc_size = (uint64_t)ni->allocated_size;
    }
    uint32_t fl = le32_to_cpu(ni->flags);
    if (fl & 0x0001) out->win_attrs |= FNTFS_WINATTR_READONLY;
    if (fl & 0x0002) out->win_attrs |= FNTFS_WINATTR_HIDDEN;
    if (fl & 0x0004) out->win_attrs |= FNTFS_WINATTR_SYSTEM;
    set_ts(&out->crtime_sec, &out->crtime_nsec, ni->creation_time);
    set_ts(&out->mtime_sec, &out->mtime_nsec, ni->last_data_change_time);
    set_ts(&out->ctime_sec, &out->ctime_nsec, ni->last_mft_change_time);
    set_ts(&out->atime_sec, &out->atime_nsec, ni->last_access_time);
}

/* --- probe / mount ------------------------------------------------------- */

static void ghost_name(char *out, size_t cap, const char *prefix,
                       uint64_t inum)
{
    static unsigned long seq;   /* under the volume lock in every caller */
    snprintf(out, cap, "%s%08lx-%llx", prefix, ++seq,
             (unsigned long long)inum);
}

/*
 * The mount ignored hiberfil.sys (Fast Startup / hibernation image). Writing
 * while a valid image survives would let Windows resume from stale metadata
 * and corrupt everything we changed, so on a read-write mount the image is
 * deleted — the same policy as ntfs-3g's `remove_hiberfile` option. Windows
 * then simply performs a full boot next time.
 */
static void drop_hibernation_image(ntfs_volume *vol)
{
    if (!ntfs_volume_check_hiberfile(vol, 0))
        return;                 /* absent, or no valid image */
    if (errno != EPERM)
        return;                 /* unreadable: leave it alone */
    ntfs_inode *ni = ntfs_pathname_to_inode(vol, NULL, "hiberfil.sys");
    if (!ni)
        return;
    ntfschar *uname = NULL;
    int ulen = ntfs_mbstoucs("hiberfil.sys", &uname);
    ntfs_inode *root = ntfs_inode_open(vol, FILE_root);
    if (ulen > 0 && root) {
        /* ntfs_delete closes both inodes, success or failure. */
        if (!ntfs_delete(vol, NULL, ni, root, uname, (u8)ulen))
            ntfs_log_info("MNtfs: removed hibernation image hiberfil.sys\n");
    } else {
        ntfs_inode_close(ni);
        if (root)
            ntfs_inode_close(root);
    }
    free(uname);
}

/* Collect leftover ghost entries in the root directory. */
typedef struct {
    char     names[128][64];
    uint64_t inums[128];
    int      n;
} sweep_list;

static int sweep_filldir(void *ctxp, const ntfschar *name, const int name_len,
                         const int name_type, const s64 pos,
                         const MFT_REF mref, const unsigned dt_type)
{
    sweep_list *sl = ctxp;
    (void)pos; (void)dt_type;
    if (name_type == FILE_NAME_DOS || sl->n >= 128)
        return 0;
    char *utf8 = NULL;
    if (ntfs_ucstombs(name, name_len, &utf8, 0) < 0)
        return 0;
    if (!strncmp(utf8, GHOST_DEL_PREFIX, strlen(GHOST_DEL_PREFIX)) ||
        !strncmp(utf8, GHOST_MV_PREFIX, strlen(GHOST_MV_PREFIX))) {
        snprintf(sl->names[sl->n], sizeof(sl->names[0]), "%s", utf8);
        sl->inums[sl->n] = MREF(mref);
        sl->n++;
    }
    free(utf8);
    return 0;
}

/* Delete ghost entries a previous crashed/killed instance left behind. */
static void sweep_ghosts(fntfs_vol *v)
{
    sweep_list sl = { .n = 0 };
    ntfs_inode *root = ntfs_inode_open(v->vol, FILE_root);
    if (!root)
        return;
    s64 pos = 0;
    ntfs_readdir(root, &pos, &sl, sweep_filldir);
    ntfs_inode_close(root);
    for (int i = 0; i < sl.n; i++)
        fntfs_remove(v, FILE_root, sl.names[i], sl.inums[i]);
    if (sl.n)
        ntfs_log_info("MNtfs: swept %d leftover ghost entr%s\n", sl.n,
                      sl.n == 1 ? "y" : "ies");
}

static bool boot_sector_is_ntfs(void *ctx, fntfs_pread_cb pread_cb,
                                uint32_t sector, uint64_t *serial_out)
{
    size_t blen = sector > 512 ? sector : 512;
    char *b = calloc(1, blen);
    if (!b) return false;
    fntfs_dev_ctx tmp = { .swift_ctx = ctx, .pread_cb = pread_cb,
                          .size = (int64_t)blen, .sector = sector };
    bool ok = false;
    if (dev_pread_aligned(&tmp, b, (int64_t)blen, 0) >= 512 &&
        memcmp(b + 3, "NTFS    ", 8) == 0) {
        memcpy(serial_out, b + 0x48, 8);
        ok = true;
    }
    free(b);
    return ok;
}

int fntfs_probe(void *ctx, fntfs_pread_cb pread_cb, uint64_t dev_size,
                uint32_t sector_size, char *name_out, uint64_t *serial_out)
{
    name_out[0] = '\0';
    *serial_out = 0;

    if (!boot_sector_is_ntfs(ctx, pread_cb, sector_size, serial_out))
        return FNTFS_PROBE_UNRECOGNIZED;

    /* Try a real read-only mount to fetch the label and validate state. */
    int err = 0;
    fntfs_vol *v = fntfs_mount(ctx, pread_cb, NULL, NULL, dev_size,
                               sector_size, true, name_out, serial_out, &err);
    if (!v)
        return FNTFS_PROBE_RECOGNIZED;
    fntfs_unmount(v);
    return FNTFS_PROBE_USABLE;
}

fntfs_vol *fntfs_mount(void *ctx, fntfs_pread_cb pread_cb,
                       fntfs_pwrite_cb pwrite_cb, fntfs_flush_cb flush_cb,
                       uint64_t dev_size, uint32_t sector_size, bool readonly,
                       char *name_out, uint64_t *serial_out, int *err_out)
{
    *err_out = 0;
    if (!readonly && !pwrite_cb) { *err_out = EINVAL; return NULL; }

    fntfs_vol *v = calloc(1, sizeof(*v));
    if (!v) { *err_out = ENOMEM; return NULL; }
    /* Recursive: FSKit's directory enumeration calls back into fntfs_getattr
       from inside the fntfs_readdir packer callback, on the same thread. */
    pthread_mutexattr_t mattr;
    pthread_mutexattr_init(&mattr);
    pthread_mutexattr_settype(&mattr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&v->lock, &mattr);
    pthread_mutexattr_destroy(&mattr);
    v->devctx = (fntfs_dev_ctx){
        .swift_ctx = ctx,
        .pread_cb = pread_cb,
        .pwrite_cb = pwrite_cb,
        .flush_cb = flush_cb,
        .size = (int64_t)dev_size,
        .sector = sector_size ? sector_size : 512,
        .readonly = readonly,
    };
    v->dev = ntfs_device_alloc("fastntfs", 0, &fntfs_dops, &v->devctx);
    if (!v->dev) {
        *err_out = ENOMEM;
        pthread_mutex_destroy(&v->lock);
        free(v);
        return NULL;
    }

    ntfs_mount_flags flags = 0;
    if (readonly)
        flags |= NTFS_MNT_RDONLY;
    else
        /* RECOVER replays a dirty $LogFile. IGNORE_HIBERFILE mounts read-write
           even when Windows left a hiberfil.sys behind — which is the norm with
           Fast Startup / hybrid shutdown (Windows 10/11 default) and otherwise
           makes ntfs-3g refuse the mount entirely ("failed to mount"). */
        flags |= NTFS_MNT_RECOVER | NTFS_MNT_IGNORE_HIBERFILE;

    v->vol = ntfs_device_mount(v->dev, flags);
    if (!v->vol) {
        *err_out = errno ? errno : EIO;
        ntfs_device_free(v->dev);
        pthread_mutex_destroy(&v->lock);
        free(v);
        return NULL;
    }

    NVolSetShowHidFiles(v->vol);            /* surface hidden files      */
    NVolClearShowSysFiles(v->vol);          /* hide $MFT & co. (default on!) */

    /* Honour the case-insensitive/case-preserving contract the FSKit layer
       advertises: fold case in lookups exactly like Windows does. Failure
       (allocation only) degrades to case-sensitive lookups; not fatal. */
    ntfs_set_ignore_case(v->vol);

    if (!readonly) {
        drop_hibernation_image(v->vol);
        sweep_ghosts(v);
    }
    ntfs_volume_get_free_space(v->vol);     /* prime free-cluster count  */

    if (name_out) {
        name_out[0] = '\0';
        if (v->vol->vol_name)
            snprintf(name_out, 256, "%s", v->vol->vol_name);
    }
    if (serial_out) {
        *serial_out = 0;
        char bs[512];
        if (dev_pread_aligned(&v->devctx, bs, sizeof(bs), 0) == sizeof(bs))
            memcpy(serial_out, bs + 0x48, 8);
    }
    return v;
}

static int sync_all_locked(fntfs_vol *v)
{
    int err = 0;
    for (int i = 0; i < FCACHE_SIZE; i++)
        if (v->cache[i].inum && ntfs_inode_sync(v->cache[i].ni) && !err)
            err = -errno;
    if (v->dev->d_ops->sync(v->dev) && !err)
        err = -errno;
    return err;
}

int fntfs_sync(fntfs_vol *v)
{
    LOCK(v);
    int err = sync_all_locked(v);
    UNLOCK(v);
    return err;
}

int fntfs_unmount(fntfs_vol *v)
{
    LOCK(v);
    int err = fcache_drop_all(v);
    if (ntfs_umount(v->vol, FALSE) && !err)   /* also frees the device */
        err = -errno;
    v->vol = NULL;
    UNLOCK(v);
    pthread_mutex_destroy(&v->lock);
    free(v);
    return err;
}

int fntfs_statfs(fntfs_vol *v, fntfs_statfs_t *out)
{
    LOCK(v);
    ntfs_volume *vol = v->vol;
    out->cluster_size = (uint32_t)vol->cluster_size;
    out->total_bytes = (uint64_t)vol->nr_clusters * vol->cluster_size;
    out->free_bytes = (uint64_t)vol->free_clusters * vol->cluster_size;
    out->total_files = vol->mft_na
        ? (uint64_t)(vol->mft_na->data_size >> vol->mft_record_size_bits)
        : 0;
    UNLOCK(v);
    return 0;
}

void fntfs_volname(fntfs_vol *v, char *out)
{
    LOCK(v);
    out[0] = '\0';
    if (v->vol->vol_name)
        snprintf(out, 256, "%s", v->vol->vol_name);
    UNLOCK(v);
}

#ifdef FNTFS_TESTING
/* White-box access to the sector-alignment layer for the standalone tests. */
int64_t fntfs_test_pread_aligned(void *ctx, fntfs_pread_cb pr,
                                 uint64_t dev_size, uint32_t sector,
                                 void *buf, int64_t count, int64_t off)
{
    fntfs_dev_ctx c = { .swift_ctx = ctx, .pread_cb = pr,
                        .size = (int64_t)dev_size, .sector = sector };
    return dev_pread_aligned(&c, buf, count, off);
}

int64_t fntfs_test_pwrite_aligned(void *ctx, fntfs_pread_cb pr,
                                  fntfs_pwrite_cb pw, uint64_t dev_size,
                                  uint32_t sector, const void *buf,
                                  int64_t count, int64_t off)
{
    fntfs_dev_ctx c = { .swift_ctx = ctx, .pread_cb = pr, .pwrite_cb = pw,
                        .size = (int64_t)dev_size, .sector = sector };
    return dev_pwrite_aligned(&c, buf, count, off);
}
#endif

/* --- namespace ops ------------------------------------------------------- */

int fntfs_getattr(fntfs_vol *v, uint64_t inum, fntfs_attrs *out)
{
    LOCK(v);
    bool cached;
    ntfs_inode *ni = inode_get(v, inum, &cached);
    if (!ni) { int e = -errno; UNLOCK(v); return e; }
    fill_attrs(ni, out);
    inode_put(ni, cached);
    UNLOCK(v);
    return 0;
}

int fntfs_lookup(fntfs_vol *v, uint64_t dir, const char *name,
                 fntfs_attrs *out)
{
    LOCK(v);
    bool dcached;
    ntfs_inode *dir_ni = inode_get(v, dir, &dcached);
    if (!dir_ni) { int e = -errno; UNLOCK(v); return e; }
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, dir_ni, name);
    int err = ni ? 0 : -errno;
    if (ni) {
        /*
         * If the found inode is already open in the I/O cache we now hold a
         * second instance; close ours and read attrs from the cached one.
         */
        uint64_t inum = ni->mft_no;
        bool have_cached = false;
        for (int i = 0; i < FCACHE_SIZE; i++) {
            if (v->cache[i].inum == inum) { have_cached = true; break; }
        }
        if (have_cached) {
            ntfs_inode_close(ni);
            bool c2;
            ntfs_inode *cni = inode_get(v, inum, &c2);
            fill_attrs(cni, out);
        } else {
            fill_attrs(ni, out);
            ntfs_inode_close(ni);
        }
    }
    inode_put(dir_ni, dcached);
    UNLOCK(v);
    return err;
}

/* readdir plumbing */

typedef struct {
    fntfs_vol      *v;
    void           *cbctx;
    fntfs_dirent_cb cb;
    bool            stopped;
} readdir_ctx;

static int bridge_filldir(void *dirent, const ntfschar *name,
                          const int name_len, const int name_type,
                          const s64 pos, const MFT_REF mref,
                          const unsigned dt_type)
{
    readdir_ctx *rc = dirent;

    /* Skip DOS-only 8.3 aliases: they duplicate the Win32 name. */
    if (name_type == FILE_NAME_DOS)
        return 0;

    char *utf8 = NULL;
    if (ntfs_ucstombs(name, name_len, &utf8, 0) < 0)
        return 0; /* unconvertible name: skip entry, keep enumerating */

    /* Unlink ghosts are deleted files kept alive for still-open handles;
       they must never appear in a listing. */
    if (!strncmp(utf8, GHOST_DEL_PREFIX, strlen(GHOST_DEL_PREFIX))) {
        free(utf8);
        return 0;
    }

    int32_t type = (dt_type == NTFS_DT_DIR) ? FNTFS_TYPE_DIR : FNTFS_TYPE_FILE;
    bool keep_going = rc->cb(rc->cbctx, utf8, type, MREF(mref), pos + 1);
    free(utf8);
    if (!keep_going) {
        rc->stopped = true;
        return -1; /* abort enumeration; not an error for us */
    }
    return 0;
}

int fntfs_readdir(fntfs_vol *v, uint64_t dir, int64_t cookie, void *cbctx,
                  fntfs_dirent_cb cb)
{
    LOCK(v);
    bool dcached;
    ntfs_inode *dir_ni = inode_get(v, dir, &dcached);
    if (!dir_ni) { int e = -errno; UNLOCK(v); return e; }

    readdir_ctx rc = { v, cbctx, cb, false };
    s64 pos = cookie;
    int err = 0;
    if (ntfs_readdir(dir_ni, &pos, &rc, bridge_filldir) && !rc.stopped)
        err = -errno;
    inode_put(dir_ni, dcached);
    UNLOCK(v);
    return err;
}

/* --- data I/O ------------------------------------------------------------ */

int64_t fntfs_read(fntfs_vol *v, uint64_t inum, void *buf, int64_t len,
                   int64_t off)
{
    LOCK(v);
    ntfs_inode *ni; ntfs_attr *na;
    int err = fcache_get(v, inum, &ni, &na);
    if (err) { UNLOCK(v); return err; }

    int64_t total = 0;
    while (total < len) {
        s64 r = ntfs_attr_pread(na, off + total, len - total,
                                (char *)buf + total);
        if (r < 0) { total = total ? total : -errno; break; }
        if (r == 0) break; /* EOF */
        total += r;
    }
    UNLOCK(v);
    return total;
}

int64_t fntfs_write(fntfs_vol *v, uint64_t inum, const void *buf, int64_t len,
                    int64_t off)
{
    LOCK(v);
    ntfs_inode *ni; ntfs_attr *na;
    int err = fcache_get(v, inum, &ni, &na);
    if (err) { UNLOCK(v); return err; }

    int64_t total = 0;
    while (total < len) {
        s64 w = ntfs_attr_pwrite(na, off + total, len - total,
                                 (const char *)buf + total);
        if (w <= 0) { total = total ? total : -(errno ? errno : EIO); break; }
        total += w;
    }
    if (total > 0)
        ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    UNLOCK(v);
    return total;
}

int fntfs_truncate(fntfs_vol *v, uint64_t inum, uint64_t size)
{
    LOCK(v);
    ntfs_inode *ni; ntfs_attr *na;
    int err = fcache_get(v, inum, &ni, &na);
    if (err) { UNLOCK(v); return err; }
    if (ntfs_attr_truncate(na, (s64)size))
        err = -errno;
    else
        ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    UNLOCK(v);
    return err;
}

/* --- create / remove / link / rename ------------------------------------- */

static int name_to_ucs(const char *name, ntfschar **uname)
{
    int len = ntfs_mbstoucs(name, uname);
    if (len < 0) return -errno;
    if (len > NTFS_MAX_NAME_LEN) { free(*uname); return -ENAMETOOLONG; }
    return len;
}

int fntfs_create(fntfs_vol *v, uint64_t dir, const char *name, bool is_dir,
                 fntfs_attrs *out)
{
    LOCK(v);
    int err = 0;
    ntfschar *uname = NULL;
    int ulen = name_to_ucs(name, &uname);
    if (ulen < 0) { UNLOCK(v); return ulen; }

    ntfs_inode *dir_ni = ntfs_inode_open(v->vol, MK_MREF(dir, 0));
    if (!dir_ni) { err = -errno; free(uname); UNLOCK(v); return err; }

    /* libntfs-3g happily creates case-colliding duplicates ("foo" beside
       "FOO"); on this case-insensitive volume that must be EEXIST. The
       lookup folds case because the volume is in ignore-case mode. */
    ntfs_inode *existing = ntfs_pathname_to_inode(v->vol, dir_ni, name);
    if (existing) {
        ntfs_inode_close(existing);
        ntfs_inode_close(dir_ni);
        free(uname);
        UNLOCK(v);
        return -EEXIST;
    }

    ntfs_inode *ni = ntfs_create(dir_ni, const_cpu_to_le32(0), uname,
                                 (u8)ulen, is_dir ? S_IFDIR : S_IFREG);
    if (!ni) {
        err = -errno;
        ntfs_inode_close(dir_ni);
    } else {
        fill_attrs(ni, out);
        if (ntfs_inode_close_in_dir(ni, dir_ni) && !err)
            err = -errno;
        if (ntfs_inode_close(dir_ni) && !err)
            err = -errno;
    }
    free(uname);
    UNLOCK(v);
    return err;
}

int fntfs_remove(fntfs_vol *v, uint64_t dir, const char *name, uint64_t inum)
{
    LOCK(v);
    int err = fcache_drop(v, inum);
    if (!err) err = fcache_drop(v, dir);
    if (err) { UNLOCK(v); return err; }   /* dirty data would be lost */

    ntfschar *uname = NULL;
    int ulen = name_to_ucs(name, &uname);
    if (ulen < 0) { UNLOCK(v); return ulen; }

    ntfs_inode *dir_ni = ntfs_inode_open(v->vol, MK_MREF(dir, 0));
    if (!dir_ni) { err = -errno; free(uname); UNLOCK(v); return err; }
    ntfs_inode *ni = ntfs_inode_open(v->vol, MK_MREF(inum, 0));
    if (!ni) {
        err = -errno;
        ntfs_inode_close(dir_ni);
        free(uname);
        UNLOCK(v);
        return err;
    }
    /* ntfs_delete closes both inodes, success or failure. */
    if (ntfs_delete(v->vol, NULL, ni, dir_ni, uname, (u8)ulen))
        err = -errno;
    free(uname);
    UNLOCK(v);
    return err;
}

int fntfs_link(fntfs_vol *v, uint64_t inum, uint64_t dir, const char *name)
{
    LOCK(v);
    int err = fcache_drop(v, inum);
    if (err) { UNLOCK(v); return err; }

    ntfschar *uname = NULL;
    int ulen = name_to_ucs(name, &uname);
    if (ulen < 0) { UNLOCK(v); return ulen; }

    ntfs_inode *dir_ni = ntfs_inode_open(v->vol, MK_MREF(dir, 0));
    ntfs_inode *ni = dir_ni ? ntfs_inode_open(v->vol, MK_MREF(inum, 0)) : NULL;
    if (!dir_ni || !ni) {
        err = -errno;
        if (dir_ni) ntfs_inode_close(dir_ni);
    } else {
        /* Case-folding duplicate guard — see fntfs_create. */
        ntfs_inode *existing = ntfs_pathname_to_inode(v->vol, dir_ni, name);
        if (existing) {
            ntfs_inode_close(existing);
            err = -EEXIST;
        } else if (ntfs_link(ni, dir_ni, uname, (u8)ulen)) {
            err = -errno;
        }
        if (ntfs_inode_close(ni) && !err) err = -errno;
        if (ntfs_inode_close(dir_ni) && !err) err = -errno;
    }
    free(uname);
    UNLOCK(v);
    return err;
}

/* Is `inum` a directory? Uses the cached instance when one exists. */
static int inum_is_dir(fntfs_vol *v, uint64_t inum, bool *isdir)
{
    bool cached;
    ntfs_inode *ni = inode_get(v, inum, &cached);
    if (!ni) return -errno;
    *isdir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != 0;
    inode_put(ni, cached);
    return 0;
}

/*
 * Number of *effective* names an inode has. The MFT link_count over-counts:
 * a Windows-created file carries a paired DOS 8.3 alias that ntfs_delete
 * removes together with its WIN32 name, so for open-unlink decisions only
 * non-DOS names matter. Returns the count, or -errno.
 */
static int count_real_names(fntfs_vol *v, uint64_t inum)
{
    bool cached;
    ntfs_inode *ni = inode_get(v, inum, &cached);
    if (!ni) return -errno;
    int names = 0, err = 0;
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, NULL);
    if (!ctx) {
        err = -ENOMEM;
    } else {
        while (!ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE,
                                 0, NULL, 0, ctx)) {
            FILE_NAME_ATTR *fn = (FILE_NAME_ATTR *)((u8 *)ctx->attr
                + le16_to_cpu(ctx->attr->value_offset));
            if (fn->file_name_type != FILE_NAME_DOS)
                names++;
        }
        ntfs_attr_put_search_ctx(ctx);
    }
    inode_put(ni, cached);
    return err ? err : names;
}

/* Do two UTF-8 names fold to the same NTFS name under $UpCase? */
static bool names_equal_fold(fntfs_vol *v, const char *a, const char *b)
{
    ntfschar *ua = NULL, *ub = NULL;
    int la = ntfs_mbstoucs(a, &ua);
    int lb = ntfs_mbstoucs(b, &ub);
    bool eq = la >= 0 && lb >= 0 &&
        ntfs_names_are_equal(ua, la, ub, lb, IGNORE_CASE,
                             v->vol->upcase, v->vol->upcase_len);
    free(ua);
    free(ub);
    return eq;
}

/* -EINVAL if `dst_dir` is `inum` itself or lies anywhere below it — a
   directory must never be moved into its own subtree. */
static int check_not_descendant(fntfs_vol *v, uint64_t inum, uint64_t dst_dir)
{
    uint64_t cur = dst_dir;
    for (int depth = 0; depth < 4096; depth++) {
        if (cur == inum)
            return -EINVAL;
        if (cur == FILE_root)
            return 0;
        bool cached;
        ntfs_inode *ni = inode_get(v, cur, &cached);
        if (!ni) return -errno;
        int err = 0;
        uint64_t parent = cur;
        ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(ni, NULL);
        if (!ctx) {
            err = -ENOMEM;
        } else {
            if (ntfs_attr_lookup(AT_FILE_NAME, AT_UNNAMED, 0, CASE_SENSITIVE,
                                 0, NULL, 0, ctx)) {
                err = -EIO;
            } else {
                FILE_NAME_ATTR *fn = (FILE_NAME_ATTR *)((u8 *)ctx->attr
                    + le16_to_cpu(ctx->attr->value_offset));
                parent = MREF_LE(fn->parent_directory);
            }
            ntfs_attr_put_search_ctx(ctx);
        }
        inode_put(ni, cached);
        if (err) return err;
        if (parent == cur)      /* self-parented: nothing above us */
            return 0;
        cur = parent;
    }
    return -ELOOP;
}

/* Change only the case/spelling of a name that folds onto itself: link a
   ghost, drop the old name, add the new one. Called with the lock held. */
static int rename_case_change(fntfs_vol *v, uint64_t inum, uint64_t dir,
                              const char *src_name, const char *dst_name)
{
    char ghost[64];
    ghost_name(ghost, sizeof ghost, GHOST_MV_PREFIX, inum);

    int err = fntfs_link(v, inum, dir, ghost);
    if (err) return err;
    err = fntfs_remove(v, dir, src_name, inum);
    if (err) {
        fntfs_remove(v, dir, ghost, inum);
        return err;
    }
    err = fntfs_link(v, inum, dir, dst_name);
    if (err) {
        /* Put the old name back; worst case the file stays under the ghost
           name (data preserved, swept/renameable later). */
        if (!fntfs_link(v, inum, dir, src_name))
            fntfs_remove(v, dir, ghost, inum);
        return err;
    }
    fntfs_remove(v, dir, ghost, inum);   /* best-effort; visible if leaked */
    return 0;
}

int fntfs_rename2(fntfs_vol *v, uint64_t inum, uint64_t src_dir,
                  const char *src_name, uint64_t dst_dir, const char *dst_name,
                  uint64_t over_inum, char *over_ghost_out)
{
    /* The recursive lock is held across the whole sequence so the individual
       link/remove steps (each of which also locks) can't interleave with other
       operations — the rename is atomic with respect to the rest of the driver.
       NTFS keeps a file's parent in its $FILE_NAME attribute, so link-to-new +
       remove-old correctly re-parents files AND directories (ntfs_link permits
       directory links, which is exactly how ntfs-3g's own rename moves dirs). */
    LOCK(v);
    int err;
    if (over_ghost_out)
        over_ghost_out[0] = '\0';

    /* Same directory entry, byte for byte: POSIX no-op. */
    if (src_dir == dst_dir && strcmp(src_name, dst_name) == 0) {
        UNLOCK(v);
        return 0;
    }

    /* Same-directory rename where the names fold together ("foo" → "FOO"):
       a case-preserving volume must apply the new spelling. This needs its
       own path because linking the new name would collide with the old one. */
    if (src_dir == dst_dir && (over_inum == 0 || over_inum == inum)
        && names_equal_fold(v, src_name, dst_name)) {
        err = rename_case_change(v, inum, dst_dir, src_name, dst_name);
        UNLOCK(v);
        return err;
    }

    /* Source and destination are hard links to the same file: POSIX says
       rename does nothing and reports success. */
    if (over_inum == inum) {
        UNLOCK(v);
        return 0;
    }

    bool src_isdir = false;
    err = inum_is_dir(v, inum, &src_isdir);
    if (err) { UNLOCK(v); return err; }

    /* A directory must not move into itself or its own subtree — that would
       detach the whole subtree from the namespace. */
    if (src_isdir && src_dir != dst_dir) {
        err = check_not_descendant(v, inum, dst_dir);
        if (err) { UNLOCK(v); return err; }
    }

    if (over_inum) {
        /* POSIX type rules for the existing destination. */
        bool dst_isdir = false;
        err = inum_is_dir(v, over_inum, &dst_isdir);
        if (err) { UNLOCK(v); return err; }
        if (src_isdir && !dst_isdir) { UNLOCK(v); return -ENOTDIR; }
        if (!src_isdir && dst_isdir) { UNLOCK(v); return -EISDIR; }
        if (dst_isdir) {
            /* Only an empty directory may be replaced. Checked before the
               ghost link below — parking first would raise the link count
               past ntfs_delete's own emptiness guard and let a populated
               directory vanish into an invisible ghost. */
            bool cached;
            ntfs_inode *ni = inode_get(v, over_inum, &cached);
            if (!ni) { err = -errno; UNLOCK(v); return err; }
            int r = ntfs_check_empty_dir(ni);
            inode_put(ni, cached);
            if (r) {
                err = -(errno ? errno : ENOTEMPTY);
                UNLOCK(v);
                return err;
            }
        }
    }

    if (!over_inum) {
        /* Destination is free: add the new name, then drop the old one. */
        err = fntfs_link(v, inum, dst_dir, dst_name);
        if (!err) {
            err = fntfs_remove(v, src_dir, src_name, inum);
            if (err)
                fntfs_remove(v, dst_dir, dst_name, inum);   /* roll back */
        }
        UNLOCK(v);
        return err;
    }

    /* Overwrite: never delete the destination up front. Park the existing
       target under a temporary "ghost" name so any failure can restore it
       (mirrors ntfs-3g's ntfs_fuse_safe_rename).

       When the caller asks to KEEP the replaced inode (it is still open
       somewhere — POSIX says its data must survive until the last close) and
       this is its only real name, park it directly as a hidden del-ghost in
       the root directory and hand that name back instead of deleting it. */
    bool keep_over = false;
    if (over_ghost_out) {
        int names = count_real_names(v, over_inum);
        if (names < 0) { UNLOCK(v); return names; }
        keep_over = (names <= 1);   /* other names keep the inode alive */
    }
    char ghost[64];
    uint64_t ghost_dir;
    if (keep_over) {
        ghost_name(ghost, sizeof ghost, GHOST_DEL_PREFIX, over_inum);
        ghost_dir = FILE_root;
    } else {
        ghost_name(ghost, sizeof ghost, GHOST_MV_PREFIX, over_inum);
        ghost_dir = dst_dir;
    }

    err = fntfs_link(v, over_inum, ghost_dir, ghost);       /* 1: park target */
    if (err) { UNLOCK(v); return err; }

    err = fntfs_remove(v, dst_dir, dst_name, over_inum);    /* 2: free the name */
    if (err) {
        fntfs_remove(v, ghost_dir, ghost, over_inum);       /* undo 1 */
        UNLOCK(v);
        return err;
    }

    err = fntfs_link(v, inum, dst_dir, dst_name);           /* 3: move source in */
    if (err)
        goto restore;

    err = fntfs_remove(v, src_dir, src_name, inum);         /* 4: drop old name */
    if (err) {
        fntfs_remove(v, dst_dir, dst_name, inum);           /* undo 3 */
        goto restore;
    }

    if (keep_over) {
        /* Success; the replaced inode lives on under the del-ghost until the
           caller finalizes it (last close / reclaim / mount sweep). */
        snprintf(over_ghost_out, 64, "%s", ghost);
    } else if (fntfs_remove(v, ghost_dir, ghost, over_inum)) {
        /* Success: the old target dies with its last (ghost) name. If this
           final unlink fails the rename still succeeded — the leftover ghost
           stays visible in listings and is swept at the next rw mount. */
        ntfs_log_error("MNtfs: rename succeeded but ghost '%s' was left "
                       "behind\n", ghost);
    }
    UNLOCK(v);
    return 0;

restore:
    /* Put the destination back under its real name; if that also fails the
       target survives under the ghost name (data preserved, never lost). */
    if (!fntfs_link(v, over_inum, dst_dir, dst_name))
        fntfs_remove(v, ghost_dir, ghost, over_inum);
    UNLOCK(v);
    return err;
}

int fntfs_rename(fntfs_vol *v, uint64_t inum, uint64_t src_dir,
                 const char *src_name, uint64_t dst_dir, const char *dst_name,
                 uint64_t over_inum)
{
    return fntfs_rename2(v, inum, src_dir, src_name, dst_dir, dst_name,
                         over_inum, NULL);
}

int fntfs_unlink_keep(fntfs_vol *v, uint64_t dir, const char *name,
                      uint64_t inum, char *ghost_out)
{
    LOCK(v);
    ghost_out[0] = '\0';

    /* Decide *inside* the lock (a caller-side link-count check would race
       with concurrent removes): if the inode has other real names, removing
       this one cannot destroy it — no ghost needed. Counting ignores DOS 8.3
       aliases, which ntfs_delete drops together with their WIN32 pair. */
    int names = count_real_names(v, inum);
    if (names < 0) { UNLOCK(v); return names; }
    if (names > 1) {
        int err = fntfs_remove(v, dir, name, inum);
        UNLOCK(v);
        return err;
    }

    ghost_name(ghost_out, 64, GHOST_DEL_PREFIX, inum);
    int err = fntfs_link(v, inum, FILE_root, ghost_out);
    if (!err) {
        err = fntfs_remove(v, dir, name, inum);
        if (err)
            fntfs_remove(v, FILE_root, ghost_out, inum);    /* roll back */
    }
    if (err)
        ghost_out[0] = '\0';
    UNLOCK(v);
    return err;
}

/* --- metadata setters ----------------------------------------------------- */

int fntfs_settimes(fntfs_vol *v, uint64_t inum, const fntfs_attrs *times,
                   uint32_t mask)
{
    LOCK(v);
    bool cached;
    ntfs_inode *ni = inode_get(v, inum, &cached);
    if (!ni) { int e = -errno; UNLOCK(v); return e; }

    /* ntfs_inode_set_times takes packed little-endian NTFS times:
       [creation, last data change, last MFT change, last access]. */
    u64 packed[4];
    packed[0] = (u64)ni->creation_time;
    packed[1] = (u64)ni->last_data_change_time;
    packed[2] = (u64)ni->last_mft_change_time;
    packed[3] = (u64)ni->last_access_time;

    struct timespec ts;
    if (mask & FNTFS_SET_CRTIME) {
        ts.tv_sec = times->crtime_sec; ts.tv_nsec = times->crtime_nsec;
        packed[0] = (u64)timespec2ntfs(ts);
    }
    if (mask & FNTFS_SET_MTIME) {
        ts.tv_sec = times->mtime_sec; ts.tv_nsec = times->mtime_nsec;
        packed[1] = (u64)timespec2ntfs(ts);
    }
    if (mask & FNTFS_SET_ATIME) {
        ts.tv_sec = times->atime_sec; ts.tv_nsec = times->atime_nsec;
        packed[3] = (u64)timespec2ntfs(ts);
    }

    int err = 0;
    if (ntfs_inode_set_times(ni, (const char *)packed, sizeof(packed), 0))
        err = -errno;
    inode_put(ni, cached);
    UNLOCK(v);
    return err;
}

int fntfs_setwinattrs(fntfs_vol *v, uint64_t inum, uint32_t win_attrs)
{
    LOCK(v);
    bool cached;
    ntfs_inode *ni = inode_get(v, inum, &cached);
    if (!ni) { int e = -errno; UNLOCK(v); return e; }

    uint32_t fl = le32_to_cpu(ni->flags);
    fl &= ~(0x0001u | 0x0002u | 0x0004u);
    if (win_attrs & FNTFS_WINATTR_READONLY) fl |= 0x0001u;
    if (win_attrs & FNTFS_WINATTR_HIDDEN)   fl |= 0x0002u;
    if (win_attrs & FNTFS_WINATTR_SYSTEM)   fl |= 0x0004u;
    ni->flags = cpu_to_le32(fl);
    ntfs_inode_mark_dirty(ni);

    int err = 0;
    if (!cached && ntfs_inode_close(ni))
        err = -errno;
    if (cached)
        (void)0; /* stays open in cache; will sync on fsync/unmount */
    UNLOCK(v);
    return err;
}

int fntfs_forget(fntfs_vol *v, uint64_t inum)
{
    LOCK(v);
    int err = fcache_drop(v, inum);
    UNLOCK(v);
    return err;
}

/* --- consistency check ---------------------------------------------------- */

int fntfs_check_state(void *ctx, fntfs_pread_cb pread_cb, uint64_t dev_size,
                      uint32_t sector_size, uint32_t *state_out)
{
    *state_out = 0;
    int err = 0;
    /* Read-only mount: never touches the device, and (unlike a read-write
       mount) performs no log replay or hiberfile removal, so the dirty state
       is observed as-is. */
    fntfs_vol *v = fntfs_mount(ctx, pread_cb, NULL, NULL, dev_size,
                               sector_size, true, NULL, NULL, &err);
    if (!v)
        return -(err ? err : EIO);
    ntfs_volume *vol = v->vol;

    if (vol->flags & VOLUME_IS_DIRTY)
        *state_out |= FNTFS_VSTATE_DIRTY;

    if (ntfs_volume_check_hiberfile(vol, 0) && errno == EPERM)
        *state_out |= FNTFS_VSTATE_HIBERNATED;

    ntfs_inode *ni = ntfs_inode_open(vol, FILE_LogFile);
    if (ni) {
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na) {
            RESTART_PAGE_HEADER *rp = NULL;
            if (!ntfs_check_logfile(na, &rp) ||
                !ntfs_is_logfile_clean(na, rp))
                *state_out |= FNTFS_VSTATE_LOG_DIRTY;
            free(rp);
            ntfs_attr_close(na);
        }
        ntfs_inode_close(ni);
    }

    fntfs_unmount(v);
    return 0;
}
