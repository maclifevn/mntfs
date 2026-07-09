/*
 * test_fntfs.c — standalone exerciser for the fntfs bridge.
 *
 * Runs the full operation suite against an NTFS image file (created by
 * mkntfs) without any FSKit involvement, using file-backed I/O callbacks
 * that emulate a 512-byte-sector block device.
 *
 * Usage: test_fntfs <image-file>
 */

#include "../Sources/FSModule/Bridge/fntfs.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SECTOR 512

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        exit(1); \
    } \
} while (0)

static int g_fd;

static int64_t cb_pread(void *ctx, void *buf, int64_t count, int64_t offset)
{
    (void)ctx;
    CHECK(offset % SECTOR == 0 && count % SECTOR == 0,
          "unaligned pread off=%lld len=%lld", (long long)offset,
          (long long)count);
    ssize_t r = pread(g_fd, buf, (size_t)count, offset);
    return r < 0 ? -errno : r;
}

static int64_t cb_pwrite(void *ctx, const void *buf, int64_t count,
                         int64_t offset)
{
    (void)ctx;
    CHECK(offset % SECTOR == 0 && count % SECTOR == 0,
          "unaligned pwrite off=%lld len=%lld", (long long)offset,
          (long long)count);
    ssize_t r = pwrite(g_fd, buf, (size_t)count, offset);
    return r < 0 ? -errno : r;
}

static int cb_flush(void *ctx)
{
    (void)ctx;
    return fsync(g_fd) < 0 ? -errno : 0;
}

/* readdir collector */
struct entlist { char names[64][256]; uint64_t inums[64]; int32_t types[64]; int n; };

static bool collect_cb(void *ctx, const char *name, int32_t type,
                       uint64_t inum, int64_t next_cookie)
{
    (void)next_cookie;
    struct entlist *el = ctx;
    if (el->n < 64) {
        snprintf(el->names[el->n], 256, "%s", name);
        el->inums[el->n] = inum;
        el->types[el->n] = type;
        el->n++;
    }
    return true;
}

static int list_has(struct entlist *el, const char *name)
{
    for (int i = 0; i < el->n; i++)
        if (!strcmp(el->names[i], name))
            return i;
    return -1;
}

/* one-at-a-time enumeration to exercise cookie resumption */
struct one { char name[256]; int got; int64_t next; };
static bool one_cb(void *ctx, const char *name, int32_t type, uint64_t inum,
                   int64_t next_cookie)
{
    (void)type; (void)inum;
    struct one *o = ctx;
    if (o->got) return false;
    snprintf(o->name, 256, "%s", name);
    o->next = next_cookie;
    o->got = 1;
    return true;
}

