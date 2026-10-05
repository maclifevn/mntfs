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

#ifndef SECTOR
#define SECTOR 512
#endif

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        exit(1); \
    } \
} while (0)

static int g_fd;
static int64_t g_max_io;   /* largest single device I/O since last reset */
static int g_fail_writes;
static bool g_fail_flush;

static int64_t cb_pread(void *ctx, void *buf, int64_t count, int64_t offset)
{
    (void)ctx;
    CHECK(offset % SECTOR == 0 && count % SECTOR == 0,
          "unaligned pread off=%lld len=%lld", (long long)offset,
          (long long)count);
    if (count > g_max_io) g_max_io = count;
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
    if (count > g_max_io) g_max_io = count;
    if (g_fail_writes) { g_fail_writes--; return -EIO; }
    ssize_t r = pwrite(g_fd, buf, (size_t)count, offset);
    return r < 0 ? -errno : r;
}

/* White-box hooks from fntfs.c (compiled with -DFNTFS_TESTING). */
extern int fntfs_test_link_raw(fntfs_vol *v, uint64_t inum, uint64_t dir,
                               const char *name);
extern void fntfs_test_dirty_metadata(fntfs_vol *v);
extern bool fntfs_test_metadata_is_dirty(fntfs_vol *v);
extern int64_t fntfs_test_pread_aligned(void *ctx, fntfs_pread_cb pr,
                                        uint64_t dev_size, uint32_t sector,
                                        void *buf, int64_t count, int64_t off);
extern int64_t fntfs_test_pwrite_aligned(void *ctx, fntfs_pread_cb pr,
                                         fntfs_pwrite_cb pw, uint64_t dev_size,
                                         uint32_t sector, const void *buf,
                                         int64_t count, int64_t off);

