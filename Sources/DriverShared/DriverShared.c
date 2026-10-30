#include "DriverShared.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

DriverSharedHeader *driver_shared_open(const char *name, int *error) {
    int fd = shm_open(name, O_RDWR);
    if (fd < 0) {
        *error = errno;
        return NULL;
    }
    void *memory = mmap(NULL, driver_shared_size(), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int mapError = errno;
    close(fd);
    if (memory == MAP_FAILED) {
        *error = mapError;
        return NULL;
    }
    return memory;
}
