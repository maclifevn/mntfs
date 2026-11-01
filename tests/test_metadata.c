/* Real NTFS metadata round trips; all fixtures live in a disposable image. */
#include "../Sources/FSModule/Bridge/fntfs.h"
#include "../vendor/ntfs-3g/config.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "volume.h"
#include "inode.h"
#include "attrib.h"
#include "dir.h"
#include "unistr.h"
#include "reparse.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL metadata:%d: %s (errno=%d)\n", __LINE__, #x, errno); exit(1); } } while (0)
static int fd, fail_writes;
static int64_t rd(void *c, void *b, int64_t n, int64_t o) {
    (void)c; ssize_t r = pread(fd, b, n, o); return r < 0 ? -errno : r;
}
static int64_t wr(void *c, const void *b, int64_t n, int64_t o) {
    (void)c; if (fail_writes) { --fail_writes; return -EIO; }
    ssize_t r = pwrite(fd, b, n, o); return r < 0 ? -errno : r;
}
static int flush(void *c) { (void)c; return fsync(fd) ? -errno : 0; }
static void check_link(fntfs_vol *v, uint64_t dir, const char *name, const char *target) {
    fntfs_attrs a; CHECK(!fntfs_lookup(v, dir, name, &a));
    CHECK(a.type == FNTFS_TYPE_SYMLINK);
    char out[4096]; int64_t n = fntfs_readlink(v, a.inum, out, sizeof(out));
    if (n != (int64_t)strlen(target)) fprintf(stderr, "link %s: length=%lld expected=%zu\n", name, (long long)n, strlen(target));
    CHECK(n == (int64_t)strlen(target)); CHECK(!memcmp(out, target, n));
    CHECK(a.size == (uint64_t)n);
    CHECK(fntfs_readlink(v, a.inum, out, 1) == -ERANGE);
}

static void windows_link(ntfs_volume *v, ntfs_inode *parent, const char *name,
                          const char *target, bool junction) {
    ntfschar *un = NULL, *ut = NULL;
    int nl = ntfs_mbstoucs(name, &un), tl = ntfs_mbstoucs(target, &ut);
    CHECK(nl > 0 && tl > 0);
    ntfs_inode *ni = ntfs_create(parent, 0, un, nl, junction ? S_IFDIR : S_IFREG); CHECK(ni);
    size_t header = junction ? 16 : 20, bytes = header + 4 * tl;
    char *raw = calloc(1, bytes); CHECK(raw);
    le32 tag = junction ? IO_REPARSE_TAG_MOUNT_POINT : IO_REPARSE_TAG_SYMLINK;
    le16 length = cpu_to_le16(bytes - 8), pathlen = cpu_to_le16(2 * tl), printoff = pathlen;
    memcpy(raw, &tag, 4); memcpy(raw + 4, &length, 2);
    memcpy(raw + 10, &pathlen, 2); memcpy(raw + 12, &printoff, 2); memcpy(raw + 14, &pathlen, 2);
    if (!junction) { le32 relative = cpu_to_le32(1); memcpy(raw + 16, &relative, 4); }
    memcpy(raw + header, ut, 2 * tl); memcpy(raw + header + 2 * tl, ut, 2 * tl);
    CHECK(!ntfs_set_ntfs_reparse_data(ni, raw, bytes, 0));
    CHECK(!ntfs_inode_close_in_dir(ni, parent));
    free(un); free(ut); free(raw); (void)v;
}