static int cb_flush(void *ctx)
{
    (void)ctx;
    if (g_fail_flush) return -EIO;
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

    /* Sync must include the metadata inodes owned by libntfs-3g, and must
       report a device flush failure rather than claiming success. */
    fntfs_test_dirty_metadata(v);
    CHECK(fntfs_test_metadata_is_dirty(v), "metadata dirtied");
    CHECK(fntfs_sync(v) == 0 && !fntfs_test_metadata_is_dirty(v),
          "sync did not flush system metadata");
    g_fail_flush = true;
    CHECK(fntfs_sync(v) == -EIO, "sync must propagate device failure");
    g_fail_flush = false;

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

    /* --- rename onto a NON-EMPTY directory must fail with ENOTEMPTY --- */
    fntfs_attrs dst_d, src_d, inner;
    CHECK(fntfs_create(v, root, "dstdir", true, &dst_d) == 0, "mkdir dstdir");
    CHECK(fntfs_create(v, dst_d.inum, "inside.txt", false, &inner) == 0,
          "populate dstdir");
    CHECK(fntfs_create(v, root, "srcdir", true, &src_d) == 0, "mkdir srcdir");
    CHECK(fntfs_rename(v, src_d.inum, root, "srcdir",
                       root, "dstdir", dst_d.inum) == -ENOTEMPTY,
          "overwrite of non-empty dir must be ENOTEMPTY");
    CHECK(fntfs_lookup(v, root, "dstdir", &la) == 0 && la.inum == dst_d.inum,
          "dst dir intact after refused rename");
    CHECK(fntfs_lookup(v, dst_d.inum, "inside.txt", &la) == 0,
          "dst dir content intact");
    struct entlist elg = {0};
    CHECK(fntfs_readdir(v, root, 0, &elg, collect_cb) == 0, "readdir ghosts");
    for (int i = 0; i < elg.n; i++)
        CHECK(strncmp(elg.names[i], ".mntfs-", 7) != 0,
              "ghost leaked: %s", elg.names[i]);

    /* --- POSIX type rules: file over dir = EISDIR, dir over file = ENOTDIR */
    fntfs_attrs plain;
    CHECK(fntfs_create(v, root, "plain.txt", false, &plain) == 0, "create plain");
    CHECK(fntfs_rename(v, plain.inum, root, "plain.txt",
                       root, "dstdir", dst_d.inum) == -EISDIR, "file over dir");
    CHECK(fntfs_rename(v, src_d.inum, root, "srcdir",
                       root, "plain.txt", plain.inum) == -ENOTDIR,
          "dir over file");

    /* --- an EMPTY directory target is replaceable --- */
    CHECK(fntfs_remove(v, dst_d.inum, "inside.txt", inner.inum) == 0,
          "empty out dstdir");
    CHECK(fntfs_rename(v, src_d.inum, root, "srcdir",
                       root, "dstdir", dst_d.inum) == 0, "dir over empty dir");
    CHECK(fntfs_lookup(v, root, "dstdir", &la) == 0 && la.inum == src_d.inum,
          "empty dir replaced");
    CHECK(fntfs_lookup(v, root, "srcdir", &la) == -ENOENT, "src dir name gone");
    CHECK(fntfs_remove(v, root, "plain.txt", plain.inum) == 0, "rm plain");

    /* --- a directory must not move into its own subtree --- */
    fntfs_attrs par, chi;
    CHECK(fntfs_create(v, root, "parent", true, &par) == 0, "mkdir parent");
    CHECK(fntfs_create(v, par.inum, "child", true, &chi) == 0, "mkdir child");
    CHECK(fntfs_rename(v, par.inum, root, "parent",
                       chi.inum, "oops", 0) == -EINVAL,
          "move into descendant rejected");
    CHECK(fntfs_rename(v, par.inum, root, "parent",
                       par.inum, "oops", 0) == -EINVAL,
          "move into self rejected");
    CHECK(fntfs_remove(v, par.inum, "child", chi.inum) == 0, "rm child");
    CHECK(fntfs_remove(v, root, "parent", par.inum) == 0, "rm parent");
    printf("rename safety checks ok\n");

    /* --- hard links to the same inode: rename is a POSIX no-op --- */
    fntfs_attrs hl;
    CHECK(fntfs_create(v, root, "orig.txt", false, &hl) == 0, "create orig");
    CHECK(fntfs_write(v, hl.inum, "HL", 2, 0) == 2, "write orig");
    CHECK(fntfs_link(v, hl.inum, root, "alias.txt") == 0, "link alias");
    CHECK(fntfs_rename(v, hl.inum, root, "orig.txt",
                       root, "alias.txt", hl.inum) == 0, "same-inode rename");
    CHECK(fntfs_lookup(v, root, "orig.txt", &la) == 0, "orig still present");
    CHECK(fntfs_lookup(v, root, "alias.txt", &la) == 0, "alias still present");
    CHECK(fntfs_remove(v, root, "alias.txt", hl.inum) == 0, "rm alias");

    /* --- case-insensitive lookup, collision, case-change rename --- */
    CHECK(fntfs_lookup(v, root, "ORIG.TXT", &la) == 0 && la.inum == hl.inum,
          "case-insensitive lookup");
    fntfs_attrs coll;
    CHECK(fntfs_create(v, root, "OrIg.TxT", false, &coll) == -EEXIST,
          "case-colliding create rejected");
    CHECK(fntfs_rename(v, hl.inum, root, "orig.txt",
                       root, "ORIG.txt", hl.inum) == 0, "case-change rename");
    struct entlist elc = {0};
    CHECK(fntfs_readdir(v, root, 0, &elc, collect_cb) == 0, "readdir case");
    CHECK(list_has(&elc, "ORIG.txt") >= 0, "new spelling listed");
    CHECK(list_has(&elc, "orig.txt") < 0, "old spelling gone");
    r = fntfs_read(v, hl.inum, rbuf, 2, 0);
    CHECK(r == 2 && !memcmp(rbuf, "HL", 2), "content survives case rename");
    CHECK(fntfs_remove(v, root, "ORIG.txt", hl.inum) == 0, "rm cased file");
    printf("case-insensitive semantics ok\n");

    /* --- open-unlink: park, stay readable, invisible, finalize --- */
    fntfs_attrs ou;
    CHECK(fntfs_create(v, root, "openfile.txt", false, &ou) == 0,
          "create openfile");
    CHECK(fntfs_write(v, ou.inum, "STILL-OPEN", 10, 0) == 10, "write openfile");
    char ghost[64];
    CHECK(fntfs_unlink_keep(v, root, "openfile.txt", ou.inum, ghost) == 0,
          "unlink_keep");
    CHECK(fntfs_lookup(v, root, "openfile.txt", &la) == -ENOENT,
          "unlinked name gone");
    r = fntfs_read(v, ou.inum, rbuf, 10, 0);
    CHECK(r == 10 && !memcmp(rbuf, "STILL-OPEN", 10),
          "unlinked-but-open file still readable");
    struct entlist elu = {0};
    CHECK(fntfs_readdir(v, root, 0, &elu, collect_cb) == 0, "readdir unlink");
    for (int i = 0; i < elu.n; i++)
        CHECK(strncmp(elu.names[i], ".mntfs-", 7) != 0,
              "unlink ghost visible: %s", elu.names[i]);
    CHECK(fntfs_remove(v, root, ghost, ou.inum) == 0, "finalize unlinked");

    /* unlink_keep of one of several hard links: plain remove, no ghost */
    fntfs_attrs mh;
    CHECK(fntfs_create(v, root, "multi.txt", false, &mh) == 0, "create multi");
    CHECK(fntfs_link(v, mh.inum, root, "multi2.txt") == 0, "link multi2");
    char ghostm[64] = "x";
    CHECK(fntfs_unlink_keep(v, root, "multi.txt", mh.inum, ghostm) == 0,
          "unlink_keep hardlinked");
    CHECK(ghostm[0] == '\0', "no ghost for hardlinked file");
    CHECK(fntfs_lookup(v, root, "multi.txt", &la) == -ENOENT, "multi gone");
    CHECK(fntfs_lookup(v, root, "multi2.txt", &la) == 0 && la.inum == mh.inum,
          "second link intact");
    CHECK(fntfs_remove(v, root, "multi2.txt", mh.inum) == 0, "rm multi2");

    /* overwrite-rename that must KEEP the open destination (rename2) */
    fntfs_attrs rs, rd;
    CHECK(fntfs_create(v, root, "new.cfg", false, &rs) == 0, "create new.cfg");
    CHECK(fntfs_create(v, root, "cur.cfg", false, &rd) == 0, "create cur.cfg");
    CHECK(fntfs_write(v, rs.inum, "NEW", 3, 0) == 3, "write new.cfg");
    CHECK(fntfs_write(v, rd.inum, "OLD-DATA", 8, 0) == 8, "write cur.cfg");
    char kghost[64] = "";
    CHECK(fntfs_rename2(v, rs.inum, root, "new.cfg", root, "cur.cfg",
                        rd.inum, kghost) == 0, "rename2 keep-over");
    CHECK(kghost[0] != '\0', "replaced inode parked under a ghost");
    CHECK(fntfs_lookup(v, root, "cur.cfg", &la) == 0 && la.inum == rs.inum,
          "dest name maps to source");
    r = fntfs_read(v, rd.inum, rbuf, 8, 0);
    CHECK(r == 8 && !memcmp(rbuf, "OLD-DATA", 8),
          "replaced-but-open inode still readable");
    CHECK(fntfs_remove(v, root, kghost, rd.inum) == 0, "finalize kept over");
    CHECK(fntfs_remove(v, root, "cur.cfg", rs.inum) == 0, "rm cur.cfg");

    /* --- reserved ghost namespace is rejected for user names --- */
    fntfs_attrs rsv;
    CHECK(fntfs_create(v, root, ".mntfs-del-userfile", false, &rsv) == -EINVAL,
          "create in del namespace rejected");
    CHECK(fntfs_create(v, root, ".mntfs-mv-userfile", false, &rsv) == -EINVAL,
          "create in mv namespace rejected");
    fntfs_attrs anyf;
    CHECK(fntfs_create(v, root, "any.txt", false, &anyf) == 0, "create any");
    CHECK(fntfs_link(v, anyf.inum, root, ".mntfs-del-alias") == -EINVAL,
          "link into ghost namespace rejected");
    CHECK(fntfs_rename(v, anyf.inum, root, "any.txt",
                       root, ".mntfs-mv-evil", 0) == -EINVAL,
          "rename into ghost namespace rejected");

    /* a FOREIGN file that merely starts with the prefix (e.g. created on
       Windows) must stay visible and must survive the mount sweep */
    CHECK(fntfs_test_link_raw(v, anyf.inum, root, ".mntfs-del-hello") == 0,
          "raw link foreign-style name");
    CHECK(fntfs_remove(v, root, "any.txt", anyf.inum) == 0, "drop real name");
    struct entlist elf = {0};
    CHECK(fntfs_readdir(v, root, 0, &elf, collect_cb) == 0, "readdir foreign");
    CHECK(list_has(&elf, ".mntfs-del-hello") >= 0,
          "foreign prefix-named file stays visible");

    /* --- crashed rename simulation: mv-ghost as the file's LAST name must
           be RECOVERED by the sweep, never deleted --- */
    fntfs_attrs strand;
    CHECK(fntfs_create(v, root, "victim2.txt", false, &strand) == 0,
          "create victim2");
    CHECK(fntfs_write(v, strand.inum, "PRECIOUS", 8, 0) == 8, "write victim2");
    char mvghost[64];
    snprintf(mvghost, sizeof mvghost, ".mntfs-mv-%08lx-%llx", 1ul,
             (unsigned long long)strand.inum);
    CHECK(fntfs_test_link_raw(v, strand.inum, root, mvghost) == 0,
          "raw link mv ghost");
    CHECK(fntfs_remove(v, root, "victim2.txt", strand.inum) == 0,
          "drop victim2 real name (simulate crash mid-rename)");

    /* redundant mv-ghost (extra leaked link): sweep may safely remove it */
    fntfs_attrs redun;
    CHECK(fntfs_create(v, root, "stays.txt", false, &redun) == 0,
          "create stays");
    char mvghost2[64];
    snprintf(mvghost2, sizeof mvghost2, ".mntfs-mv-%08lx-%llx", 2ul,
             (unsigned long long)redun.inum);
    CHECK(fntfs_test_link_raw(v, redun.inum, root, mvghost2) == 0,
          "raw link redundant mv ghost");

    /* leave one del-ghost behind on purpose: the next rw mount sweeps it */
    fntfs_attrs ou2;
    CHECK(fntfs_create(v, root, "crashfile.txt", false, &ou2) == 0,
          "create crashfile");
    char ghost2[64];
    CHECK(fntfs_unlink_keep(v, root, "crashfile.txt", ou2.inum, ghost2) == 0,
          "unlink_keep crashfile");
    CHECK(ghost2[0] != '\0', "crashfile parked under a ghost");
    CHECK(fntfs_getattr(v, ou2.inum, &a) == 0 &&
          (a.win_attrs & FNTFS_WINATTR_HIDDEN), "parked ghost is hidden");
    printf("open-unlink semantics ok\n");

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
    tset.atime_sec = 978307200; /* 2001-01-01, distinct from MFT change time */
    tset.crtime_sec = 915148800; /* 1999-01-01 */
    CHECK(fntfs_settimes(v, fa.inum, &tset,
                         FNTFS_SET_MTIME | FNTFS_SET_ATIME | FNTFS_SET_CRTIME) == 0,
          "settimes");
    CHECK(fntfs_getattr(v, fa.inum, &a) == 0 && a.mtime_sec == 946684800,
          "mtime=%lld", (long long)a.mtime_sec);
    CHECK(a.atime_sec == tset.atime_sec && a.crtime_sec == tset.crtime_sec,
          "access/birth times not applied");
    CHECK(fntfs_forget(v, fa.inum) == 0, "flush times");
    CHECK(fntfs_getattr(v, fa.inum, &a) == 0 && a.atime_sec == tset.atime_sec,
          "access time must persist after inode reopen");
    // Setter succeeds in memory, but inode close writes the changed metadata.
    // A close failure must be returned to the caller.
    g_fail_writes = 100; // Keep failing through libntfs-3g's internal retries.
    CHECK(fntfs_settimes(v, fa.inum, &tset, FNTFS_SET_ATIME) < 0,
          "settimes must propagate inode close failure");
    g_fail_writes = 0;

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

    /* --- remount, verify persistence + ghost sweep --- */
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
    /* the ghost left by the "crashed" unlink_keep must have been swept */
    CHECK(fntfs_lookup(v, root, ghost2, &la) == -ENOENT,
          "leftover del ghost swept at remount");
    /* the stranded mv-ghost was RECOVERED, not deleted */
    CHECK(fntfs_lookup(v, root, mvghost, &la) == -ENOENT,
          "stranded mv ghost gone");
    char recname[80];
    snprintf(recname, sizeof recname, "mntfs-recovered-%s",
             mvghost + strlen(".mntfs-mv-"));
    CHECK(fntfs_lookup(v, root, recname, &la) == 0 && la.inum == strand.inum,
          "stranded file recovered under visible name");
    r = fntfs_read(v, strand.inum, rbuf, 8, 0);
    CHECK(r == 8 && !memcmp(rbuf, "PRECIOUS", 8), "recovered data intact");
    /* the redundant mv-ghost was removed, its real name survives */
    CHECK(fntfs_lookup(v, root, mvghost2, &la) == -ENOENT,
          "redundant mv ghost removed");
    CHECK(fntfs_lookup(v, root, "stays.txt", &la) == 0 && la.inum == redun.inum,
          "real name of redundant-ghost file intact");
    /* the foreign prefix-named file survived the sweep untouched */
    CHECK(fntfs_lookup(v, root, ".mntfs-del-hello", &la) == 0 &&
          la.inum == anyf.inum, "foreign prefix-named file survived sweep");
    CHECK(fntfs_unmount(v) == 0, "unmount 2");
    printf("ghost sweep ok (del swept, stranded recovered, foreign kept)\n");

    /* --- consistency check on the (clean) unmounted image --- */
    uint32_t vstate = 0xffffffffu;
    CHECK(fntfs_check_state(NULL, cb_pread, dev_size, SECTOR, &vstate) == 0,
          "check_state");
    CHECK(vstate == 0, "volume should be clean, state=0x%x", vstate);
    printf("check_state ok (clean)\n");

    /* --- bounce-buffer clamping (white-box; trashes the image, keep last) --- */
    char pat[300], chk[600];
    for (int i = 0; i < 300; i++) pat[i] = (char)(i ^ 0x5a);

    g_max_io = 0;
    CHECK(fntfs_test_pwrite_aligned(NULL, cb_pread, cb_pwrite, dev_size,
                                    SECTOR, pat, 3, 1) == 3,
          "tiny unaligned write");
    CHECK(g_max_io == SECTOR, "3-byte write did %lld-byte I/O, want %d",
          (long long)g_max_io, SECTOR);

    g_max_io = 0;
    CHECK(fntfs_test_pwrite_aligned(NULL, cb_pread, cb_pwrite, dev_size,
                                    SECTOR, pat, 2, SECTOR - 1) == 2,
          "sector-straddling write");
    CHECK(g_max_io == 2 * SECTOR, "straddle did %lld-byte I/O, want %d",
          (long long)g_max_io, 2 * SECTOR);

    g_max_io = 0;
    CHECK(fntfs_test_pread_aligned(NULL, cb_pread, dev_size, SECTOR,
                                   chk, 5, 7) == 5, "tiny unaligned read");
    CHECK(g_max_io == SECTOR, "5-byte read did %lld-byte I/O, want %d",
          (long long)g_max_io, SECTOR);

    CHECK(fntfs_test_pwrite_aligned(NULL, cb_pread, cb_pwrite, dev_size,
                                    SECTOR, pat, 300, 777) == 300,
          "pattern write");
    memset(chk, 0, sizeof chk);
    CHECK(fntfs_test_pread_aligned(NULL, cb_pread, dev_size, SECTOR,
                                   chk, 300, 777) == 300, "pattern read");
    CHECK(!memcmp(chk, pat, 300), "unaligned roundtrip intact");

    size_t bigw = (2u << 20) + 5;
    char *bw = malloc(bigw);
    for (size_t i = 0; i < bigw; i++) bw[i] = (char)i;
    g_max_io = 0;
    CHECK(fntfs_test_pwrite_aligned(NULL, cb_pread, cb_pwrite, dev_size, SECTOR,
                                    bw, (int64_t)bigw, 1) == (int64_t)bigw,
          "large unaligned write");
    CHECK(g_max_io == (1 << 20), "large write chunked at %lld, want %d",
          (long long)g_max_io, 1 << 20);
    free(bw);
    printf("bounce clamping ok\n");

    close(g_fd);
    printf("ALL TESTS PASSED\n");
    return 0;
}