int main(int argc, char **argv)
{
    CHECK(argc == 2, "usage: %s <image>", argv[0]);
    g_fd = open(argv[1], O_RDWR);
    CHECK(g_fd >= 0, "open image: %s", strerror(errno));
    struct stat st;
    CHECK(fstat(g_fd, &st) == 0, "fstat");
    uint64_t dev_size = (uint64_t)st.st_size;

    char name[256];
    uint64_t serial = 0;

    /* --- probe --- */
    int pr = fntfs_probe(NULL, cb_pread, dev_size, SECTOR, name, &serial);
    CHECK(pr == FNTFS_PROBE_USABLE, "probe=%d", pr);
    CHECK(serial != 0, "serial");
    printf("probe ok: label='%s' serial=%llx\n", name, (unsigned long long)serial);

    /* --- mount rw --- */
    int err = 0;
    fntfs_vol *v = fntfs_mount(NULL, cb_pread, cb_pwrite, cb_flush, dev_size,
                               SECTOR, false, name, &serial, &err);
    CHECK(v, "mount err=%d", err);
    printf("mounted rw: label='%s'\n", name);

    fntfs_statfs_t sf;
    CHECK(fntfs_statfs(v, &sf) == 0, "statfs");
    printf("statfs: total=%llu free=%llu cluster=%u files=%llu\n",
           (unsigned long long)sf.total_bytes, (unsigned long long)sf.free_bytes,
           sf.cluster_size, (unsigned long long)sf.total_files);
    CHECK(sf.total_bytes > 0 && sf.free_bytes > 0, "statfs values");

    uint64_t root = fntfs_root_inum();
    fntfs_attrs a;
    CHECK(fntfs_getattr(v, root, &a) == 0, "getattr root");
    CHECK(a.type == FNTFS_TYPE_DIR, "root type");

    /* --- create file, write, read back --- */
    fntfs_attrs fa;
    CHECK(fntfs_create(v, root, "hello.txt", false, &fa) == 0, "create file");
    CHECK(fa.type == FNTFS_TYPE_FILE, "created type");
    printf("created hello.txt inum=%llu\n", (unsigned long long)fa.inum);

    const char *msg = "Xin chao NTFS from FastNTFS bridge!\n";
    int64_t w = fntfs_write(v, fa.inum, msg, (int64_t)strlen(msg), 0);
    CHECK(w == (int64_t)strlen(msg), "write w=%lld", (long long)w);

    char rbuf[128] = {0};
    int64_t r = fntfs_read(v, fa.inum, rbuf, sizeof(rbuf), 0);
    CHECK(r == (int64_t)strlen(msg), "read r=%lld", (long long)r);
    CHECK(!memcmp(rbuf, msg, strlen(msg)), "readback");

    CHECK(fntfs_getattr(v, fa.inum, &a) == 0, "getattr file");
    CHECK(a.size == strlen(msg), "size=%llu", (unsigned long long)a.size);

    /* --- larger write with odd size & offset (non-aligned paths) --- */
    size_t big = 3 * 1024 * 1024 + 137;
    char *bigbuf = malloc(big), *big2 = malloc(big);
    for (size_t i = 0; i < big; i++) bigbuf[i] = (char)(i * 31 + 7);
    fntfs_attrs ba;
    CHECK(fntfs_create(v, root, "big.bin", false, &ba) == 0, "create big");
    w = fntfs_write(v, ba.inum, bigbuf, (int64_t)big, 4099);
    CHECK(w == (int64_t)big, "big write w=%lld", (long long)w);
    r = fntfs_read(v, ba.inum, big2, (int64_t)big, 4099);
    CHECK(r == (int64_t)big, "big read r=%lld", (long long)r);
    CHECK(!memcmp(bigbuf, big2, big), "big readback");
    CHECK(fntfs_getattr(v, ba.inum, &a) == 0, "getattr big");
    CHECK(a.size == big + 4099, "big size");
    printf("big file ok (%zu bytes at offset 4099)\n", big);

    /* --- mkdir + nested file --- */
    fntfs_attrs da;
    CHECK(fntfs_create(v, root, "Thu Muc", true, &da) == 0, "mkdir");
    CHECK(da.type == FNTFS_TYPE_DIR, "mkdir type");
    fntfs_attrs na_;
    CHECK(fntfs_create(v, da.inum, "nested-tệp.dat", false, &na_) == 0,
          "nested create (unicode)");
    w = fntfs_write(v, na_.inum, "abc", 3, 0);
    CHECK(w == 3, "nested write");

    /* --- lookup --- */
    fntfs_attrs la;
    CHECK(fntfs_lookup(v, root, "hello.txt", &la) == 0, "lookup");
    CHECK(la.inum == fa.inum, "lookup inum");
    CHECK(fntfs_lookup(v, root, "khong-ton-tai", &la) == -ENOENT, "lookup ENOENT");
    CHECK(fntfs_lookup(v, da.inum, "nested-tệp.dat", &la) == 0, "nested lookup");

    /* --- readdir --- */
    struct entlist el = {0};
    CHECK(fntfs_readdir(v, root, 0, &el, collect_cb) == 0, "readdir");
    printf("root entries (%d):", el.n);
    for (int i = 0; i < el.n; i++) printf(" %s", el.names[i]);
    printf("\n");
    CHECK(list_has(&el, ".") >= 0 && list_has(&el, "..") >= 0, "dot entries");
    CHECK(list_has(&el, "hello.txt") >= 0, "hello listed");
    CHECK(list_has(&el, "Thu Muc") >= 0, "dir listed");
    CHECK(list_has(&el, "$MFT") < 0, "system files hidden");

    /* --- cookie resumption: walk one entry at a time --- */
    struct entlist el2 = {0};
    int64_t cookie = 0;
    for (;;) {
        struct one o = {0};
        CHECK(fntfs_readdir(v, root, cookie, &o, one_cb) == 0, "readdir step");
        if (!o.got) break;
        collect_cb(&el2, o.name, 0, 0, 0);
        cookie = o.next;
        CHECK(el2.n < 64, "runaway enumeration");
    }
    CHECK(el2.n == el.n, "stepwise count %d vs %d", el2.n, el.n);
    for (int i = 0; i < el.n; i++)
        CHECK(list_has(&el2, el.names[i]) >= 0, "stepwise missing %s", el.names[i]);
    printf("cookie resumption ok\n");

    /* --- rename (same dir, cross dir) --- */
    CHECK(fntfs_rename(v, fa.inum, root, "hello.txt", root, "chao.txt", 0) == 0,
          "rename same dir");
    CHECK(fntfs_lookup(v, root, "chao.txt", &la) == 0 && la.inum == fa.inum,
          "renamed lookup");
    CHECK(fntfs_lookup(v, root, "hello.txt", &la) == -ENOENT, "old gone");
    CHECK(fntfs_rename(v, fa.inum, root, "chao.txt", da.inum, "moved.txt", 0) == 0,
          "rename cross dir");
    CHECK(fntfs_lookup(v, da.inum, "moved.txt", &la) == 0, "moved lookup");
    r = fntfs_read(v, fa.inum, rbuf, sizeof(rbuf), 0);
    CHECK(r == (int64_t)strlen(msg) && !memcmp(rbuf, msg, strlen(msg)),
          "content survives rename");

    /* --- rename directory (and its nested content survives) --- */
    CHECK(fntfs_rename(v, da.inum, root, "Thu Muc", root, "ThuMuc2", 0) == 0,
          "rename dir");
    CHECK(fntfs_lookup(v, root, "ThuMuc2", &la) == 0 && la.inum == da.inum,
          "renamed dir lookup");
    CHECK(fntfs_lookup(v, da.inum, "nested-tệp.dat", &la) == 0,
          "nested file survives dir rename");

    /* --- overwrite rename: destination is replaced with source data, and the
           old destination's data is gone (this is the P0 data-loss path) --- */
    fntfs_attrs ka, wa;
    CHECK(fntfs_create(v, root, "keep.txt", false, &ka) == 0, "create keep");
    CHECK(fntfs_create(v, root, "victim.txt", false, &wa) == 0, "create victim");
    CHECK(fntfs_write(v, ka.inum, "SRC", 3, 0) == 3, "write keep");
    CHECK(fntfs_write(v, wa.inum, "DEST-DATA", 9, 0) == 9, "write victim");
    CHECK(fntfs_rename(v, ka.inum, root, "keep.txt",
                       root, "victim.txt", wa.inum) == 0, "overwrite rename");
    CHECK(fntfs_lookup(v, root, "keep.txt", &la) == -ENOENT, "source name gone");
    CHECK(fntfs_lookup(v, root, "victim.txt", &la) == 0 && la.inum == ka.inum,
          "dest name now maps to the source inode");
    r = fntfs_read(v, ka.inum, rbuf, sizeof(rbuf), 0);
    CHECK(r == 3 && !memcmp(rbuf, "SRC", 3), "overwrite kept source data");
    printf("overwrite rename ok\n");

    /* --- hard link --- */
    CHECK(fntfs_link(v, fa.inum, root, "hardlink.txt") == 0, "hardlink");
    CHECK(fntfs_getattr(v, fa.inum, &a) == 0 && a.nlink >= 2, "nlink=%u", a.nlink);

    /* --- truncate --- */
    CHECK(fntfs_truncate(v, ba.inum, 1000) == 0, "truncate down");
    CHECK(fntfs_getattr(v, ba.inum, &a) == 0 && a.size == 1000, "trunc size");
    CHECK(fntfs_truncate(v, ba.inum, 100000) == 0, "truncate up");
    CHECK(fntfs_getattr(v, ba.inum, &a) == 0 && a.size == 100000, "grow size");
    r = fntfs_read(v, ba.inum, rbuf, 64, 50000);
    CHECK(r == 64, "read grown r=%lld", (long long)r);

    /* --- settimes --- */
    fntfs_attrs tset = {0};
    tset.mtime_sec = 946684800; /* 2000-01-01 */
    CHECK(fntfs_settimes(v, fa.inum, &tset, FNTFS_SET_MTIME) == 0, "settimes");
    CHECK(fntfs_getattr(v, fa.inum, &a) == 0 && a.mtime_sec == 946684800,
          "mtime=%lld", (long long)a.mtime_sec);

    /* --- winattrs --- */
    CHECK(fntfs_setwinattrs(v, fa.inum, FNTFS_WINATTR_HIDDEN) == 0, "winattrs");
    CHECK(fntfs_getattr(v, fa.inum, &a) == 0 &&
          (a.win_attrs & FNTFS_WINATTR_HIDDEN), "hidden set");

    /* --- remove --- */
    CHECK(fntfs_remove(v, root, "hardlink.txt", fa.inum) == 0, "rm hardlink");
    CHECK(fntfs_remove(v, da.inum, "moved.txt", fa.inum) == 0, "rm file");
    CHECK(fntfs_lookup(v, da.inum, "moved.txt", &la) == -ENOENT, "rm verified");
    CHECK(fntfs_remove(v, da.inum, "nested-tệp.dat", na_.inum) == 0, "rm nested");
    CHECK(fntfs_remove(v, root, "ThuMuc2", da.inum) == 0, "rmdir");
    CHECK(fntfs_lookup(v, root, "ThuMuc2", &la) == -ENOENT, "rmdir verified");

    /* --- sync + unmount --- */
    CHECK(fntfs_sync(v) == 0, "sync");
    CHECK(fntfs_unmount(v) == 0, "unmount");
    printf("unmounted\n");

    /* --- remount, verify persistence --- */
    v = fntfs_mount(NULL, cb_pread, cb_pwrite, cb_flush, dev_size, SECTOR,
                    false, name, &serial, &err);
    CHECK(v, "remount err=%d", err);
    struct entlist el3 = {0};
    CHECK(fntfs_readdir(v, root, 0, &el3, collect_cb) == 0, "readdir 2");
    CHECK(list_has(&el3, "big.bin") >= 0, "big.bin persisted");
    CHECK(list_has(&el3, "chao.txt") < 0, "chao.txt correctly gone");
    CHECK(list_has(&el3, "ThuMuc2") < 0, "dir correctly gone");
    int bi = list_has(&el3, "big.bin");
    CHECK(fntfs_getattr(v, el3.inums[bi], &a) == 0 && a.size == 100000,
          "persisted size");
    CHECK(fntfs_unmount(v) == 0, "unmount 2");

    close(g_fd);
    printf("ALL TESTS PASSED\n");
    return 0;
}
