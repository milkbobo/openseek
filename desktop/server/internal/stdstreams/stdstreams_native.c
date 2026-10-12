/*
 * Taking the protocol channel off descriptors 0 and 1, for a server whose
 * one client talks to it over its standard streams.
 */

#include "moonbit.h"

/* Nothing here exists on Windows: the package has no caller there. */
#if !defined(_WIN32)

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>

/*
 * Duplicate standard input and output to fresh close-on-exec descriptors,
 * written to `descriptors[0]` and `descriptors[1]`, then point descriptor 0
 * at the null device and descriptor 1 at standard error. Returns 0, or the
 * `errno` of the call that failed.
 */
MOONBIT_FFI_EXPORT int32_t
moonbit_openseek_desktop_server_claim_standard_streams(int32_t *descriptors) {
  int input = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3);
  if (input < 0) {
    return errno;
  }
  int output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3);
  if (output < 0) {
    int error = errno;
    close(input);
    return error;
  }
  int null = open("/dev/null", O_RDONLY);
  if (null < 0 || dup2(null, STDIN_FILENO) < 0 ||
      dup2(STDERR_FILENO, STDOUT_FILENO) < 0) {
    int error = errno;
    if (null >= 0) {
      close(null);
    }
    close(input);
    close(output);
    return error;
  }
  close(null);
  descriptors[0] = input;
  descriptors[1] = output;
  return 0;
}

#endif
