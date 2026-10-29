#include "CFATXPlatform.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#ifdef __APPLE__
#include <sys/disk.h>
#else
#include <linux/fs.h>
#endif
int fx_geometry(int fd, uint64_t *length, uint32_t *block, int *device) {
    struct stat st;
    if (fstat(fd, &st)) return -1;
    *device = S_ISBLK(st.st_mode) || S_ISCHR(st.st_mode);
    *block = 512;
    if (S_ISREG(st.st_mode)) { *length = st.st_size; return 0; }
    if (!*device) { errno = EINVAL; return -1; }
#ifdef __APPLE__
    uint64_t count;
    if (ioctl(fd, DKIOCGETBLOCKSIZE, block) || ioctl(fd, DKIOCGETBLOCKCOUNT, &count)) return -1;
    if (*block == 0 || count > UINT64_MAX / *block) { errno = EOVERFLOW; return -1; }
    *length = count * *block;
#else
    if (ioctl(fd, BLKGETSIZE64, length) || ioctl(fd, BLKSSZGET, block)) return -1;
#endif
    return 0;
}
int fx_lock(int fd, int write) { return flock(fd, (write ? LOCK_EX : LOCK_SH) | LOCK_NB); }
int fx_sync(int fd) {
    if (fsync(fd)) return -1;
#ifdef __APPLE__
    struct stat st;
    if (fstat(fd, &st)) return -1;
    if (S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode)) {
        return ioctl(fd, DKIOCSYNCHRONIZECACHE, 0);
    }
    if (fcntl(fd, F_FULLFSYNC) == -1 && errno != ENOTSUP && errno != EINVAL && errno != ENOTTY) return -1;
#endif
    return 0;
}
