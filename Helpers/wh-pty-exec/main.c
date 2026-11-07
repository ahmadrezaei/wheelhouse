// wh-pty-exec: makes the pseudo-terminal on fd 0 the controlling terminal of this new session, then runs the program.
//
//   wh-pty-exec <absolute program> [arguments...]
//
// The app spawns this helper with POSIX_SPAWN_SETSID and fd 0 opened on the PTY slave. XNU does not acquire a controlling terminal
// when a session leader opens a tty, so the explicit TIOCSCTTY below is what gives the child a controlling TTY (job control,
// SIGWINCH and SIGHUP delivery). No fork() happens in the app process.
#include <errno.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fputs("usage: wh-pty-exec <program> [args...]\n", stderr); return 64; }
    ioctl(0, TIOCSCTTY, 0);
    execv(argv[1], argv + 1);
    int code = errno == EACCES ? 126 : 127;
    perror(argv[1]);
    return code;
}
