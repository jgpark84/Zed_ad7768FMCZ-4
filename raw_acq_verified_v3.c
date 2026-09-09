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
#include <unistd.h>

#define IIO_DEV_NAME        "cf_axi_adc"
#define IIO_SYSFS_BASE      "/sys/bus/iio/devices/iio:device1"
#define IIO_DEV_NODE        "/dev/iio:device1"

#define NUM_CHANNELS        4
#define RAW_SCAN_BYTES      16
#define OUT_SCAN_BYTES      16
#define DEFAULT_BUF_LENGTH  4096
#define READ_SCANS_CHUNK    4096

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
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
                     buf[n - 1] == ' '  || buf[n - 1] == '\t')) {
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
    char path[256];
    char value[128];

    snprintf(path, sizeof(path), "%s/name", IIO_SYSFS_BASE);
    if (read_text(path, value, sizeof(value)) != 0)
        return -1;

    if (strcmp(value, IIO_DEV_NAME) != 0) {
        fprintf(stderr,
                "Unexpected IIO device name: '%s' (expected '%s')\n",
                value, IIO_DEV_NAME);
        return -1;
    }

    fprintf(stderr, "IIO device: %s\n", value);
    return 0;
}

static int verify_scan_layout(void)
{
    static const char *expected_type = "le:s24/32>>0";
    char path[256];
    char value[128];

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) {
        snprintf(path, sizeof(path),
                 "%s/scan_elements/in_voltage%d_index",
                 IIO_SYSFS_BASE, ch);
        if (read_text(path, value, sizeof(value)) != 0)
            return -1;

        long idx = strtol(value, NULL, 10);
        if (idx != ch) {
            fprintf(stderr,
                    "Channel %d index mismatch: got %ld, expected %d\n",
                    ch, idx, ch);
            return -1;
        }

        snprintf(path, sizeof(path),
                 "%s/scan_elements/in_voltage%d_type",
                 IIO_SYSFS_BASE, ch);
        if (read_text(path, value, sizeof(value)) != 0)
            return -1;

        if (strcmp(value, expected_type) != 0) {
            fprintf(stderr,
                    "Channel %d type mismatch: got '%s', expected '%s'\n",
                    ch, value, expected_type);
            return -1;
        }
    }

    fprintf(stderr,
            "Scan layout verified: 4 ch x le:s24/32>>0 = 16 bytes/scan\n");
    return 0;
}

static int print_watermark_status(void)
{
    char path[256];
    char value[128];

    snprintf(path, sizeof(path), "%s/buffer/watermark", IIO_SYSFS_BASE);
    if (read_text(path, value, sizeof(value)) != 0) {
        fprintf(stderr,
                "Warning: could not read watermark; continuing without it\n");
        return 0;
    }

    fprintf(stderr, "IIO watermark (read-only): %s scans\n", value);
    return 0;
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

    /*
     * IMPORTANT:
     * buffer/watermark is read-only on this system.
     * Do not attempt to write it.
     */
    print_watermark_status();

    snprintf(path, sizeof(path), "%s/buffer/enable", IIO_SYSFS_BASE);
    if (write_text(path, "1") != 0)
        return -1;

    return 0;
}

static void disable_iio(void)
{
    char path[256];

    snprintf(path, sizeof(path), "%s/buffer/enable", IIO_SYSFS_BASE);
    if (write_text(path, "0") != 0) {
        fprintf(stderr, "Warning: failed to disable IIO buffer\n");
    }
}

static inline int32_t decode_s24_le32(const uint8_t *p)
{
    /*
     * IIO type: le:s24/32>>0
     * Meaning:
     *   - 32-bit little-endian storage slot
     *   - valid signed ADC sample is lower 24 bits
     *   - sign-extend bit 23 to int32_t
     */
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

static int write_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;

    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "output write failed: %s\n", strerror(errno));
            return -1;
        }

        if (n == 0) {
            fprintf(stderr, "output write returned 0\n");
            return -1;
        }

        p += (size_t)n;
        len -= (size_t)n;
    }

    return 0;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [-a REC_avg] [-n output_scans] [-o output_file] "
        "[-l buffer_length]\n"
        "\n"
        "Options:\n"
        "  -a N    Recording averaging factor (default: 1)\n"
        "  -n N    Number of averaged output scans; 0 = continuous (default: 0)\n"
        "  -o PATH Binary output file; default = stdout\n"
        "  -l N    IIO buffer length in scans (default: 4096)\n"
        "  -h      Show this help\n"
        "\n"
        "Output format per averaged scan:\n"
        "  int32 ch0, int32 ch1, int32 ch2, int32 ch3\n"
        "  total = 16 bytes / averaged scan\n"
        "\n"
        "Note: buffer/watermark is read-only and is only displayed at startup.\n",
        prog);
}

