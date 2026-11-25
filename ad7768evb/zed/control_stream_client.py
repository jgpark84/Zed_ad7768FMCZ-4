#!/usr/bin/env python3
import subprocess
import threading
import time
from dataclasses import dataclass

import numpy as np


FRAME_BYTES = 32

# 6 x signed int32 + 4 x unsigned int16 = 32 bytes
CONTROL_DTYPE = np.dtype([
    ("avg0",   "<i4"),
    ("avg1",   "<i4"),
    ("avg2",   "<i4"),
    ("avg3",   "<i4"),
    ("phase0", "<i4"),
    ("phase1", "<i4"),
    ("ao0",    "<u2"),
    ("ao1",    "<u2"),
    ("ao2",    "<u2"),
    ("ao3",    "<u2"),
])

BAM_TO_RAD = 2.0 * np.pi / (2 ** 32)


@dataclass
class StreamStats:
    received_frames: int = 0
    dropped_pc_bytes: int = 0
    reconnects: int = 0


class SSHControlStream:
    """
    Persistent SSH stream reader.

    One SSH process is kept open:
        ssh -T root@169.254.92.202 python3 /root/control_stream_source.py

    The remote helper continuously drains the IIO DMA locally.
    The PC reader continuously drains the SSH pipe.
    GUI code calls take_all() whenever convenient; no per-frame request is made.
    """

    def __init__(
        self,
        host="root@169.254.92.202",
        remote_command="python3 /root/control_stream_source.py",
        max_pc_backlog_bytes=32 * 262144,
    ):
        self.host = host
        self.remote_command = remote_command
        self.max_pc_backlog_bytes = max_pc_backlog_bytes

        self.proc = None
        self.thread = None
        self.running = False

        self._lock = threading.Lock()
        self._buffer = bytearray()
        self._rx_remainder = bytearray()

        self.stats = StreamStats()

    def start(self):
        if self.running:
            return

        self.running = True
        self.proc = subprocess.Popen(
            ["ssh", "-T", self.host, self.remote_command],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )

        self.thread = threading.Thread(target=self._reader_loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False

        if self.proc is not None:
            try:
                self.proc.terminate()
            except Exception:
                pass

        if self.thread is not None:
            self.thread.join(timeout=1.0)

        self.proc = None
        self.thread = None

    def _reader_loop(self):
        while self.running:
            if self.proc is None or self.proc.stdout is None:
                return

            try:
                data = self.proc.stdout.read(128 * 1024)
            except Exception:
                return

            if not data:
                return

            self._rx_remainder.extend(data)

            usable = (len(self._rx_remainder) // FRAME_BYTES) * FRAME_BYTES
            if usable == 0:
                continue

            aligned = bytes(self._rx_remainder[:usable])
            del self._rx_remainder[:usable]

            with self._lock:
                self._buffer.extend(aligned)

                # Keep only a bounded amount of PC-side backlog.
                # Always drop complete 32-byte frames.
                excess = len(self._buffer) - self.max_pc_backlog_bytes
                if excess > 0:
                    drop = ((excess + FRAME_BYTES - 1) // FRAME_BYTES) * FRAME_BYTES
                    drop = min(drop, len(self._buffer))
                    del self._buffer[:drop]
                    self.stats.dropped_pc_bytes += drop

                self.stats.received_frames += len(aligned) // FRAME_BYTES

    def take_all(self):
        """
        Return every complete frame received since the previous take_all().
        The returned length is variable and follows actual SSH arrival timing.
        """
        with self._lock:
            if not self._buffer:
                return np.empty(0, dtype=CONTROL_DTYPE)

            raw = bytes(self._buffer)
            self._buffer.clear()

        return np.frombuffer(raw, dtype=CONTROL_DTYPE).copy()

    @staticmethod
    def phase_rad(frames, phase_index=0):
        key = "phase0" if phase_index == 0 else "phase1"
        return frames[key].astype(np.float64) * BAM_TO_RAD


if __name__ == "__main__":
    stream = SSHControlStream()
    stream.start()

    print("Streaming. Ctrl+C to stop.")

    try:
        while True:
            time.sleep(0.5)
            frames = stream.take_all()
            if len(frames):
                print(
                    f"{len(frames):6d} frames | "
                    f"AVG0={int(frames['avg0'][-1]):8d} | "
                    f"PH0={SSHControlStream.phase_rad(frames, 0)[-1]:+.6f} rad | "
                    f"AO0={int(frames['ao0'][-1]):5d}"
                )
    except KeyboardInterrupt:
        pass
    finally:
        stream.stop()
