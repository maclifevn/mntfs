/* Process crash and injected-device failures on a disposable NTFS image.
   This tests acknowledged sync, not physical USB power-loss guarantees. */
#include "../Sources/FSModule/Bridge/fntfs.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static int fd, failure;
static uint64_t size;
static int64_t rd(void *c, void *b, int64_t n, int64_t o) {
    (void)c; if (failure == ENXIO) return -ENXIO;
    ssize_t r = pread(fd, b, n, o); return r < 0 ? -errno : r;
}
static int64_t wr(void *c, const void *b, int64_t n, int64_t o) {
    (void)c; if (failure == ENXIO) return -ENXIO;
    ssize_t r = pwrite(fd, b, n, o); return r < 0 ? -errno : r;
}
static int flush(void *c) { (void)c; return failure ? -failure : (fsync(fd) ? -errno : 0); }
static fntfs_vol *mount_image(void) {
    int err; fntfs_vol *v = fntfs_mount(NULL, rd, wr, flush, size, 512, false, NULL, NULL, &err);
    CHECK(v && !fntfs_is_readonly(v)); return v;
}
int main(int argc, char **argv) {
    CHECK(argc == 2); fd = open(argv[1], O_RDWR); CHECK(fd >= 0);
    struct stat st; CHECK(!fstat(fd, &st)); size = st.st_size;
    enum { LENGTH = 1024 * 1024 + 17 };
    unsigned char *expected = malloc(LENGTH), *actual = malloc(LENGTH);
    CHECK(expected && actual);
    for (size_t i = 0; i < LENGTH; ++i) expected[i] = (unsigned char)(i * 37 + 11);
    pid_t child = fork(); CHECK(child >= 0);
    if (!child) {
        fntfs_vol *v = mount_image(); fntfs_attrs a;
        CHECK(!fntfs_create(v, fntfs_root_inum(), "synced-before-crash", false, &a));
        CHECK(fntfs_write(v, a.inum, expected, LENGTH, 0) == LENGTH);
        CHECK(!fntfs_sync(v));
        _exit(0); /* Deliberately skip every close/unmount/destructor. */
    }
    int status; CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    fntfs_vol *v = mount_image(); fntfs_attrs a;
    CHECK(!fntfs_lookup(v, fntfs_root_inum(), "synced-before-crash", &a));
    CHECK(a.size == LENGTH);
    CHECK(fntfs_read(v, a.inum, actual, LENGTH, 0) == LENGTH);
    CHECK(!memcmp(actual, expected, LENGTH));
    failure = EIO;
    CHECK(fntfs_sync(v) == -EIO);
    CHECK(fntfs_unmount(v) == -EIO);
    failure = 0;
    v = mount_image();
    failure = ENXIO; /* Model loss of the device, without unplugging hardware. */
    /* libntfs-3g may translate a failed metadata operation to EIO or EBUSY. */
    int sync_error = fntfs_sync(v);
    CHECK(sync_error == -ENXIO || sync_error == -EIO || sync_error == -EBUSY);
    int unmount_error = fntfs_unmount(v);
    CHECK(unmount_error == -ENXIO || unmount_error == -EIO || unmount_error == -EBUSY);
    free(expected); free(actual); close(fd);
    puts("Durability tests passed (sync then abrupt exit, content verification, failed flush/unmount, unplug)");
    return 0;
}
