/*
 * fntfs.h — FastNTFS bridge API
 *
 * A thin, FSKit-shaped C facade over libntfs-3g. All calls are serialized
 * internally; callers may invoke from any thread. Functions return 0 or a
 * positive byte count on success, and -errno on failure.
 *
 * Device I/O is delegated to caller-supplied callbacks so the volume can sit
 * on top of an FSBlockDeviceResource (or a plain file in tests). The bridge
 * handles sector alignment internally: callbacks only ever see sector-aligned
 * offsets and lengths.
 */

#ifndef FNTFS_H
#define FNTFS_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fntfs_vol fntfs_vol;

/* I/O callbacks. `ctx` is an opaque handle passed straight back to the caller
   (never dereferenced by the bridge), so it may be NULL. Return bytes
   transferred, or -errno. */
typedef int64_t (*fntfs_pread_cb)(void *_Nullable ctx, void *_Nonnull buf,
                                  int64_t count, int64_t offset);
typedef int64_t (*fntfs_pwrite_cb)(void *_Nullable ctx, const void *_Nonnull buf,
                                   int64_t count, int64_t offset);
/* Flush device caches. Return 0 or -errno. */
typedef int (*fntfs_flush_cb)(void *_Nullable ctx);

enum {
    FNTFS_TYPE_UNKNOWN = 0,
    FNTFS_TYPE_FILE    = 1,
    FNTFS_TYPE_DIR     = 2,
    FNTFS_TYPE_SYMLINK = 3,
};

/* Windows file attribute bits we surface (subset of FILE_ATTR_*). */
#define FNTFS_WINATTR_READONLY 0x0001u
#define FNTFS_WINATTR_HIDDEN   0x0002u
#define FNTFS_WINATTR_SYSTEM   0x0004u

typedef struct {
    uint64_t inum;
    int32_t  type;          /* FNTFS_TYPE_* */
    uint32_t nlink;
    uint64_t size;
    uint64_t alloc_size;
    uint32_t win_attrs;
    int64_t  crtime_sec; int32_t crtime_nsec;   /* birth   */
    int64_t  mtime_sec;  int32_t mtime_nsec;    /* data    */
    int64_t  ctime_sec;  int32_t ctime_nsec;    /* meta    */
    int64_t  atime_sec;  int32_t atime_nsec;    /* access  */
} fntfs_attrs;

/* Bit mask for fntfs_settimes. */
#define FNTFS_SET_CRTIME (1u << 0)
#define FNTFS_SET_MTIME  (1u << 1)
#define FNTFS_SET_ATIME  (1u << 2)

typedef struct {
    uint64_t total_bytes;
    uint64_t free_bytes;
    uint32_t cluster_size;
    uint64_t total_files;
} fntfs_statfs_t;

/* Probe result codes. */
enum {
    FNTFS_PROBE_USABLE      = 0,  /* recognized, mountable            */
    FNTFS_PROBE_RECOGNIZED  = 1,  /* NTFS, but not safely mountable   */
    FNTFS_PROBE_UNRECOGNIZED = 2, /* not NTFS                         */
};

/*
 * Probe a device. Attempts a read-only mount to fetch the volume label and
 * serial; falls back to a boot-sector check. name_out must hold >= 256 bytes.
 */
int fntfs_probe(void *_Nullable ctx, fntfs_pread_cb _Nonnull pread_cb,
                uint64_t dev_size, uint32_t sector_size,
                char *_Nonnull name_out, uint64_t *_Nonnull serial_out);

/*
 * Mount. On success returns a volume handle and fills name/serial.
 * On failure returns NULL and sets *err_out to a positive errno.
 */
fntfs_vol *_Nullable fntfs_mount(void *_Nullable ctx,
                                 fntfs_pread_cb _Nonnull pread_cb,
                                 fntfs_pwrite_cb _Nullable pwrite_cb,
                                 fntfs_flush_cb _Nullable flush_cb,
                                 uint64_t dev_size, uint32_t sector_size,
                                 bool readonly,
                                 char *_Nullable name_out,
                                 uint64_t *_Nullable serial_out,
                                 int *_Nonnull err_out);

