#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IIO_BASE "/sys/bus/iio/devices/iio:device1"
#define IIO_DEV  "/dev/iio:device1"
#define NCH 4
#define SCAN_BYTES 16

static volatile sig_atomic_t stop_flag = 0;
static void on_signal(int sig) { (void)sig; stop_flag = 1; }

static int write_text(const char *path, const char *text) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    size_t len = strlen(text);
    ssize_t n = write(fd, text, len);
    close(fd);
    return (n == (ssize_t)len) ? 0 : -1;
}

static int read_text(const char *path, char *buf, size_t nbuf) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, nbuf - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = 0;
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r' || buf[n-1] == ' ')) buf[--n] = 0;
    return 0;
}

static int verify_layout(void) {
    char path[256], buf[128];

    snprintf(path, sizeof(path), IIO_BASE "/name");
    if (read_text(path, buf, sizeof(buf)) || strcmp(buf, "cf_axi_adc")) {
        fprintf(stderr, "Unexpected IIO device name\n");
        return -1;
    }

    for (int ch = 0; ch < NCH; ch++) {
        snprintf(path, sizeof(path), IIO_BASE "/scan_elements/in_voltage%d_index", ch);
        if (read_text(path, buf, sizeof(buf)) || atoi(buf) != ch) {
            fprintf(stderr, "Unexpected channel %d index\n", ch);
            return -1;
        }

        snprintf(path, sizeof(path), IIO_BASE "/scan_elements/in_voltage%d_type", ch);
        if (read_text(path, buf, sizeof(buf)) || strcmp(buf, "le:s24/32>>0")) {
            fprintf(stderr, "Unexpected channel %d type: %s\n", ch, buf);
            return -1;
        }
    }
    return 0;
}

static int configure_iio(unsigned length, unsigned watermark) {
    char path[256], val[64];

    snprintf(path, sizeof(path), IIO_BASE "/buffer/enable");
    if (write_text(path, "0")) return -1;

    for (int ch = 0; ch < NCH; ch++) {
        snprintf(path, sizeof(path), IIO_BASE "/scan_elements/in_voltage%d_en", ch);
        if (write_text(path, "1")) return -1;
    }

    snprintf(path, sizeof(path), IIO_BASE "/buffer/length");
    snprintf(val, sizeof(val), "%u", length);
    if (write_text(path, val)) return -1;

    snprintf(path, sizeof(path), IIO_BASE "/buffer/watermark");
    snprintf(val, sizeof(val), "%u", watermark);
    if (write_text(path, val)) return -1;

    snprintf(path, sizeof(path), IIO_BASE "/buffer/enable");
    if (write_text(path, "1")) return -1;

    return 0;
}

static void disable_iio(void) {
    char path[256];
    snprintf(path, sizeof(path), IIO_BASE "/buffer/enable");
    write_text(path, "0");
}

static inline int32_t s24(uint32_t w) {
    uint32_t v = w & 0x00ffffffu;
    if (v & 0x00800000u) v |= 0xff000000u;
    return (int32_t)v;
}

static int write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static void usage(const char *p) {
    fprintf(stderr,
        "Usage: %s [-a avg] [-n outputs] [-o file|-] [-l length] [-w watermark]\n"
        "Defaults: avg=1024, outputs=0(unlimited), output=-, length=4096, watermark=2048\n",
        p);
}

int main(int argc, char **argv) {
    uint64_t avg_n = 1024, out_limit = 0, out_count = 0, raw_count = 0, acc_count = 0;
    unsigned length = 4096, watermark = 2048;
    const char *out_path = "-";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-a") && i+1 < argc) avg_n = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-n") && i+1 < argc) out_limit = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-o") && i+1 < argc) out_path = argv[++i];
        else if (!strcmp(argv[i], "-l") && i+1 < argc) length = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-w") && i+1 < argc) watermark = strtoul(argv[++i], 0, 0);
        else { usage(argv[0]); return 2; }
    }

    if (avg_n < 1 || watermark < 1 || watermark > length) return 2;

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (verify_layout()) return 1;
    if (configure_iio(length, watermark)) {
        fprintf(stderr, "IIO configuration failed: %s\n", strerror(errno));
        disable_iio();
        return 1;
    }

    int in_fd = open(IIO_DEV, O_RDONLY);
    if (in_fd < 0) {
        perror("open IIO");
        disable_iio();
        return 1;
    }

    int out_fd = STDOUT_FILENO;
    if (strcmp(out_path, "-")) {
        out_fd = open(out_path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        if (out_fd < 0) {
            perror("open output");
            close(in_fd);
            disable_iio();
            return 1;
        }
    }

    const size_t READ_BYTES = 131072; /* 8192 complete 16-byte scans */
    uint8_t *buf = malloc(READ_BYTES);
    if (!buf) return 1;

    int64_t acc[NCH] = {0,0,0,0};

    fprintf(stderr,
        "source=%s, format=4x le:s24/32>>0, avg=%" PRIu64
        ", length=%u, watermark=%u\n",
        IIO_DEV, avg_n, length, watermark);

    while (!stop_flag && (out_limit == 0 || out_count < out_limit)) {
        ssize_t n = read(in_fd, buf, READ_BYTES);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("read");
            break;
        }
        if (n == 0) break;

        if ((n % SCAN_BYTES) != 0) {
            fprintf(stderr, "Unexpected short alignment: %zd bytes\n", n);
            break;
        }

        for (ssize_t pos = 0; pos < n; pos += SCAN_BYTES) {
            uint32_t w[NCH];
            memcpy(w, buf + pos, SCAN_BYTES);

            for (int ch = 0; ch < NCH; ch++) acc[ch] += s24(w[ch]);
            acc_count++;
            raw_count++;

            if (acc_count == avg_n) {
                int32_t out[NCH];
                for (int ch = 0; ch < NCH; ch++)
                    out[ch] = (int32_t)(acc[ch] / (int64_t)avg_n);

                if (write_all(out_fd, out, sizeof(out))) {
                    perror("write");
                    stop_flag = 1;
                    break;
                }

                memset(acc, 0, sizeof(acc));
                acc_count = 0;
                out_count++;

                if (out_limit && out_count >= out_limit) break;
            }
        }
    }

    fprintf(stderr,
        "done: raw_scans=%" PRIu64 ", averaged_scans=%" PRIu64
        ", partial=%" PRIu64 "/%" PRIu64 "\n",
        raw_count, out_count, acc_count, avg_n);

    if (out_fd != STDOUT_FILENO) {
        fsync(out_fd);
        close(out_fd);
    }
    free(buf);
    close(in_fd);
    disable_iio();
    return 0;
}
