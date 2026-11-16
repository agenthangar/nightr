#include "NightrTestProcess.h"

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

pid_t nightr_test_spawn_lock_owner(int lock_fd, int ready_write_fd, int release_read_fd) {
    pid_t child = fork();
    if (child != 0) {
        return child;
    }

    /* XCTest may have other threads. Stay entirely in async-signal-safe POSIX
     * calls after fork, and never return into the Swift runtime in the child. */
    struct flock lock = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0 };
    int acquired;
    do {
        acquired = fcntl(lock_fd, F_SETLK, &lock);
    } while (acquired < 0 && errno == EINTR);
    unsigned char ready = acquired == 0 ? 1 : 0;
    ssize_t count;
    do {
        count = write(ready_write_fd, &ready, 1);
    } while (count < 0 && errno == EINTR);
    if (count != 1) {
        _exit(2);
    }

    unsigned char release;
    do {
        count = read(release_read_fd, &release, 1);
    } while (count < 0 && errno == EINTR);
    _exit(count == 1 && ready == 1 ? 0 : 1);
}
