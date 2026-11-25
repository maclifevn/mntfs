/* Safety policy on disposable images: unsafe mounts must not change a byte. */
#include "../Sources/FSModule/Bridge/fntfs.h"
#include "../vendor/ntfs-3g/config.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdarg.h>
#include <time.h>
#include "volume.h"
#include "inode.h"
#include "attrib.h"
#include "logfile.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (errno=%d)\n", __LINE__, #x, errno); exit(1); } } while (0)
static int fd, writes;
/* Fault injection for the discard pass. */
static int flushes, fail_flush, fail_writes_after_flushes = -1;
static int64_t rd(void *c, void *b, int64_t n, int64_t o) {
    (void)c; ssize_t r = pread(fd, b, (size_t)n, o); return r < 0 ? -errno : r;
}
static int64_t wr(void *c, const void *b, int64_t n, int64_t o) {
    (void)c;
    if (fail_writes_after_flushes >= 0 && flushes >= fail_writes_after_flushes) return -EIO;
    writes++; ssize_t r = pwrite(fd, b, (size_t)n, o); return r < 0 ? -errno : r;
}
static int flush(void *c) {
    (void)c; flushes++;
    if (fail_flush) return -EIO;
    return fsync(fd) ? -errno : 0;
}
static void restore_image(const char *image, off_t size) {
    CHECK(pwrite(fd, image, (size_t)size, 0) == size);
    CHECK(!fsync(fd));
}

