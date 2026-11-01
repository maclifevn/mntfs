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
static int64_t rd(void *c, void *b, int64_t n, int64_t o) {
    (void)c; ssize_t r = pread(fd, b, (size_t)n, o); return r < 0 ? -errno : r;
}
static int64_t wr(void *c, const void *b, int64_t n, int64_t o) {
    (void)c; writes++; ssize_t r = pwrite(fd, b, (size_t)n, o); return r < 0 ? -errno : r;
}
static int flush(void *c) { (void)c; return fsync(fd) ? -errno : 0; }

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
    if (!strcmp(kind, "hibernate")) {
        fntfs_attrs h;
        char header[4096] = "hibr";
        CHECK(!fntfs_create(v, fntfs_root_inum(), "hiberfil.sys", false, &h));
        CHECK(fntfs_write(v, h.inum, header, sizeof(header), 0) == sizeof(header));
    }
    CHECK(!fntfs_unmount(v));

    if (!strcmp(kind, "dirty") || !strcmp(kind, "journal") || !strcmp(kind, "v2journal")) {
        /* Deliberately prepare an unsafe fixture using libntfs-3g directly. */
        ntfs_volume *nv = ntfs_mount(path, 0); CHECK(nv);
        if (!strcmp(kind, "dirty")) {
            CHECK(!ntfs_volume_write_flags(nv, nv->flags | VOLUME_IS_DIRTY));
        } else {
            ntfs_inode *ni = ntfs_inode_open(nv, FILE_LogFile); CHECK(ni);
            ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0); CHECK(na);
            char page[4096]; memset(page, 0x42, sizeof(page));
            if (!strcmp(kind, "v2journal")) {
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
            if (!strcmp(kind, "v2journal"))
                CHECK(ntfs_attr_pwrite(na, 4096, sizeof(page), page) == sizeof(page));
            ntfs_attr_close(na); CHECK(!ntfs_inode_close(ni));
        }
        CHECK(!ntfs_umount(nv, false));
    }
    CHECK(!fsync(fd));
    if (!strcmp(kind, "v2journal")) {
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
    CHECK(state != 0);
    if (!strcmp(kind, "dirty")) CHECK(state & FNTFS_VSTATE_DIRTY);
    if (!strcmp(kind, "hibernate")) CHECK(state & FNTFS_VSTATE_HIBERNATED);
    if (!strcmp(kind, "journal")) CHECK(state & (FNTFS_VSTATE_LOG_DIRTY | FNTFS_VSTATE_UNKNOWN));
    if (!strcmp(kind, "v2journal")) CHECK(state & FNTFS_VSTATE_LOG_DIRTY);

    writes = 0;
    v = fntfs_mount(NULL, rd, wr, flush, st.st_size, 512, false, NULL, NULL, &err);
    CHECK(v && fntfs_is_readonly(v) && fntfs_mount_state(v) == state);
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
    free(before); close(fd);
    printf("Mount safety passed (%s): read-only fallback, no writes, entire image preserved\n", kind);
    return 0;
}
