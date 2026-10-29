#ifndef CFATXPLATFORM_H
#define CFATXPLATFORM_H
#include <stdint.h>
int fx_geometry(int fd, uint64_t *length, uint32_t *block, int *device);
int fx_lock(int fd, int write);
int fx_sync(int fd);
uint64_t fx_process_stamp(int pid);
#endif
