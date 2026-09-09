#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define DEFAULT_SOCKET_PATH "/run/ad7768_stream.sock"

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int signo)
{
    (void)signo;
    g_stop = 1;
}

static int connect_socket(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "socket failed: %s\n", strerror(errno));
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    if (strlen(path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "Socket path too long\n");
        close(fd);
        return -1;
    }

    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "connect(%s) failed: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }

    return fd;
}

static int write_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (n == 0)
            return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *socket_path = DEFAULT_SOCKET_PATH;
    bool stop_mode = false;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            socket_path = argv[++i];
        } else if (!strcmp(argv[i], "--stop")) {
            stop_mode = true;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            fprintf(stderr,
                    "Usage: %s [--socket PATH] [--stop]\n",
                    argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 2;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    int fd = connect_socket(socket_path);
    if (fd < 0)
        return 1;

    char cmd = stop_mode ? 'Q' : 'S';
    if (write_all(fd, &cmd, 1) != 0) {
        fprintf(stderr, "Failed to send command\n");
        close(fd);
        return 1;
    }

    if (stop_mode) {
        close(fd);
        return 0;
    }

    uint8_t buf[64 * 1024];

    while (!g_stop) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "stream read failed: %s\n", strerror(errno));
            break;
        }
        if (n == 0)
            break;

        if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0)
            break;
    }

    close(fd);
    return 0;
}
