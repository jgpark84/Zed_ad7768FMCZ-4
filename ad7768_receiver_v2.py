#!/usr/bin/env python3
import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

FRAME_BYTES = 16
stop_requested = False


def on_signal(signum, frame):
    global stop_requested
    stop_requested = True


def parse_args():
    p = argparse.ArgumentParser(
        description="Persistent AD7768 receiver with SSH reconnect."
    )
    p.add_argument("--host", default="ad7768")
    p.add_argument("--remote-program", default="/root/raw_acq_verified_v3")
    p.add_argument("-a", "--avg", type=int, default=1024)
    p.add_argument("-o", "--out-dir", default="recordings")
    p.add_argument("--prefix", default="record")
    p.add_argument("--segment-seconds", type=float, default=60.0)
    p.add_argument("--fsync-seconds", type=float, default=5.0)
    p.add_argument("--reconnect-seconds", type=float, default=2.0)
    return p.parse_args()


def open_segment(out_dir: Path, prefix: str, seg_index: int):
    ts = time.strftime("%Y%m%d_%H%M%S")
    path = out_dir / f"{prefix}_{ts}_{seg_index:04d}.bin"
    f = open(path, "wb", buffering=1024 * 1024)
    return path, f


def close_segment(f):
    if f is None:
        return
    f.flush()
    os.fsync(f.fileno())
    f.close()


def start_ssh(args):
    remote_cmd = f"{args.remote_program} -a {args.avg}"
    cmd = ["ssh", args.host, remote_cmd]

    print("Connecting:", " ".join(cmd), file=sys.stderr)

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=None,
        bufsize=0,
    )

    return proc


def stop_ssh(proc):
    if proc is None:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def main():
    args = parse_args()

    if args.avg < 1:
        print("ERROR: --avg must be >= 1", file=sys.stderr)
        return 2

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    seg_index = 0
    total_frames = 0
    reconnect_count = 0

    while not stop_requested:
        proc = start_ssh(args)

        if proc.stdout is None:
            print("ERROR: failed to open SSH stdout pipe", file=sys.stderr)
            stop_ssh(proc)
            return 1

        seg_path = None
        seg_file = None
        seg_start = None
        last_fsync = None
        seg_frames = 0
        carry = bytearray()

        try:
            while not stop_requested:
                chunk = proc.stdout.read(64 * 1024)

                if not chunk:
                    break

                if seg_file is None:
                    seg_path, seg_file = open_segment(
                        out_dir, args.prefix, seg_index
                    )
                    seg_start = time.monotonic()
                    last_fsync = seg_start
                    seg_frames = 0
                    print(f"Opened: {seg_path}", file=sys.stderr)

                carry.extend(chunk)

                complete_bytes = (len(carry) // FRAME_BYTES) * FRAME_BYTES
                if complete_bytes:
                    seg_file.write(carry[:complete_bytes])

                    nframes = complete_bytes // FRAME_BYTES
                    total_frames += nframes
                    seg_frames += nframes

                    del carry[:complete_bytes]

                now = time.monotonic()

                if now - last_fsync >= args.fsync_seconds:
                    seg_file.flush()
                    os.fsync(seg_file.fileno())
                    last_fsync = now

                if now - seg_start >= args.segment_seconds:
                    close_segment(seg_file)

                    print(
                        f"Closed: {seg_path} "
                        f"({seg_frames} frames, "
                        f"{seg_frames * FRAME_BYTES} bytes)",
                        file=sys.stderr,
                    )

                    seg_index += 1
                    seg_path = None
                    seg_file = None
                    seg_start = None
                    last_fsync = None
                    seg_frames = 0

        finally:
            if carry:
                print(
                    f"Warning: discarded {len(carry)} trailing byte(s) "
                    f"from interrupted stream",
                    file=sys.stderr,
                )

            if seg_file is not None:
                close_segment(seg_file)
                print(
                    f"Closed: {seg_path} "
                    f"({seg_frames} frames, "
                    f"{seg_frames * FRAME_BYTES} bytes)",
                    file=sys.stderr,
                )
                seg_index += 1

            rc = proc.poll()
            stop_ssh(proc)

            if rc is None:
                rc = proc.returncode

        if stop_requested:
            break

        reconnect_count += 1

        print(
            f"SSH stream ended (rc={rc}). "
            f"Reconnect #{reconnect_count} in "
            f"{args.reconnect_seconds:g} s...",
            file=sys.stderr,
        )

        deadline = time.monotonic() + args.reconnect_seconds
        while not stop_requested and time.monotonic() < deadline:
            time.sleep(0.1)

    print(
        f"Stopped. total_frames={total_frames}, "
        f"total_bytes={total_frames * FRAME_BYTES}, "
        f"reconnects={reconnect_count}",
        file=sys.stderr,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