int main(int argc, char **argv) {
    CHECK(argc == 2); fd = open(argv[1], O_RDWR); CHECK(fd >= 0);
    struct stat st; CHECK(!fstat(fd, &st)); int err = 0;
    fntfs_vol *v = fntfs_mount(NULL, rd, wr, flush, st.st_size, 512, false, NULL, NULL, &err);
    CHECK(v && !fntfs_is_readonly(v));
    uint64_t root = fntfs_root_inum(); fntfs_attrs file, link, dir;
    CHECK(!fntfs_create(v, root, "target.txt", false, &file));
    CHECK(fntfs_write(v, file.inum, "main-data", 9, 0) == 9);
    CHECK(!fntfs_create(v, root, "targetdir", true, &dir));
    CHECK(!fntfs_symlink(v, root, "relative-link", "target.txt", &link));
    check_link(v, root, "relative-link", "target.txt");
    CHECK(fntfs_symlink(v, root, "RELATIVE-LINK", "missing", &link) == -EEXIST);
    CHECK(!fntfs_symlink(v, root, "dangling-link", "missing/Đường dẫn", &link));
    check_link(v, root, "dangling-link", "missing/Đường dẫn");
    CHECK(!fntfs_symlink(v, root, "absolute-link", "/tmp/Đích", &link));
    check_link(v, root, "absolute-link", "/tmp/Đích");
    CHECK(fntfs_symlink(v, root, "bad/name", "x", &link) == -EINVAL);
    CHECK(fntfs_symlink(v, root, "empty-link", "", &link) == -EINVAL);

    const char zone[] = "[ZoneTransfer]\r\nZoneId=3\r\n";
    CHECK(!fntfs_setxattr(v, file.inum, "Zone.Identifier", zone, sizeof(zone), FNTFS_XATTR_CREATE));
    CHECK(fntfs_setxattr(v, file.inum, "Zone.Identifier", zone, sizeof(zone), FNTFS_XATTR_CREATE) == -EEXIST);
    CHECK(fntfs_setxattr(v, file.inum, "absent", zone, sizeof(zone), FNTFS_XATTR_REPLACE) == -ENOATTR);
    CHECK(!fntfs_setxattr(v, file.inum, "com.apple.ResourceFork", NULL, 0, FNTFS_XATTR_SET));
    CHECK(fntfs_getxattr(v, file.inum, "com.apple.ResourceFork", NULL, 0) == 0);
    CHECK(!fntfs_setxattr(v, dir.inum, "ghi.chú", "Unicode", 7, FNTFS_XATTR_SET));
    CHECK(!fntfs_setxattr(v, file.inum, "note.\xc3\xa9", "NFC", 3, FNTFS_XATTR_SET));
    CHECK(!fntfs_setxattr(v, file.inum, "note.e\xcc\x81", "NFD", 3, FNTFS_XATTR_SET));
    char out[65536];
    CHECK(fntfs_getxattr(v, file.inum, "note.\xc3\xa9", out, sizeof(out)) == 3 && !memcmp(out, "NFC", 3));
    CHECK(fntfs_getxattr(v, file.inum, "note.e\xcc\x81", out, sizeof(out)) == 3 && !memcmp(out, "NFD", 3));
    CHECK(fntfs_getxattr(v, file.inum, "Zone.Identifier", out, 1) == -ERANGE);
    CHECK(fntfs_getxattr(v, file.inum, "Zone.Identifier", out, sizeof(out)) == sizeof(zone));
    CHECK(!memcmp(out, zone, sizeof(zone)));
    int64_t list_size = fntfs_listxattr(v, file.inum, NULL, 0); CHECK(list_size > 0);
    CHECK(fntfs_listxattr(v, file.inum, out, 1) == -ERANGE);
    CHECK(fntfs_listxattr(v, file.inum, out, sizeof(out)) == list_size);
    CHECK(!fntfs_setxattr(v, file.inum, "com.apple.ResourceFork", NULL, 0, FNTFS_XATTR_DELETE));
    CHECK(fntfs_getxattr(v, file.inum, "com.apple.ResourceFork", NULL, 0) == -ENOATTR);
    CHECK(fntfs_setxattr(v, file.inum, "too-large", NULL, FNTFS_MAX_XATTR_SIZE + 1, FNTFS_XATTR_SET) == -E2BIG);

    char previous[32768], replacement[32768]; memset(previous, 'A', sizeof(previous)); memset(replacement, 'B', sizeof(replacement));
    CHECK(!fntfs_setxattr(v, file.inum, "rollback", previous, sizeof(previous), FNTFS_XATTR_SET));
    CHECK(!fntfs_sync(v)); fail_writes = 1;
    CHECK(fntfs_setxattr(v, file.inum, "rollback", replacement, sizeof(replacement), FNTFS_XATTR_REPLACE) < 0);
    CHECK(fntfs_getxattr(v, file.inum, "rollback", out, sizeof(out)) == sizeof(previous));
    CHECK(!memcmp(out, previous, sizeof(previous)));
    CHECK(fntfs_read(v, file.inum, out, sizeof(out), 0) == 9 && !memcmp(out, "main-data", 9));
    CHECK(fntfs_is_readonly(v) && fntfs_io_error(v) == EIO);
    CHECK(fntfs_unmount(v) == -EIO);

    /* Verify actual NTFS streams independently of the bridge, and prepare
       Windows-native reparse points as cross-implementation fixtures. */
    ntfs_volume *nv = ntfs_mount(argv[1], 0); CHECK(nv);
    ntfs_inode *ni = ntfs_inode_open(nv, file.inum); CHECK(ni);
    ntfschar *un = NULL; int nl = ntfs_mbstoucs("Zone.Identifier", &un);
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, un, nl); CHECK(na);
    CHECK(ntfs_attr_pread(na, 0, sizeof(zone), out) == sizeof(zone) && !memcmp(out, zone, sizeof(zone)));
    ntfs_attr_close(na); free(un); un = NULL;
    nl = ntfs_mbstoucs("rollback", &un);
    na = ntfs_attr_open(ni, AT_DATA, un, nl); CHECK(na);
    CHECK(ntfs_attr_pread(na, 0, sizeof(previous), out) == sizeof(previous));
    CHECK(!memcmp(out, previous, sizeof(previous)));
    ntfs_attr_close(na); free(un); CHECK(!ntfs_inode_close(ni));
    ni = ntfs_inode_open(nv, FILE_root); CHECK(ni);
    windows_link(nv, ni, "windows-link", "target.txt", false);
    windows_link(nv, ni, "windows-dangling", "missing/file", false);
    windows_link(nv, ni, "junction", "\\??\\C:\\targetdir", true);
    windows_link(nv, ni, "foreign-junction", "\\??\\Z:\\missing", true);
    ntfschar *opaque_name = NULL; int opaque_len = ntfs_mbstoucs("opaque-reparse", &opaque_name);
    ntfs_inode *opaque = ntfs_create(ni, 0, opaque_name, opaque_len, S_IFREG); CHECK(opaque);
    REPARSE_POINT raw = { .reparse_tag = cpu_to_le32(0x80000042), .reparse_data_length = 0, .reserved = 0 };
    CHECK(!ntfs_set_ntfs_reparse_data(opaque, (const char *)&raw, sizeof(raw), 0));
    CHECK(!ntfs_inode_close_in_dir(opaque, ni)); free(opaque_name);
    CHECK(!ntfs_inode_close(ni)); CHECK(!ntfs_umount(nv, false));

    v = fntfs_mount(NULL, rd, wr, flush, st.st_size, 512, false, NULL, NULL, &err); CHECK(v);
    check_link(v, root, "relative-link", "target.txt");
    check_link(v, root, "dangling-link", "missing/Đường dẫn");
    check_link(v, root, "windows-link", "target.txt");
    check_link(v, root, "windows-dangling", "missing/file");
    check_link(v, root, "junction", "targetdir");
    CHECK(!fntfs_lookup(v, root, "foreign-junction", &link));
    CHECK(fntfs_readlink(v, link.inum, out, sizeof(out)) == -ENOTSUP);
    CHECK(fntfs_get_reparse(v, link.inum, out, sizeof(out)) > 8);
    CHECK(fntfs_write(v, link.inum, "x", 1, 0) == -ENOTSUP);
    CHECK(!fntfs_lookup(v, root, "opaque-reparse", &link));
    CHECK(link.type == FNTFS_TYPE_REPARSE && link.reparse_tag == 0x80000042);
    CHECK(fntfs_read(v, link.inum, out, sizeof(out), 0) == -ENOTSUP);
    CHECK(fntfs_truncate(v, link.inum, 0) == -ENOTSUP);
    CHECK(fntfs_get_reparse(v, link.inum, out, sizeof(out)) == sizeof(raw));
    CHECK(!fntfs_unmount(v));
    v = fntfs_mount(NULL, rd, NULL, NULL, st.st_size, 512, true, NULL, NULL, &err); CHECK(v);
    CHECK(fntfs_setxattr(v, file.inum, "Zone.Identifier", NULL, 0, FNTFS_XATTR_DELETE) == -EROFS);
    CHECK(fntfs_symlink(v, root, "ro-link", "x", &link) == -EROFS);
    CHECK(!fntfs_unmount(v)); close(fd);
    puts("Metadata tests passed (WSL/Windows links, junctions, Unicode, ADS, rollback, independent NTFS readback, read-only)");
}
