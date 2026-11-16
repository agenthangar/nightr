#ifndef NIGHTR_TEST_PROCESS_H
#define NIGHTR_TEST_PROCESS_H

#include <sys/types.h>

/* Parent returns the child PID, or -1 on fork failure. The child never returns:
 * it reports lock acquisition as one byte (1 or 0), waits for one release byte,
 * then exits. The caller owns timeout, termination and reaping. */
pid_t nightr_test_spawn_lock_owner(int lock_fd, int ready_write_fd, int release_read_fd);

#endif
