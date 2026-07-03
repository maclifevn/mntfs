/*
 * bench_fntfs.c — throughput benchmark for the fntfs engine.
 *
 * Measures sequential write and read through the full bridge stack
 * (fntfs API → libntfs-3g → device callbacks) against an image file,
 * plus a raw pread/pwrite baseline for the same file as the ceiling.
 *
 * Usage: bench_fntfs <image> <MB>
 */

#include "../Sources/FSModule/Bridge/fntfs.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define SECTOR 512
#define CHUNK (1 << 20)

static int g_fd;

static int64_t cb_pread(void *ctx, void *buf, int64_t count, int64_t offset)
{ (void)ctx; ssize_t r = pread(g_fd, buf, (size_t)count, offset); return r < 0 ? -errno : r; }
static int64_t cb_pwrite(void *ctx, const void *buf, int64_t count, int64_t offset)
{ (void)ctx; ssize_t r = pwrite(g_fd, buf, (size_t)count, offset); return r < 0 ? -errno : r; }
static int cb_flush(void *ctx) { (void)ctx; return fsync(g_fd) < 0 ? -errno : 0; }

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: %s <image> <MB>\n", argv[0]); return 1; }
    long mb = atol(argv[2]);
    g_fd = open(argv[1], O_RDWR);
    if (g_fd < 0) { perror("open"); return 1; }
    struct stat st; fstat(g_fd, &st);

    char *buf = malloc(CHUNK);
    for (int i = 0; i < CHUNK; i++) buf[i] = (char)(i * 131 + 17);

    int err = 0;
    fntfs_vol *v = fntfs_mount(buf, cb_pread, cb_pwrite, cb_flush,
                               (uint64_t)st.st_size, SECTOR, false,
                               NULL, NULL, &err);
    if (!v) { fprintf(stderr, "mount err %d\n", err); return 1; }

    uint64_t root = fntfs_root_inum();
    fntfs_attrs fa;
    if (fntfs_create(v, root, "bench.bin", false, &fa) != 0) {
        fntfs_attrs la;
        if (fntfs_lookup(v, root, "bench.bin", &la) != 0) return 1;
        fa = la;
    }

    /* sequential write */
    double t0 = now();
    for (long i = 0; i < mb; i++) {
        int64_t w = fntfs_write(v, fa.inum, buf, CHUNK, (int64_t)i * CHUNK);
        if (w != CHUNK) { fprintf(stderr, "write fail @%ld: %lld\n", i, (long long)w); return 1; }
    }
    fntfs_sync(v);
    double tw = now() - t0;

    /* sequential read */
    t0 = now();
    for (long i = 0; i < mb; i++) {
        int64_t r = fntfs_read(v, fa.inum, buf, CHUNK, (int64_t)i * CHUNK);
        if (r != CHUNK) { fprintf(stderr, "read fail @%ld: %lld\n", i, (long long)r); return 1; }
    }
    double tr = now() - t0;

    printf("fntfs engine:  write %6.1f MB/s   read %6.1f MB/s   (%ld MB)\n",
           mb / tw, mb / tr, mb);

    fntfs_unmount(v);

    /* raw file baseline */
    t0 = now();
    for (long i = 0; i < mb; i++)
        if (pwrite(g_fd, buf, CHUNK, (off_t)i * CHUNK) != CHUNK) return 1;
    fsync(g_fd);
    double bw = now() - t0;
    t0 = now();
    for (long i = 0; i < mb; i++)
        if (pread(g_fd, buf, CHUNK, (off_t)i * CHUNK) != CHUNK) return 1;
    double br = now() - t0;
    printf("raw baseline:  write %6.1f MB/s   read %6.1f MB/s\n", mb / bw, mb / br);

    close(g_fd);
    return 0;
}