int main(int argc, char **argv)
{
    uint64_t rec_avg = 1;
    uint64_t output_limit = 0;
    uint32_t buffer_length = DEFAULT_BUF_LENGTH;
    const char *output_path = NULL;

    int opt;
    while ((opt = getopt(argc, argv, "a:n:o:l:h")) != -1) {
        switch (opt) {
        case 'a':
            rec_avg = strtoull(optarg, NULL, 10);
            if (rec_avg == 0) {
                fprintf(stderr, "REC_avg must be >= 1\n");
                return EXIT_FAILURE;
            }
            break;

        case 'n':
            output_limit = strtoull(optarg, NULL, 10);
            break;

        case 'o':
            output_path = optarg;
            break;

        case 'l': {
            unsigned long v = strtoul(optarg, NULL, 10);
            if (v == 0 || v > UINT32_MAX) {
                fprintf(stderr, "Invalid buffer length\n");
                return EXIT_FAILURE;
            }
            buffer_length = (uint32_t)v;
            break;
        }

        case 'h':
            usage(argv[0]);
            return EXIT_SUCCESS;

        default:
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (verify_identity() != 0)
        return EXIT_FAILURE;

    if (verify_scan_layout() != 0)
        return EXIT_FAILURE;

    if (configure_iio(buffer_length) != 0) {
        fprintf(stderr, "IIO configuration failed\n");
        disable_iio();
        return EXIT_FAILURE;
    }

    int dev_fd = open(IIO_DEV_NODE, O_RDONLY);
    if (dev_fd < 0) {
        fprintf(stderr, "open(%s) failed: %s\n",
                IIO_DEV_NODE, strerror(errno));
        disable_iio();
        return EXIT_FAILURE;
    }

    int out_fd = STDOUT_FILENO;
    if (output_path != NULL) {
        out_fd = open(output_path,
                      O_WRONLY | O_CREAT | O_TRUNC,
                      0666);
        if (out_fd < 0) {
            fprintf(stderr, "open(%s) for output failed: %s\n",
                    output_path, strerror(errno));
            close(dev_fd);
            disable_iio();
            return EXIT_FAILURE;
        }
    }

    fprintf(stderr,
            "Acquisition started: REC_avg=%" PRIu64
            ", output_limit=%" PRIu64
            ", buffer_length=%" PRIu32 "\n",
            rec_avg, output_limit, buffer_length);

    if (output_path != NULL)
        fprintf(stderr, "Binary output: %s\n", output_path);
    else
        fprintf(stderr, "Binary output: stdout\n");

    size_t read_buf_bytes = READ_SCANS_CHUNK * RAW_SCAN_BYTES;
    uint8_t *read_buf = malloc(read_buf_bytes);
    if (!read_buf) {
        fprintf(stderr, "malloc failed\n");
        if (out_fd != STDOUT_FILENO)
            close(out_fd);
        close(dev_fd);
        disable_iio();
        return EXIT_FAILURE;
    }

    uint8_t carry[RAW_SCAN_BYTES];
    size_t carry_len = 0;

    int64_t acc[NUM_CHANNELS] = {0, 0, 0, 0};
    uint64_t acc_count = 0;
    uint64_t output_count = 0;

    int exit_code = EXIT_SUCCESS;

    while (!g_stop &&
           (output_limit == 0 || output_count < output_limit)) {

        ssize_t n = read(dev_fd, read_buf, read_buf_bytes);
        if (n < 0) {
            if (errno == EINTR)
                continue;

            fprintf(stderr, "read(%s) failed: %s\n",
                    IIO_DEV_NODE, strerror(errno));
            exit_code = EXIT_FAILURE;
            break;
        }

        if (n == 0) {
            fprintf(stderr, "read(%s) returned EOF\n", IIO_DEV_NODE);
            exit_code = EXIT_FAILURE;
            break;
        }

        size_t pos = 0;

        if (carry_len > 0) {
            size_t need = RAW_SCAN_BYTES - carry_len;
            size_t avail = (size_t)n;

            if (avail < need) {
                memcpy(carry + carry_len, read_buf, avail);
                carry_len += avail;
                continue;
            }

            memcpy(carry + carry_len, read_buf, need);

            int32_t s[NUM_CHANNELS];
            for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                s[ch] = decode_s24_le32(carry + 4 * ch);

            for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                acc[ch] += s[ch];

            acc_count++;
            if (acc_count == rec_avg) {
                int32_t out[NUM_CHANNELS];
                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    out[ch] = (int32_t)(acc[ch] / (int64_t)rec_avg);

                if (write_all(out_fd, out, OUT_SCAN_BYTES) != 0) {
                    exit_code = EXIT_FAILURE;
                    goto done;
                }

                output_count++;
                memset(acc, 0, sizeof(acc));
                acc_count = 0;

                if (output_limit != 0 &&
                    output_count >= output_limit)
                    goto done;
            }

            carry_len = 0;
            pos = need;
        }

        while (pos + RAW_SCAN_BYTES <= (size_t)n) {
            const uint8_t *scan = read_buf + pos;

            int32_t s[NUM_CHANNELS];
            for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                s[ch] = decode_s24_le32(scan + 4 * ch);

            for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                acc[ch] += s[ch];

            acc_count++;

            if (acc_count == rec_avg) {
                int32_t out[NUM_CHANNELS];

                for (int ch = 0; ch < NUM_CHANNELS; ++ch)
                    out[ch] = (int32_t)(acc[ch] / (int64_t)rec_avg);

                if (write_all(out_fd, out, OUT_SCAN_BYTES) != 0) {
                    exit_code = EXIT_FAILURE;
                    goto done;
                }

                output_count++;
                memset(acc, 0, sizeof(acc));
                acc_count = 0;

                if (output_limit != 0 &&
                    output_count >= output_limit)
                    goto done;
            }

            pos += RAW_SCAN_BYTES;
        }

        if (pos < (size_t)n) {
            carry_len = (size_t)n - pos;
            memcpy(carry, read_buf + pos, carry_len);
        }
    }

done:
    fprintf(stderr,
            "Acquisition stopped: averaged scans written=%" PRIu64 "\n",
            output_count);

    free(read_buf);

    if (out_fd != STDOUT_FILENO) {
        if (fsync(out_fd) != 0)
            fprintf(stderr, "Warning: fsync failed: %s\n", strerror(errno));
        close(out_fd);
    }

    close(dev_fd);
    disable_iio();

    return exit_code;
}
