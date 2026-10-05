/* White-box regression tests for cache coherence and edge-sector I/O.
   Uses memory only; never opens a real disk. */
#include "../Sources/FSModule/Bridge/fntfs.c"
#include <assert.h>

enum { DISK_SIZE = 4 << 20 };
static unsigned char disk[DISK_SIZE];
static int64_t read_bytes, write_bytes;
static int reads, writes;
static uint32_t sector;
static bool fail_write;
static bool short_read;

static int64_t memory_read(void *ctx, void *buf, int64_t len, int64_t off)
{
    (void)ctx;
    assert(off >= 0 && len > 0 && off + len <= DISK_SIZE);
    assert(off % sector == 0 && len % sector == 0);
    reads++; read_bytes += len;
    if (short_read) { short_read = false; return 0; }
    memcpy(buf, disk + off, len);
    return len;
}

static int64_t memory_write(void *ctx, const void *buf, int64_t len, int64_t off)
{
    (void)ctx;
    assert(off >= 0 && len > 0 && off + len <= DISK_SIZE);
    assert(off % sector == 0 && len % sector == 0);
    writes++; write_bytes += len;
    if (fail_write) {
        /* A device may change some bytes before reporting failure. */
        memcpy(disk + off, buf, sector);
        fail_write = false;
        return -EIO;
    }
    memcpy(disk + off, buf, len);
    return len;
}

static void run_tests(uint32_t ss)
{
    sector = ss;
    small_io_cache *cache = calloc(1, sizeof(*cache));
    assert(cache);
    fntfs_dev_ctx c = { .pread_cb = memory_read, .pwrite_cb = memory_write,
                        .size = DISK_SIZE, .sector = ss, .read_cache = cache };
    unsigned char data[16384], result[16384];
    memset(disk, 0x11, sizeof(disk));
    memset(data, 0x77, sizeof(data));
    reads = writes = 0;

    /* Repeated metadata reads hit the cache. */
    assert(dev_pread_aligned(&c, result, 2 * ss, 0) == 2 * ss);
    assert(dev_pread_aligned(&c, result, 2 * ss, 0) == 2 * ss);
    assert(reads == 1);
    assert(dev_pread_aligned(&c, result, ss, ss) == ss);

    /* Different overlapping read lengths must all be invalidated. */
    assert(dev_pwrite_aligned(&c, data, ss, ss) == ss);
    assert(disk[ss] == 0x77);   /* writes already reached the device */
    assert(dev_pread_aligned(&c, result, 2 * ss, 0) == 2 * ss);
    assert(result[0] == 0x11 && result[ss] == 0x77);

    /* Even failed writes invalidate stale entries. */
    memset(data, 0x55, sizeof(data));
    fail_write = true;
    assert(dev_pwrite_aligned(&c, data, 2 * ss, 0) == -EIO);
    assert(dev_pread_aligned(&c, result, 2 * ss, 0) == 2 * ss);
    assert(result[0] == 0x55 && result[ss] == 0x77);

    /* Failed/short reads must not become cache hits. */
    short_read = true;
    assert(dev_pread_aligned(&c, result, ss, 4 * ss) == 0);
    int before = reads;
    assert(dev_pread_aligned(&c, result, ss, 4 * ss) == ss);
    assert(reads == before + 1);

    /* A large bypassing write also invalidates every overlapping entry. */
    unsigned char *big = malloc((2 << 20) + 5);
    assert(big);
    memset(big, 0x99, (2 << 20) + 5);
    assert(dev_pwrite_aligned(&c, big, 1 << 20, 0) == 1 << 20);
    assert(dev_pread_aligned(&c, result, 2 * ss, 0) == 2 * ss);
    for (uint32_t i = 0; i < 2 * ss; i++) assert(result[i] == 0x99);

    /* Eviction is safe: cache entries never contain deferred writes. */
    for (int i = 0; i < SMALL_IO_SLOTS + 2; i++)
        assert(dev_pread_aligned(&c, result, ss, (int64_t)i * ss) == ss);
    assert(dev_pread_aligned(&c, result, ss, 0) == ss);
    assert(result[0] == 0x99);

    /* Odd large writes read only the two edges, preserve neighbor bytes,
       and write the complete interior without first reading it. */
    c.read_cache = NULL;
    memset(disk, 0x22, sizeof(disk));
    read_bytes = write_bytes = 0;
    assert(dev_pwrite_aligned(&c, big, (2 << 20) + 5, 1) == (2 << 20) + 5);
    assert(read_bytes == 2 * ss);
    assert(disk[0] == 0x22 && disk[(2 << 20) + 6] == 0x22);
    assert(!memcmp(disk + 1, big, (2 << 20) + 5));

    /* The two sectors of a straddling write preserve both outside bytes. */
    assert(dev_pwrite_aligned(&c, data, 2, 3 * ss - 1) == 2);
    assert(disk[3 * ss - 2] == 0x99 && disk[3 * ss + 1] == 0x99);
    assert(disk[3 * ss - 1] == 0x55 && disk[3 * ss] == 0x55);

    free(big); free(cache);
    printf("device I/O tests passed (%u-byte sectors)\n", ss);
}

int main(void)
{
    sector = 512;
    int error = 0, before = reads;
    char label[256]; uint64_t serial;
    assert(!fntfs_mount(NULL, memory_read, memory_write, NULL,
                         DISK_SIZE - 1, 512, false, NULL, NULL, &error));
    assert(error == EINVAL && reads == before);
    assert(fntfs_probe(NULL, memory_read, DISK_SIZE, 513, label, &serial)
           == FNTFS_PROBE_UNRECOGNIZED && reads == before);
    // Zero sector size has the same default as mount; it must not divide by zero.
    assert(fntfs_probe(NULL, memory_read, DISK_SIZE, 0, label, &serial)
           == FNTFS_PROBE_UNRECOGNIZED);
    assert(!valid_geometry(UINT64_MAX, 512));
    run_tests(512);
    run_tests(4096);
    return 0;
}