/* Flush everything and release the volume. Returns 0 or -errno. */
int fntfs_unmount(fntfs_vol *_Nonnull v);

/* Flush all dirty state (inodes, MFT, device). */
int fntfs_sync(fntfs_vol *_Nonnull v);

int fntfs_statfs(fntfs_vol *_Nonnull v, fntfs_statfs_t *_Nonnull out);

/* Root directory inode number (FILE_root == 5). */
uint64_t fntfs_root_inum(void);

int fntfs_getattr(fntfs_vol *_Nonnull v, uint64_t inum,
                  fntfs_attrs *_Nonnull out);

/* Look up `name` (UTF-8) inside directory `dir`. */
int fntfs_lookup(fntfs_vol *_Nonnull v, uint64_t dir,
                 const char *_Nonnull name, fntfs_attrs *_Nonnull out);

/*
 * Directory enumeration. The callback receives each entry; return false to
 * stop early (e.g. reply buffer full). `next_cookie` resumes enumeration
 * *after* the delivered entry when passed as `cookie` to the next call.
 * Entries "." and ".." are delivered first. DOS-only 8.3 aliases and NTFS
 * metadata files are filtered out.
 */
typedef bool (*fntfs_dirent_cb)(void *_Nullable cbctx,
                                const char *_Nonnull name, int32_t type,
                                uint64_t inum, int64_t next_cookie);
int fntfs_readdir(fntfs_vol *_Nonnull v, uint64_t dir, int64_t cookie,
                  void *_Nullable cbctx, fntfs_dirent_cb _Nonnull cb);

/* Returns bytes read (0 at/past EOF) or -errno. */
int64_t fntfs_read(fntfs_vol *_Nonnull v, uint64_t inum,
                   void *_Nonnull buf, int64_t len, int64_t off);

/* Returns bytes written or -errno. Extends the file as needed. */
int64_t fntfs_write(fntfs_vol *_Nonnull v, uint64_t inum,
                    const void *_Nonnull buf, int64_t len, int64_t off);

int fntfs_create(fntfs_vol *_Nonnull v, uint64_t dir,
                 const char *_Nonnull name, bool is_dir,
                 fntfs_attrs *_Nonnull out);

int fntfs_remove(fntfs_vol *_Nonnull v, uint64_t dir,
                 const char *_Nonnull name, uint64_t inum);

/* Hard link `inum` into `dir` as `name`. */
int fntfs_link(fntfs_vol *_Nonnull v, uint64_t inum, uint64_t dir,
               const char *_Nonnull name);

/*
 * Rename/move `inum` from src_dir/src_name to dst_dir/dst_name. Works for files
 * and directories. If `over_inum` is non-zero the destination name already
 * exists and holds that inode; it is replaced atomically-safely (the old target
 * is kept under a temporary name until the move fully succeeds, so a mid-way
 * failure never loses the destination file). Pass over_inum == 0 when the
 * destination does not exist.
 */
int fntfs_rename(fntfs_vol *_Nonnull v, uint64_t inum,
                 uint64_t src_dir, const char *_Nonnull src_name,
                 uint64_t dst_dir, const char *_Nonnull dst_name,
                 uint64_t over_inum);

int fntfs_truncate(fntfs_vol *_Nonnull v, uint64_t inum, uint64_t size);

int fntfs_settimes(fntfs_vol *_Nonnull v, uint64_t inum,
                   const fntfs_attrs *_Nonnull times, uint32_t mask);

/* Set/clear FNTFS_WINATTR_* bits. */
int fntfs_setwinattrs(fntfs_vol *_Nonnull v, uint64_t inum, uint32_t win_attrs);

/* Drop a cached open file handle, if any (call from reclaim). */
void fntfs_forget(fntfs_vol *_Nonnull v, uint64_t inum);

/* Volume label (UTF-8, may be empty). Buffer >= 256 bytes. */
void fntfs_volname(fntfs_vol *_Nonnull v, char *_Nonnull out);

#ifdef __cplusplus
}
#endif

#endif /* FNTFS_H */
