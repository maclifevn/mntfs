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

static int64_t dev_pread_aligned(fntfs_dev_ctx *c, void *buf, int64_t count,
                                 int64_t offset)
{
    if (offset < 0) return -EINVAL;
    if (offset >= c->size) return 0;
    if (offset + count > c->size) count = c->size - offset;
    if (count <= 0) return 0;

    const uint32_t ss = c->sector;
    if ((offset % ss) == 0 && (count % ss) == 0)
        return c->pread_cb(c->swift_ctx, buf, count, offset);

    int64_t astart = (offset / ss) * ss;
    int64_t aend = ((offset + count + ss - 1) / ss) * ss;
    if (aend > c->size) aend = c->size;
    int64_t alen = aend - astart;
    char *tmp = malloc((size_t)alen);
    if (!tmp) return -ENOMEM;
    int64_t r = c->pread_cb(c->swift_ctx, tmp, alen, astart);
    if (r < 0) { free(tmp); return r; }
    int64_t avail = r - (offset - astart);
    if (avail < 0) avail = 0;
    if (avail > count) avail = count;
    memcpy(buf, tmp + (offset - astart), (size_t)avail);
    free(tmp);
    return avail;
}

static int64_t dev_pwrite_aligned(fntfs_dev_ctx *c, const void *buf,
                                  int64_t count, int64_t offset)
{
    if (c->readonly || !c->pwrite_cb) return -EROFS;
    if (offset < 0 || offset + count > c->size) return -EIO;
    if (count <= 0) return 0;

    const uint32_t ss = c->sector;
    if ((offset % ss) == 0 && (count % ss) == 0)
        return c->pwrite_cb(c->swift_ctx, buf, count, offset);

    /* Read-modify-write the covering aligned span. */
    int64_t astart = (offset / ss) * ss;
    int64_t aend = ((offset + count + ss - 1) / ss) * ss;
    if (aend > c->size) aend = c->size;
    int64_t alen = aend - astart;
    char *tmp = malloc((size_t)alen);
    if (!tmp) return -ENOMEM;
    int64_t r = c->pread_cb(c->swift_ctx, tmp, alen, astart);
    if (r < alen) { free(tmp); return r < 0 ? r : -EIO; }
    memcpy(tmp + (offset - astart), buf, (size_t)count);
    int64_t w = c->pwrite_cb(c->swift_ctx, tmp, alen, astart);
    free(tmp);
    if (w < alen) return w < 0 ? w : -EIO;
    return count;
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

static void fcache_drop_ent(fcache_ent *e)
{
    if (!e->inum) return;
    if (e->na) ntfs_attr_close(e->na);
    if (e->ni) ntfs_inode_close(e->ni);
    e->inum = 0; e->ni = NULL; e->na = NULL;
}

static void fcache_drop(fntfs_vol *v, uint64_t inum)
{
    for (int i = 0; i < FCACHE_SIZE; i++)
        if (v->cache[i].inum == inum)
            fcache_drop_ent(&v->cache[i]);
}

static void fcache_drop_all(fntfs_vol *v)
{
    for (int i = 0; i < FCACHE_SIZE; i++)
        fcache_drop_ent(&v->cache[i]);
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
    /* Evict LRU. */
    int victim = 0;
    for (int i = 1; i < FCACHE_SIZE; i++) {
        if (!v->cache[i].inum) { victim = i; break; }
        if (v->cache[i].stamp < v->cache[victim].stamp) victim = i;
    }
    fcache_drop_ent(&v->cache[victim]);
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
    fcache_drop_all(v);
    int err = 0;
    if (ntfs_umount(v->vol, FALSE))   /* also frees the device */
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
    fcache_drop(v, inum);
    fcache_drop(v, dir);

    int err = 0;
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
    fcache_drop(v, inum);

    int err = 0;
    ntfschar *uname = NULL;
    int ulen = name_to_ucs(name, &uname);
    if (ulen < 0) { UNLOCK(v); return ulen; }

    ntfs_inode *dir_ni = ntfs_inode_open(v->vol, MK_MREF(dir, 0));
    ntfs_inode *ni = dir_ni ? ntfs_inode_open(v->vol, MK_MREF(inum, 0)) : NULL;
    if (!dir_ni || !ni) {
        err = -errno;
        if (dir_ni) ntfs_inode_close(dir_ni);
    } else {
        if (ntfs_link(ni, dir_ni, uname, (u8)ulen))
            err = -errno;
        if (ntfs_inode_close(ni) && !err) err = -errno;
        if (ntfs_inode_close(dir_ni) && !err) err = -errno;
    }
    free(uname);
    UNLOCK(v);
    return err;
}

int fntfs_rename(fntfs_vol *v, uint64_t inum, uint64_t src_dir,
                 const char *src_name, uint64_t dst_dir, const char *dst_name)
{
    int err = fntfs_link(v, inum, dst_dir, dst_name);
    if (err)
        return err;
    err = fntfs_remove(v, src_dir, src_name, inum);
    if (err) {
        /* Roll the new link back so we don't leave two names behind. */
        fntfs_remove(v, dst_dir, dst_name, inum);
    }
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

void fntfs_forget(fntfs_vol *v, uint64_t inum)
{
    LOCK(v);
    fcache_drop(v, inum);
    UNLOCK(v);
}
