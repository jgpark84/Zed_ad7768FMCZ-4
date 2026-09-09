#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define IIO_DEV_NAME        "cf_axi_adc"
#define IIO_SYSFS_BASE      "/sys/bus/iio/devices/iio:device1"
#define IIO_DEV_NODE        "/dev/iio:device1"
#define NUM_CHANNELS        4
#define RAW_SCAN_BYTES      16
#define OUT_SCAN_BYTES      16
#define DEFAULT_BUF_LENGTH  4096
#define READ_SCANS_CHUNK    4096
#define DEFAULT_SOCKET_PATH "/run/ad7768_stream.sock"
#define DEFAULT_SPILL_DIR   "/root"

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int signo)
{
    (void)signo;
    g_stop = 1;
}

static int read_text(const char *path, char *buf, size_t buf_sz)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "open(%s) failed: %s\n", path, strerror(errno));
        return -1;
    }
    ssize_t n = read(fd, buf, buf_sz - 1);
    if (n < 0) {
        fprintf(stderr, "read(%s) failed: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    buf[n] = '\0';
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' ||
                     buf[n-1] == ' ' || buf[n-1] == '\t')) {
        buf[--n] = '\0';
    }
    close(fd);
    return 0;
}

static int write_text(const char *path, const char *value)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "open(%s) for write failed: %s\n",
                path, strerror(errno));
        return -1;
    }
    size_t len = strlen(value);
    ssize_t n = write(fd, value, len);
    if (n < 0 || (size_t)n != len) {
        fprintf(stderr, "write(%s) failed: %s\n",
                path, (n < 0) ? strerror(errno) : "short write");
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int sysfs_write_u32(const char *path, uint32_t value)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%" PRIu32, value);
    return write_text(path, buf);
}

static int verify_identity(void)
{
    char path[256], value[128];
    snprintf(path, sizeof(path), "%s/name", IIO_SYSFS_BASE);
    if (read_text(path, value, sizeof(value)) != 0)
        return -1;
    if (strcmp(value, IIO_DEV_NAME) != 0) {
        fprintf(stderr, "Unexpected IIO device name: '%s'\n", value);
        return -1;
    }
    fprintf(stderr, "IIO device: %s\n", value);
    return 0;
}

static int verify_scan_layout(void)
{
    static const char *expected_type = "le:s24/32>>0";
    char path[256], value[128];

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) {
        snprintf(path, sizeof(path),
                 "%s/scan_elements/in_voltage%d_index",
                 IIO_SYSFS_BASE, ch);
        if (read_text(path, value, sizeof(value)) != 0)
            return -1;
        if (strtol(value, NULL, 10) != ch) {
            fprintf(stderr, "Channel %d index mismatch\n", ch);
            return -1;
        }

        snprintf(path, sizeof(path),
                 "%s/scan_elements/in_voltage%d_type",
                 IIO_SYSFS_BASE, ch);
        if (read_text(path, value, sizeof(value)) != 0)
            return -1;
        if (strcmp(value, expected_type) != 0) {
            fprintf(stderr, "Channel %d type mismatch: %s\n", ch, value);
            return -1;
        }
    }

    fprintf(stderr, "Scan layout verified: 4 ch x le:s24/32>>0\n");
    return 0;
}

static void print_watermark(void)
{
    char path[256], value[128];
    snprintf(path, sizeof(path), "%s/buffer/watermark", IIO_SYSFS_BASE);
    if (read_text(path, value, sizeof(value)) == 0)
        fprintf(stderr, "IIO watermark (read-only): %s scans\n", value);
}

static int configure_iio(uint32_t buffer_length)
{
    char path[256];

    snprintf(path, sizeof(path), "%s/buffer/enable", IIO_SYSFS_BASE);
    if (write_text(path, "0") != 0)
        return -1;

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) {
        snprintf(path, sizeof(path),
                 "%s/scan_elements/in_voltage%d_en",
                 IIO_SYSFS_BASE, ch);
        if (write_text(path, "1") != 0)
            return -1;
    }

    snprintf(path, sizeof(path), "%s/buffer/length", IIO_SYSFS_BASE);
    if (sysfs_write_u32(path, buffer_length) != 0)
        return -1;

    print_watermark();

    snprintf(path, sizeof(path), "%s/buffer/enable", IIO_SYSFS_BASE);
    return write_text(path, "1");
}

static void disable_iio(void)
{
    char path[256];
    snprintf(path, sizeof(path), "%s/buffer/enable", IIO_SYSFS_BASE);
    (void)write_text(path, "0");
}

