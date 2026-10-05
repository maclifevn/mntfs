/*
 * bench_fntfs.c — throughput benchmark for the fntfs engine.
 *
 * Measures sequential write and read through the full bridge stack
 * (fntfs API → libntfs-3g → device callbacks) against an image file,
 * plus a raw pread/pwrite baseline for the same file as the ceiling.
 *
 * Usage: bench_fntfs <image> <MiB> [chunk-KiB] [device-latency-us]
 * Only use a disposable image. The raw baseline uses a separate scratch file
 * beside the image, so it never overwrites the NTFS boot sector.
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
static int g_fd;
static long g_latency_us;
static uint64_t g_reads, g_writes, g_read_bytes, g_write_bytes;

static void device_delay(void)
{
    struct timespec ts = { g_latency_us / 1000000,
                           (g_latency_us % 1000000) * 1000 };
    while (nanosleep(&ts, &ts) && errno == EINTR) {}
}

static int64_t cb_pread(void *ctx, void *buf, int64_t count, int64_t offset)
{
    (void)ctx;
    g_reads++; g_read_bytes += count;
    if (g_latency_us) device_delay();
    ssize_t r = pread(g_fd, buf, (size_t)count, offset);
    return r < 0 ? -errno : r;
}
static int64_t cb_pwrite(void *ctx, const void *buf, int64_t count, int64_t offset)
{
    (void)ctx;
    g_writes++; g_write_bytes += count;
    if (g_latency_us) device_delay();
    ssize_t r = pwrite(g_fd, buf, (size_t)count, offset);
    return r < 0 ? -errno : r;
}
static int cb_flush(void *ctx) { (void)ctx; return fsync(g_fd) < 0 ? -errno : 0; }

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    if (argc < 3 || argc > 5) {
        fprintf(stderr, "usage: %s <image> <MiB> [chunk-KiB] [device-latency-us]\n", argv[0]);
        return 1;
    }
    long mb = atol(argv[2]);
    long kib = argc > 3 ? atol(argv[3]) : 1024;
    g_latency_us = argc > 4 ? atol(argv[4]) : 0;
    if (mb <= 0 || mb > 1048576 || kib <= 0 || kib > 1024 ||
        g_latency_us < 0 || g_latency_us > 1000000) return 1;
    size_t chunk = (size_t)kib << 10;
    int64_t bytes = (int64_t)mb << 20;
    g_fd = open(argv[1], O_RDWR);
    if (g_fd < 0) { perror("open"); return 1; }
    struct stat st; fstat(g_fd, &st);

    char *buf = malloc(chunk), *readbuf = malloc(chunk);
    if (!buf || !readbuf) return 1;
    for (size_t i = 0; i < chunk; i++) buf[i] = (char)(i * 131 + 17);

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
    if (fntfs_truncate(v, fa.inum, 0)) return 1;

    /* sequential write */
    g_reads = g_writes = g_read_bytes = g_write_bytes = 0;
    double t0 = now();
    for (int64_t off = 0; off < bytes; off += chunk) {
        int64_t len = bytes - off < (int64_t)chunk ? bytes - off : (int64_t)chunk;
        int64_t w = fntfs_write(v, fa.inum, buf, len, off);
        if (w != len) { fprintf(stderr, "write fail @%lld: %lld\n", (long long)off, (long long)w); return 1; }
    }
    if (fntfs_sync(v)) return 1;
    double tw = now() - t0;
    printf("write device I/O: %llu reads (%llu bytes), %llu writes (%llu bytes)\n",
           (unsigned long long)g_reads, (unsigned long long)g_read_bytes,
           (unsigned long long)g_writes, (unsigned long long)g_write_bytes);

    /* Reopen to verify that all bytes and the final size persisted. */
    if (fntfs_unmount(v)) return 1;
    v = fntfs_mount(NULL, cb_pread, cb_pwrite, cb_flush, st.st_size, SECTOR,
                    false, NULL, NULL, &err);
    if (!v || fntfs_lookup(v, root, "bench.bin", &fa) || fa.size != (uint64_t)bytes)
        return 1;

    /* sequential read */
    t0 = now();
    for (int64_t off = 0; off < bytes; off += chunk) {
        int64_t len = bytes - off < (int64_t)chunk ? bytes - off : (int64_t)chunk;
        int64_t r = fntfs_read(v, fa.inum, readbuf, len, off);
        if (r != len || memcmp(buf, readbuf, (size_t)len)) {
            fprintf(stderr, "read/verify fail @%lld\n", (long long)off); return 1;
        }
    }
    double tr = now() - t0;

    printf("fntfs engine:  write %6.1f MiB/s   read %6.1f MiB/s   (%ld MiB, %ld KiB/call, %ld us/device-call)\n",
           mb / tw, mb / tr, mb, kib, g_latency_us);

    if (fntfs_unmount(v)) return 1;
    close(g_fd);

    char *scratch = malloc(strlen(argv[1]) + 16);
    if (!scratch) return 1;
    sprintf(scratch, "%s.raw-XXXXXX", argv[1]);
    g_fd = mkstemp(scratch);
    if (g_fd < 0) { perror("mkstemp"); return 1; }
    unlink(scratch);
    free(scratch);

    /* raw file baseline */
    t0 = now();
    for (int64_t off = 0; off < bytes; off += chunk) {
        int64_t len = bytes - off < (int64_t)chunk ? bytes - off : (int64_t)chunk;
        if (cb_pwrite(NULL, buf, len, off) != len) return 1;
    }
    if (cb_flush(NULL)) return 1;
    double bw = now() - t0;
    t0 = now();
    for (int64_t off = 0; off < bytes; off += chunk) {
        int64_t len = bytes - off < (int64_t)chunk ? bytes - off : (int64_t)chunk;
        if (cb_pread(NULL, readbuf, len, off) != len || memcmp(buf, readbuf, (size_t)len))
            return 1;
    }
    double br = now() - t0;
    printf("raw baseline:  write %6.1f MiB/s   read %6.1f MiB/s\n", mb / bw, mb / br);

    close(g_fd);
    free(buf); free(readbuf);
    return 0;
}
