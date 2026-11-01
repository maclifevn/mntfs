/* A failed device must never receive more writes through a live handle,
   including libntfs-3g cleanup. Each run uses one disposable image. */
#include "../Sources/FSModule/Bridge/fntfs.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static int fd, writes, flushes;
static enum { HEALTHY, WRITE_ERROR, SHORT_WRITE, READ_ERROR, FLUSH_ERROR } failure;
static int64_t rd(void *c, void *b, int64_t n, int64_t o) {
    (void)c;
    if (failure == READ_ERROR) return -ENXIO;
    ssize_t r = pread(fd, b, n, o); return r < 0 ? -errno : r;
}
static int64_t wr(void *c, const void *b, int64_t n, int64_t o) {
    (void)c; writes++;
    if (failure == WRITE_ERROR) return -EIO;
    if (failure == SHORT_WRITE) return pwrite(fd, b, n / 2, o);
    ssize_t r = pwrite(fd, b, n, o); return r < 0 ? -errno : r;
}
static int flush(void *c) {
    (void)c; flushes++;
    return failure == FLUSH_ERROR ? -EIO : (fsync(fd) ? -errno : 0);
}
int main(int argc, char **argv) {
    CHECK(argc == 3);
    fd = open(argv[1], O_RDWR); CHECK(fd >= 0);
    struct stat st; CHECK(!fstat(fd, &st)); int err = 0;
    fntfs_vol *v = fntfs_mount(NULL, rd, wr, flush, st.st_size, 512, false, NULL, NULL, &err);
    CHECK(v && !fntfs_is_readonly(v) && fntfs_io_error(v) == 0);
    fntfs_attrs file, unused;
    uint64_t root = fntfs_root_inum();
    CHECK(!fntfs_create(v, root, "existing", false, &file));
    enum { LENGTH = 1 << 20 };
    unsigned char *data = malloc(LENGTH); CHECK(data); memset(data, 0x41, LENGTH);
    CHECK(fntfs_write(v, file.inum, data, LENGTH, 0) == LENGTH);
    CHECK(!fntfs_sync(v));
    CHECK(fntfs_create(v, root, "existing", false, &unused) == -EEXIST);
    CHECK(fntfs_lookup(v, root, "missing", &unused) == -ENOENT);
    CHECK(!fntfs_is_readonly(v) && fntfs_io_error(v) == 0);

    if (!strcmp(argv[2], "write")) failure = WRITE_ERROR;
    else if (!strcmp(argv[2], "short-write")) failure = SHORT_WRITE;
    else if (!strcmp(argv[2], "read")) failure = READ_ERROR;
    else if (!strcmp(argv[2], "flush")) failure = FLUSH_ERROR;
    else CHECK(0);
    int expected = failure == READ_ERROR ? ENXIO : EIO;
    if (failure == FLUSH_ERROR) CHECK(fntfs_sync(v) == -EIO);
    else if (failure == READ_ERROR) CHECK(fntfs_read(v, file.inum, data, LENGTH, 0) < 0);
    else CHECK(fntfs_write(v, file.inum, data, LENGTH, 0) < LENGTH);
    CHECK(fntfs_is_readonly(v) && fntfs_io_error(v) == expected);
    int writes_at_failure = writes, flushes_at_failure = flushes;
    failure = HEALTHY; /* Hardware recovery must not silently re-enable writing. */
    CHECK(fntfs_write(v, file.inum, data, 512, 0) == -EROFS);
    CHECK(fntfs_create(v, root, "blocked", false, &unused) == -EROFS);
    CHECK(fntfs_truncate(v, file.inum, 0) == -EROFS);
    CHECK(fntfs_remove(v, root, "existing", file.inum) == -EROFS);
    CHECK(fntfs_link(v, file.inum, root, "blocked-link") == -EROFS);
    CHECK(fntfs_setxattr(v, file.inum, "blocked-stream", data, 1, FNTFS_XATTR_SET) == -EROFS);
    CHECK(fntfs_sync(v) == -expected);
    CHECK(fntfs_io_error(v) == expected);
    CHECK(fntfs_unmount(v) == -expected);
    CHECK(writes == writes_at_failure && flushes == flushes_at_failure);

    v = fntfs_mount(NULL, rd, NULL, NULL, st.st_size, 512, true, NULL, NULL, &err);
    CHECK(v && fntfs_is_readonly(v) && !fntfs_io_error(v));
    CHECK(!fntfs_sync(v) && !fntfs_unmount(v));
    free(data); close(fd);
    printf("Error latch passed (%s): all new mutations blocked, first error retained, no backend writes during cleanup\n", argv[2]);
    return 0;
}
