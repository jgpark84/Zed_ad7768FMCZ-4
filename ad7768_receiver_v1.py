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
    p = argparse.ArgumentParser(description="Receive AD7768 averaged 4ch int32 frames over persistent SSH.")
    p.add_argument("--host", default="ad7768")
    p.add_argument("--remote-program", default="/root/raw_acq_verified_v3")
    p.add_argument("-a", "--avg", type=int, default=1024)
    p.add_argument("-o", "--out-dir", default="recordings")
    p.add_argument("--prefix", default="record")
    p.add_argument("--segment-seconds", type=float, default=60.0)
    p.add_argument("--fsync-seconds", type=float, default=5.0)
    return p.parse_args()

def open_segment(out_dir, prefix, seg_index):
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

def main():
    args = parse_args()
    if args.avg < 1:
        print("ERROR: --avg must be >= 1", file=sys.stderr)
        return 2

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    remote_cmd = f"{args.remote_program} -a {args.avg}"
    cmd = ["ssh", args.host, remote_cmd]

    print("Starting persistent SSH stream:", file=sys.stderr)
    print("  " + " ".join(cmd), file=sys.stderr)

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=None, bufsize=0)
    if proc.stdout is None:
        print("ERROR: failed to open SSH stdout pipe", file=sys.stderr)
        return 1

    seg_index = 0
    seg_path, seg_file = open_segment(out_dir, args.prefix, seg_index)
    seg_start = time.monotonic()
    last_fsync = seg_start
    total_frames = 0
    seg_frames = 0
    carry = bytearray()

    print(f"Opened: {seg_path}", file=sys.stderr)

    try:
        while not stop_requested:
            chunk = proc.stdout.read(64 * 1024)
            if not chunk:
                break

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
                print(f"Closed: {seg_path} ({seg_frames} frames, {seg_frames * FRAME_BYTES} bytes)", file=sys.stderr)
                seg_index += 1
                seg_path, seg_file = open_segment(out_dir, args.prefix, seg_index)
                seg_start = now
                last_fsync = now
                seg_frames = 0
                print(f"Opened: {seg_path}", file=sys.stderr)

    finally:
        if carry:
            print(f"Warning: discarded {len(carry)} trailing byte(s)", file=sys.stderr)

        close_segment(seg_file)

        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

        print(f"Stopped. total_frames={total_frames}, total_bytes={total_frames * FRAME_BYTES}, ssh_rc={proc.returncode}", file=sys.stderr)

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
