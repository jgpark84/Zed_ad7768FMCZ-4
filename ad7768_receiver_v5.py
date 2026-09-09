#!/usr/bin/env python3
import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

FRAME_BYTES = 16
HANDSHAKE_BYTES = 24
HANDSHAKE_MAGIC = b"AD7768IX"
stop_requested = False

def read_exact(stream, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise EOFError("stream ended during handshake")
        buf.extend(chunk)
    return bytes(buf)


def on_signal(signum, frame):
    global stop_requested
    stop_requested = True

def parse_args():
    p = argparse.ArgumentParser(
        description="AD7768 PC receiver for persistent board-side daemon."
    )
    p.add_argument("--host", default="ad7768")
    p.add_argument("--remote-client",
                   default="/root/ad7768_stream_client_v2")
    p.add_argument("-a", "--avg", type=int, default=1024)
    p.add_argument("-o", "--out-dir", default="recordings")
    p.add_argument("--prefix", default="record")
    p.add_argument("--segment-seconds", type=float, default=60.0)
    p.add_argument("--fsync-seconds", type=float, default=5.0)
    p.add_argument("--reconnect-seconds", type=float, default=2.0)
    return p.parse_args()

def open_segment(out_dir, prefix, seg_index):
    ts = time.strftime("%Y%m%d_%H%M%S")
    path = out_dir / f"{prefix}_{ts}_{seg_index:04d}.bin"
    return path, open(path, "wb", buffering=1024 * 1024)

def close_segment(f):
    if f is None:
        return
    f.flush()
    os.fsync(f.fileno())
    f.close()

def write_meta(data_path, first_sample_index, num_frames, rec_avg, frame_bytes=16):
    meta_path = Path(str(data_path) + ".meta")
    meta_path.write_text(
        f"first_sample_index={first_sample_index}\n"
        f"num_frames={num_frames}\n"
        f"rec_avg={rec_avg}\n"
        f"frame_bytes={frame_bytes}\n"
    )

def stop_remote_recording(args):
    cmd = ["ssh", args.host, f"{args.remote_client} --stop"]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass

def main():
    args = parse_args()
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    seg_index = 0
    total_frames = 0
    reconnects = 0

    while not stop_requested:
        cmd = ["ssh", args.host, args.remote_client]
        print("Connecting:", " ".join(cmd), file=sys.stderr)

        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=None, bufsize=0)

        if proc.stdout is None:
            return 1

        try:
            hdr = read_exact(proc.stdout, HANDSHAKE_BYTES)
        except EOFError as e:
            print(f"Handshake failed: {e}", file=sys.stderr)
            if proc.poll() is None:
                proc.terminate()
            time.sleep(args.reconnect_seconds)
            continue

        if hdr[:8] != HANDSHAKE_MAGIC:
            print("Handshake magic mismatch", file=sys.stderr)
            if proc.poll() is None:
                proc.terminate()
            time.sleep(args.reconnect_seconds)
            continue

        board_first_index = int.from_bytes(hdr[8:16], "little", signed=False)
        board_rec_avg = int.from_bytes(hdr[16:24], "little", signed=False)

        print(
            f"Handshake: first_sample_index={board_first_index}, "
            f"rec_avg={board_rec_avg}",
            file=sys.stderr
        )

        seg_file = None
        seg_path = None
        seg_start = 0.0
        last_fsync = 0.0
        seg_frames = 0
        seg_first_index = None
        next_sample_index = board_first_index
        carry = bytearray()

        try:
            while not stop_requested:
                chunk = proc.stdout.read(64 * 1024)
                if not chunk:
                    break

                if seg_file is None:
                    seg_path, seg_file = open_segment(
                        out_dir, args.prefix, seg_index)
                    seg_start = time.monotonic()
                    last_fsync = seg_start
                    seg_frames = 0
                    seg_first_index = next_sample_index
                    print(f"Opened: {seg_path}", file=sys.stderr)

                carry.extend(chunk)
                complete = (len(carry) // FRAME_BYTES) * FRAME_BYTES

                if complete:
                    seg_file.write(carry[:complete])
                    nframes = complete // FRAME_BYTES
                    total_frames += nframes
                    seg_frames += nframes
                    next_sample_index += nframes
                    del carry[:complete]

                now = time.monotonic()

                if now - last_fsync >= args.fsync_seconds:
                    seg_file.flush()
                    os.fsync(seg_file.fileno())
                    last_fsync = now

                if now - seg_start >= args.segment_seconds:
                    close_segment(seg_file)
                    write_meta(seg_path, seg_first_index, seg_frames, args.avg, FRAME_BYTES)
                    print(
                        f"Closed: {seg_path} "
                        f"({seg_frames} frames, "
                        f"{seg_frames * FRAME_BYTES} bytes, "
                        f"first_index={seg_first_index})",
                        file=sys.stderr)
                    seg_index += 1
                    seg_file = None
                    seg_path = None

        finally:
            if seg_file is not None:
                close_segment(seg_file)
                write_meta(seg_path, seg_first_index, seg_frames, args.avg, FRAME_BYTES)
                print(
                    f"Closed: {seg_path} "
                    f"({seg_frames} frames, "
                    f"{seg_frames * FRAME_BYTES} bytes, "
                    f"first_index={seg_first_index})",
                    file=sys.stderr)
                seg_index += 1

            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

        if stop_requested:
            break

        reconnects += 1
        print(
            f"Stream lost. Reconnect #{reconnects} in "
            f"{args.reconnect_seconds:g} s...",
            file=sys.stderr)

        deadline = time.monotonic() + args.reconnect_seconds
        while not stop_requested and time.monotonic() < deadline:
            time.sleep(0.1)

    # Intentional PC-side stop: tell daemon to end the recording session,
    # so it does not spill forever after Ctrl+C.
    print("Stopping board recording session...", file=sys.stderr)
    stop_remote_recording(args)

    print(
        f"Stopped. total_frames={total_frames}, "
        f"total_bytes={total_frames * FRAME_BYTES}, "
        f"reconnects={reconnects}",
        file=sys.stderr)

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