static inline int32_t decode_s24_le32(const uint8_t *p)
{
    uint32_t w =
        ((uint32_t)p[0]) |
        ((uint32_t)p[1] << 8) |
        ((uint32_t)p[2] << 16) |
        ((uint32_t)p[3] << 24);

    uint32_t v = w & 0x00FFFFFFu;
    if (v & 0x00800000u)
        v |= 0xFF000000u;
    return (int32_t)v;
}

static int make_listener(const char *socket_path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "socket failed: %s\n", strerror(errno));
        return -1;
    }

    unlink(socket_path);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;

    if (strlen(socket_path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "Socket path too long\n");
        close(fd);
        return -1;
    }

    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "bind(%s) failed: %s\n", socket_path, strerror(errno));
        close(fd);
        return -1;
    }

    if (listen(fd, 4) != 0) {
        fprintf(stderr, "listen failed: %s\n", strerror(errno));
        close(fd);
        unlink(socket_path);
        return -1;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    chmod(socket_path, 0660);
    return fd;
}

static int make_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int open_spill(const char *dir, unsigned long index,
                      char *path_out, size_t path_sz)
{
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);

    snprintf(path_out, path_sz,
             "%s/spill_%04d%02d%02d_%02d%02d%02d_%06lu.bin",
             dir,
             tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, index);

    int fd = open(path_out, O_WRONLY | O_CREAT | O_EXCL, 0666);
    if (fd < 0) {
        fprintf(stderr, "open spill %s failed: %s\n",
                path_out, strerror(errno));
        return -1;
    }

    fprintf(stderr, "Spill started: %s\n", path_out);
    return fd;
}

static void close_spill(int *fd, const char *path, uint64_t frames)
{
    if (*fd < 0)
        return;

    fsync(*fd);
    close(*fd);
    fprintf(stderr, "Spill closed: %s (%" PRIu64 " frames, %" PRIu64 " bytes)\n",
            path, frames, frames * (uint64_t)OUT_SCAN_BYTES);
    *fd = -1;
}

static int handle_new_clients(int listener_fd, int *client_fd,
                              bool *recording_active,
                              int *spill_fd, char *spill_path,
                              uint64_t *spill_frames)
{
    for (;;) {
        int fd = accept(listener_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return 0;
            if (errno == EINTR)
                continue;
            fprintf(stderr, "accept failed: %s\n", strerror(errno));
            return -1;
        }

        char cmd = 0;
        ssize_t n = recv(fd, &cmd, 1, 0);
        if (n != 1) {
            close(fd);
            continue;
        }

        if (cmd == 'S') {
            if (*client_fd >= 0)
                close(*client_fd);

            *client_fd = fd;
            make_nonblocking(*client_fd);
            *recording_active = true;

            close_spill(spill_fd, spill_path, *spill_frames);
            *spill_frames = 0;

            fprintf(stderr, "Live client connected; recording active\n");
        } else if (cmd == 'Q') {
            if (*client_fd >= 0) {
                close(*client_fd);
                *client_fd = -1;
            }

            *recording_active = false;
            close_spill(spill_fd, spill_path, *spill_frames);
            *spill_frames = 0;

            fprintf(stderr, "Recording stopped by client\n");
            close(fd);
        } else {
            close(fd);
        }
    }
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [-a REC_avg] [-l buffer_length] "
        "[--socket PATH] [--spill-dir DIR]\n"
        "\n"
        "Defaults:\n"
        "  REC_avg       = 1024\n"
        "  buffer_length = 4096\n"
        "  socket        = /run/ad7768_stream.sock\n"
        "  spill-dir     = /root\n",
        prog);
}