int main(int argc, char **argv) {
    CHECK(argc == 3);
    const char *path = argv[1], *kind = argv[2];
    fd = open(path, O_RDWR); CHECK(fd >= 0);
    struct stat st; CHECK(!fstat(fd, &st));
    int err = 0;
    fntfs_vol *v = fntfs_mount(NULL, rd, wr, flush, st.st_size, 512, false, NULL, NULL, &err);
    CHECK(v && !fntfs_is_readonly(v));
    fntfs_attrs a;
    CHECK(!fntfs_create(v, fntfs_root_inum(), "keep.txt", false, &a));
    CHECK(fntfs_write(v, a.inum, "preserve", 8, 0) == 8);
    const bool both = !strcmp(kind, "both");   /* Windows system drive */
    if (!strcmp(kind, "hibernate") || both) {
        fntfs_attrs h;
        char header[4096] = "hibr";
        CHECK(!fntfs_create(v, fntfs_root_inum(), "hiberfil.sys", false, &h));
        CHECK(fntfs_write(v, h.inum, header, sizeof(header), 0) == sizeof(header));
    }
    CHECK(!fntfs_unmount(v));

    const bool v2 = !strcmp(kind, "v2journal") || both;
    if (!strcmp(kind, "dirty") || !strcmp(kind, "journal") || v2) {
        /* Deliberately prepare an unsafe fixture using libntfs-3g directly. */
        ntfs_volume *nv = ntfs_mount(path, both ? NTFS_MNT_IGNORE_HIBERFILE : 0); CHECK(nv);
        if (!strcmp(kind, "dirty")) {
            CHECK(!ntfs_volume_write_flags(nv, nv->flags | VOLUME_IS_DIRTY));
        } else {
            ntfs_inode *ni = ntfs_inode_open(nv, FILE_LogFile); CHECK(ni);
            ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0); CHECK(na);
            char page[4096]; memset(page, 0x42, sizeof(page));
            if (v2) {
                /* A valid 2.0 restart page can be logically clean yet still
                   represent metadata cached by Windows Fast Startup. */
                memset(page, 0, sizeof(page));
                RESTART_PAGE_HEADER *rp = (RESTART_PAGE_HEADER *)page;
                memcpy(&rp->magic, "CHKD", 4); /* Valid chkdsk page without USA. */
                rp->system_page_size = cpu_to_le32(4096);
                rp->log_page_size = cpu_to_le32(4096);
                rp->restart_area_offset = cpu_to_le16(64);
                rp->major_ver = cpu_to_le16(2);
                RESTART_AREA *ra = (RESTART_AREA *)(page + 64);
                ra->client_free_list = LOGFILE_NO_CLIENT;
                ra->client_in_use_list = LOGFILE_NO_CLIENT;
                ra->flags = RESTART_VOLUME_IS_CLEAN;
                ra->restart_area_length = cpu_to_le16(64);
                ra->client_array_offset = cpu_to_le16(64);
                ra->file_size = cpu_to_sle64(na->data_size);
                unsigned bits = 0;
                for (uint64_t n = na->data_size; n; n >>= 1) ++bits;
                ra->seq_number_bits = cpu_to_le32(67 - bits);
            }
            CHECK(ntfs_attr_pwrite(na, 0, sizeof(page), page) == sizeof(page));
            if (v2)
                CHECK(ntfs_attr_pwrite(na, 4096, sizeof(page), page) == sizeof(page));
            ntfs_attr_close(na); CHECK(!ntfs_inode_close(ni));
        }
        CHECK(!ntfs_umount(nv, false));
    }
    CHECK(!fsync(fd));
    if (v2) {
        ntfs_volume *nv = ntfs_mount(path, NTFS_MNT_RDONLY); CHECK(nv);
        ntfs_inode *ni = ntfs_inode_open(nv, FILE_LogFile); CHECK(ni);
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0); CHECK(na);
        RESTART_PAGE_HEADER *rp = NULL;
        CHECK(ntfs_check_logfile(na, &rp));
        CHECK(rp && rp->major_ver == cpu_to_le16(2));
        CHECK(ntfs_is_logfile_clean(na, rp));
        free(rp); ntfs_attr_close(na); CHECK(!ntfs_inode_close(ni)); CHECK(!ntfs_umount(nv, false));
    }
    char *before = malloc((size_t)st.st_size); CHECK(before);
    CHECK(pread(fd, before, st.st_size, 0) == st.st_size);
    uint32_t state = 0;
    CHECK(!fntfs_check_state(NULL, rd, st.st_size, 512, &state));
    /* Pin the exact classification: a damaged journal must stay UNKNOWN,
       never become a discardable Fast Startup journal. */
    uint32_t expected = !strcmp(kind, "dirty") ? FNTFS_VSTATE_DIRTY
        : !strcmp(kind, "hibernate") ? FNTFS_VSTATE_HIBERNATED
        : !strcmp(kind, "journal") ? FNTFS_VSTATE_UNKNOWN
        : !strcmp(kind, "v2journal") ? FNTFS_VSTATE_LOG_DIRTY
        : both ? (FNTFS_VSTATE_HIBERNATED | FNTFS_VSTATE_LOG_DIRTY) : 0xffffffffu;
    CHECK(state == expected);
    const bool discardable = !(state & ~FNTFS_VSTATE_DISCARDABLE);

    writes = 0;
    v = fntfs_mount(NULL, rd, wr, flush, st.st_size, 512, false, NULL, NULL, &err);
    CHECK(v && fntfs_is_readonly(v) && fntfs_mount_state(v) == state);
    CHECK(!fntfs_unmount(v));
    /* Disk Arbitration mounts read-only after startCheck fails. The status
       must still carry the inspected reason, not only "unknown". */
    v = fntfs_mount(NULL, rd, NULL, NULL, st.st_size, 512, true, NULL, NULL, &err);
    CHECK(v && fntfs_is_readonly(v));
    CHECK(fntfs_mount_state(v) == (FNTFS_VSTATE_RO_REQUESTED | state));
    CHECK(!fntfs_lookup(v, fntfs_root_inum(), "keep.txt", &a));
    char data[8]; CHECK(fntfs_read(v, a.inum, data, sizeof(data), 0) == 8);
    CHECK(!memcmp(data, "preserve", 8));
    CHECK(fntfs_write(v, a.inum, "changed!", 8, 0) == -EROFS);
    CHECK(fntfs_truncate(v, a.inum, 1) == -EROFS);
    CHECK(fntfs_setwinattrs(v, a.inum, 0) == -EROFS);
    CHECK(fntfs_remove(v, fntfs_root_inum(), "keep.txt", a.inum) == -EROFS);
    CHECK(fntfs_create(v, fntfs_root_inum(), "new.txt", false, &a) == -EROFS);
    CHECK(!fntfs_sync(v));
    CHECK(!fntfs_unmount(v));
    CHECK(writes == 0);
    char block[65536];
    for (off_t off = 0; off < st.st_size; off += sizeof(block)) {
        CHECK(pread(fd, block, sizeof(block), off) == sizeof(block));
        CHECK(!memcmp(block, before + off, sizeof(block)));
    }

    /* A discard request that misses any unsafe bit changes nothing. */
    uint32_t discarded = 0xff;
    uint32_t partial = (state & FNTFS_VSTATE_HIBERNATED) ? FNTFS_VSTATE_LOG_DIRTY
                                                         : FNTFS_VSTATE_HIBERNATED;
    writes = 0;
    v = fntfs_mount_discarding(NULL, rd, wr, flush, st.st_size, 512, partial,
                               &discarded, NULL, NULL, &err);
    CHECK(v && fntfs_is_readonly(v) && discarded == 0 && fntfs_mount_state(v) == state);
    CHECK(!fntfs_unmount(v));
    CHECK(writes == 0);

    if (discardable) {
        /* A flush failure during the pass keeps the volume read-only even
           though the changed volume may now read clean. */
        flushes = 0; fail_flush = 1;
        v = fntfs_mount_discarding(NULL, rd, wr, flush, st.st_size, 512,
                                   FNTFS_VSTATE_DISCARDABLE, &discarded, NULL, NULL, &err);
        fail_flush = 0;
        CHECK(v && fntfs_is_readonly(v) && (fntfs_mount_state(v) & FNTFS_VSTATE_UNKNOWN));
        /* The journal goes first; a failed barrier stops before hiberfil.sys. */
        CHECK(discarded == (state & FNTFS_VSTATE_LOG_DIRTY ? FNTFS_VSTATE_LOG_DIRTY
                                                           : FNTFS_VSTATE_HIBERNATED));
        CHECK(!fntfs_unmount(v));
        restore_image(before, st.st_size);
    }
    if (both) {
        /* Writes fail after the journal reset was flushed: the image must
           survive, the volume stays read-only and reports what is gone. */
        flushes = 0; fail_writes_after_flushes = 1;
        v = fntfs_mount_discarding(NULL, rd, wr, flush, st.st_size, 512,
                                   FNTFS_VSTATE_DISCARDABLE, &discarded, NULL, NULL, &err);
        fail_writes_after_flushes = -1;
        CHECK(v && fntfs_is_readonly(v) && discarded == FNTFS_VSTATE_LOG_DIRTY);
        CHECK((fntfs_mount_state(v) & (FNTFS_VSTATE_HIBERNATED | FNTFS_VSTATE_UNKNOWN)) ==
              (FNTFS_VSTATE_HIBERNATED | FNTFS_VSTATE_UNKNOWN));
        fntfs_attrs h;
        CHECK(!fntfs_lookup(v, fntfs_root_inum(), "hiberfil.sys", &h));
        CHECK(!fntfs_unmount(v));
        restore_image(before, st.st_size);
    }
    writes = 0;

    /* Automatic mount policy: only Fast Startup journal / hibernation may be
       discarded; dirty or unverifiable volumes stay read-only and untouched. */
    v = fntfs_mount_discarding(NULL, rd, wr, flush, st.st_size, 512,
                               state | FNTFS_VSTATE_DISCARDABLE, &discarded,
                               NULL, NULL, &err);
    CHECK(v);
    const char *outcome;
    if (!discardable) {
        CHECK(fntfs_is_readonly(v) && discarded == 0 && fntfs_mount_state(v) == state);
        CHECK(!fntfs_unmount(v));
        CHECK(writes == 0);
        for (off_t off = 0; off < st.st_size; off += sizeof(block)) {
            CHECK(pread(fd, block, sizeof(block), off) == sizeof(block));
            CHECK(!memcmp(block, before + off, sizeof(block)));
        }
        outcome = "discard refused, image preserved";
    } else {
        CHECK(!fntfs_is_readonly(v) && discarded == state && fntfs_mount_state(v) == 0);
        CHECK(!fntfs_lookup(v, fntfs_root_inum(), "keep.txt", &a));
        CHECK(fntfs_read(v, a.inum, data, sizeof(data), 0) == 8);
        CHECK(!memcmp(data, "preserve", 8));
        CHECK(fntfs_write(v, a.inum, "changed!", 8, 0) == 8);
        fntfs_attrs h;
        if (state & FNTFS_VSTATE_HIBERNATED)
            CHECK(fntfs_lookup(v, fntfs_root_inum(), "hiberfil.sys", &h) == -ENOENT);
        CHECK(!fntfs_unmount(v));
        CHECK(!fntfs_check_state(NULL, rd, st.st_size, 512, &state) && state == 0);
        v = fntfs_mount(NULL, rd, NULL, NULL, st.st_size, 512, true, NULL, NULL, &err);
        CHECK(v && !fntfs_lookup(v, fntfs_root_inum(), "keep.txt", &a));
        CHECK(fntfs_read(v, a.inum, data, sizeof(data), 0) == 8);
        CHECK(!memcmp(data, "changed!", 8));
        CHECK(!fntfs_unmount(v));
        outcome = "Windows state discarded, mounted read-write";
    }
    free(before); close(fd);
    printf("Mount safety passed (%s): read-only fallback, no writes, entire image preserved; %s\n",
           kind, outcome);
    return 0;
}
