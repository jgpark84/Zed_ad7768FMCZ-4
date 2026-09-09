#!/usr/bin/env python3
import glob
import os
import queue
import signal
import sys
import threading

FRAME_BYTES = 32

# Low-latency control/monitor stream settings.
# The previous version used 4096 frames for both the IIO buffer length and each
# read request (128 KiB). That strongly encouraged bursty delivery.
BUFFER_LENGTH = 32
READ_FRAMES = 32
READ_BYTES = FRAME_BYTES * READ_FRAMES
QUEUE_CHUNKS = 64

running = True
chunk_queue = queue.Queue(maxsize=QUEUE_CHUNKS)


def find_control_iio():
    for dev in sorted(glob.glob('/sys/bus/iio/devices/iio:device*')):
        try:
            with open(os.path.join(dev, 'name'), 'r') as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == 'control_stream':
            return dev, '/dev/' + os.path.basename(dev)
    raise RuntimeError('control_stream IIO device not found')


def write_text(path, value):
    with open(path, 'w') as f:
        f.write(str(value))


def read_text(path):
    with open(path, 'r') as f:
        return f.read().strip()


def configure_iio(sysfs):
    enable = os.path.join(sysfs, 'buffer', 'enable')
    length = os.path.join(sysfs, 'buffer', 'length')

    try:
        write_text(enable, 0)
    except OSError:
        pass

    for p in sorted(glob.glob(os.path.join(sysfs, 'scan_elements', '*_en'))):
        write_text(p, 1)

    write_text(length, BUFFER_LENGTH)
    write_text(enable, 1)

    # Report the effective settings to stderr. On this DMAEngine buffer,
    # watermark is read-only, so we observe rather than write it.
    try:
        effective_length = read_text(length)
    except OSError:
        effective_length = '?'

    watermark_path = os.path.join(sysfs, 'buffer', 'watermark')
    try:
        watermark = read_text(watermark_path)
    except OSError:
        watermark = '?'

    print(
        f'control_stream: buffer_length={effective_length}, '
        f'watermark={watermark}, read_frames={READ_FRAMES}',
        file=sys.stderr,
        flush=True,
    )


def disable_iio(sysfs):
    try:
        write_text(os.path.join(sysfs, 'buffer', 'enable'), 0)
    except OSError:
        pass


def reader_loop(devnode):
    global running

    fd = os.open(devnode, os.O_RDONLY)
    pending = bytearray()

    try:
        while running:
            data = os.read(fd, READ_BYTES)
            if not data:
                continue

            pending.extend(data)

            usable = (len(pending) // FRAME_BYTES) * FRAME_BYTES
            if usable == 0:
                continue

            chunk = bytes(pending[:usable])
            del pending[:usable]

            # Monitoring is allowed to drop old data. Never let SSH backpressure
            # stop the local IIO reader and build an unbounded backlog.
            while running:
                try:
                    chunk_queue.put_nowait(chunk)
                    break
                except queue.Full:
                    try:
                        chunk_queue.get_nowait()
                    except queue.Empty:
                        pass
    finally:
        os.close(fd)


def stop_handler(signum, frame):
    global running
    running = False


def main():
    global running

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    sysfs, devnode = find_control_iio()
    configure_iio(sysfs)

    t = threading.Thread(target=reader_loop, args=(devnode,), daemon=True)
    t.start()

    out = sys.stdout.buffer

    try:
        while running:
            try:
                chunk = chunk_queue.get(timeout=0.5)
            except queue.Empty:
                continue

            try:
                out.write(chunk)
                out.flush()
            except (BrokenPipeError, OSError):
                running = False
                break
    finally:
        running = False
        disable_iio(sysfs)


if __name__ == '__main__':
    main()