int main(int argc, char **argv)
{
    uint64_t rec_avg = 1024;
    uint32_t buffer_length = DEFAULT_BUF_LENGTH;
    const char *socket_path = DEFAULT_SOCKET_PATH;
    const char *spill_dir = DEFAULT_SPILL_DIR;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-a") && i + 1 < argc) {
            rec_avg = strtoull(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "-l") && i + 1 < argc) {
            buffer_length = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            socket_path = argv[++i];
        } else if (!strcmp(argv[i], "--spill-dir") && i + 1 < argc) {
            spill_dir = argv[++i];
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (rec_avg == 0 || buffer_length == 0) {
        fprintf(stderr, "Invalid averaging or buffer length\n");
        return 2;
    }

    struct stat st;
    if (stat(spill_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "Spill directory does not exist: %s\n", spill_dir);
        return 2;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    if (verify_identity() != 0 || verify_scan_layout() != 0)
        return 1;

    if (configure_iio(buffer_length) != 0) {
        disable_iio();
        return 1;
    }

    int dev_fd = open(IIO_DEV_NODE, O_RDONLY);
    if (dev_fd < 0) {
        fprintf(stderr, "open(%s) failed: %s\n", IIO_DEV_NODE, strerror(errno));
        disable_iio();
        return 1;
    }

    int listener_fd = make_listener(socket_path);
    if (listener_fd < 0) {
        close(dev_fd);
        disable_iio();
        return 1;
    }

    fprintf(stderr,
            "AD7768 record daemon started: REC_avg=%" PRIu64
            ", socket=%s, spill-dir=%s\n",
            rec_avg, socket_path, spill_dir);
    fprintf(stderr, "Idle until first stream client connects\n");

    size_t read_buf_bytes = READ_SCANS_CHUNK * RAW_SCAN_BYTES;
    uint8_t *read_buf = malloc(read_buf_bytes);
    if (!read_buf) {
        fprintf(stderr, "malloc failed\n");
        close(listener_fd);
        close(dev_fd);
        unlink(socket_path);
        disable_iio();
        return 1;
    }

    int client_fd = -1;
    bool recording_active = false;

    int spill_fd = -1;
    char spill_path[512] = {0};
    uint64_t spill_frames = 0;
    unsigned long spill_index = 0;

    uint8_t carry[RAW_SCAN_BYTES];
    size_t carry_len = 0;
    int64_t acc[NUM_CHANNELS] = {0};
    uint64_t acc_count = 0;

    while (!g_stop) {
        if (handle_new_clients(listener_fd, &client_fd,
                               &recording_active,
                               &spill_fd, spill_path,
                               &spill_frames) != 0) {
            break;
        }

        ssize_t n = read(dev_fd, read_buf, read_buf_bytes);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "IIO read failed: %s\n", strerror(errno));
            break;
        }
        if (n == 0) {
            fprintf(stderr, "IIO read returned EOF\n");
            break;
        }

        size_t pos = 0;

        while (pos < (size_t)n) {
            const uint8_t *scan = NULL;

            if (carry_len > 0) {
                size_t need = RAW_SCAN_BYTES - carry_len;
                size_t avail = (size_t)n - pos;

                if (avail < need) {
                    memcpy(carry + carry_len, read_buf + pos, avail);
                    carry_len += avail;
                    pos += avail;
                    break;
                }

                memcpy(carry + carry_len, read_buf + pos, need);
                carry_len = 0;
                pos += need;
                scan = carry;
            } else if (pos + RAW_SCAN_BYTES <= (size_t)n) {
                scan = read_buf + pos;
                pos += RAW_SCAN_BYTES;
            } else {
                carry_len = (size_t)n - pos;
                memcpy(carry, read_buf + pos, carry_len);
                pos = (size_t)n;
                break;
            }

            for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                acc[ch] += decode_s24_le32(scan + 4 * ch);

            acc_count++;

            if (acc_count == rec_avg) {
                int32_t out[NUM_CHANNELS];
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    out[ch] = (int32_t)(acc[ch] / (int64_t)rec_avg);

                memset(acc, 0, sizeof(acc));
                acc_count = 0;

                if (handle_new_clients(listener_fd, &client_fd,
                                       &recording_active,
                                       &spill_fd, spill_path,
                                       &spill_frames) != 0) {
                    g_stop = 1;
                    break;
                }

                if (!recording_active)
                    continue;

                if (client_fd >= 0) {
                    ssize_t sent = send(client_fd, out, OUT_SCAN_BYTES,
                                        MSG_NOSIGNAL);
                    if (sent == OUT_SCAN_BYTES) {
                        continue;
                    }

                    fprintf(stderr,
                            "Live client disconnected/backpressured; "
                            "switching to spill\n");
                    close(client_fd);
                    client_fd = -1;
                }

                if (spill_fd < 0) {
                    spill_fd = open_spill(spill_dir, spill_index++,
                                          spill_path, sizeof(spill_path));
                    if (spill_fd < 0) {
                        fprintf(stderr,
                                "FATAL: cannot open spill file; data will be lost\n");
                        recording_active = false;
                        continue;
                    }
                    spill_frames = 0;
                }

                ssize_t wn = write(spill_fd, out, OUT_SCAN_BYTES);
                if (wn != OUT_SCAN_BYTES) {
                    fprintf(stderr, "spill write failed: %s\n",
                            (wn < 0) ? strerror(errno) : "short write");
                    close_spill(&spill_fd, spill_path, spill_frames);
                    recording_active = false;
                    spill_frames = 0;
                } else {
                    spill_frames++;
                }
            }
        }
    }

    if (client_fd >= 0)
        close(client_fd);
    close_spill(&spill_fd, spill_path, spill_frames);

    free(read_buf);
    close(listener_fd);
    unlink(socket_path);
    close(dev_fd);
    disable_iio();

    fprintf(stderr, "AD7768 record daemon stopped\n");
    return 0;
}
