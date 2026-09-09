#!/usr/bin/env python3
import argparse
import os
import shutil
from pathlib import Path


def parse_meta(path: Path):
    data = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()

    required = ["first_sample_index", "num_frames", "rec_avg", "frame_bytes"]
    missing = [k for k in required if k not in data]
    if missing:
        raise ValueError(f"{path}: missing metadata fields: {missing}")

    return {
        "first_sample_index": int(data["first_sample_index"]),
        "num_frames": int(data["num_frames"]),
        "rec_avg": int(data["rec_avg"]),
        "frame_bytes": int(data["frame_bytes"]),
    }


def collect_segments(paths):
    segments = []

    for root in paths:
        root = Path(root)
        if root.is_file() and root.suffix == ".meta":
            metas = [root]
        elif root.is_dir():
            metas = sorted(root.glob("*.meta"))
        else:
            raise FileNotFoundError(f"Not found: {root}")

        for meta_path in metas:
            data_path = Path(str(meta_path)[:-5])  # remove ".meta"

            if not data_path.exists():
                print(f"WARNING: data file missing for {meta_path}")
                continue

            meta = parse_meta(meta_path)

            expected_bytes = meta["num_frames"] * meta["frame_bytes"]
            actual_bytes = data_path.stat().st_size

            if actual_bytes != expected_bytes:
                print(
                    f"WARNING: size mismatch: {data_path} "
                    f"actual={actual_bytes}, expected={expected_bytes}"
                )

            segments.append({
                "data_path": data_path,
                "meta_path": meta_path,
                **meta,
            })

    return segments


def main():
    ap = argparse.ArgumentParser(
        description="Reconstruct AD7768 live + spill segments by sample index."
    )
    ap.add_argument(
        "inputs",
        nargs="+",
        help="Directories or .meta files containing live/spill segments",
    )
    ap.add_argument(
        "-o", "--output",
        default="reconstructed.bin",
        help="Output reconstructed binary file",
    )
    ap.add_argument(
        "--meta-output",
        default=None,
        help="Output metadata path; default: <output>.meta",
    )
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Abort on overlap or gap instead of reporting it",
    )
    args = ap.parse_args()

    segments = collect_segments(args.inputs)

    if not segments:
        print("No valid segments found.")
        return 1

    # Verify common format.
    rec_avgs = {s["rec_avg"] for s in segments}
    frame_bytes_set = {s["frame_bytes"] for s in segments}

    if len(rec_avgs) != 1:
        raise RuntimeError(f"Mixed rec_avg values found: {sorted(rec_avgs)}")

    if len(frame_bytes_set) != 1:
        raise RuntimeError(
            f"Mixed frame_bytes values found: {sorted(frame_bytes_set)}"
        )

    rec_avg = segments[0]["rec_avg"]
    frame_bytes = segments[0]["frame_bytes"]

    # Sort by board/global sample index.
    segments.sort(key=lambda s: (s["first_sample_index"], str(s["data_path"])))

    print("\nSegments in reconstruction order:")
    for s in segments:
        end = s["first_sample_index"] + s["num_frames"]
        print(
            f"  [{s['first_sample_index']:>12} .. {end:>12}) "
            f"{s['num_frames']:>8} frames  {s['data_path']}"
        )

    # Check continuity and build plan.
    selected = []
    cursor = None
    gaps = []
    overlaps = []

    for s in segments:
        start = s["first_sample_index"]
        end = start + s["num_frames"]

        if cursor is None:
            selected.append((s, 0, s["num_frames"]))
            cursor = end
            continue

        if start == cursor:
            selected.append((s, 0, s["num_frames"]))
            cursor = end
            continue

        if start > cursor:
            gap = start - cursor
            gaps.append((cursor, start, gap))
            msg = f"GAP: [{cursor}, {start}) = {gap} frames"
            if args.strict:
                raise RuntimeError(msg)
            print("WARNING:", msg)

            selected.append((s, 0, s["num_frames"]))
            cursor = end
            continue

        # start < cursor: overlap
        overlap = cursor - start
        overlaps.append((start, cursor, overlap))

        if end <= cursor:
            # Entire segment already covered by earlier segment(s).
            print(
                f"WARNING: fully overlapped segment skipped: "
                f"{s['data_path']} ({s['num_frames']} frames)"
            )
            if args.strict:
                raise RuntimeError(
                    f"Fully overlapped segment: {s['data_path']}"
                )
            continue

        msg = (
            f"OVERLAP: {s['data_path']} first {overlap} frames "
            f"already covered; trimming overlap"
        )
        if args.strict:
            raise RuntimeError(msg)
        print("WARNING:", msg)

        remaining = end - cursor
        selected.append((s, overlap, remaining))
        cursor = end

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    total_written_frames = 0
    first_index = selected[0][0]["first_sample_index"]
    last_index = first_index

    with open(out_path, "wb", buffering=1024 * 1024) as out:
        for s, skip_frames, take_frames in selected:
            byte_offset = skip_frames * frame_bytes
            byte_count = take_frames * frame_bytes

            with open(s["data_path"], "rb") as src:
                src.seek(byte_offset)

                remaining = byte_count
                while remaining > 0:
                    chunk = src.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise RuntimeError(
                            f"Unexpected EOF in {s['data_path']}"
                        )
                    out.write(chunk)
                    remaining -= len(chunk)

            total_written_frames += take_frames
            last_index = max(
                last_index,
                s["first_sample_index"] + skip_frames + take_frames,
            )

        out.flush()
        os.fsync(out.fileno())

    meta_out = (
        Path(args.meta_output)
        if args.meta_output
        else Path(str(out_path) + ".meta")
    )

    # Note: num_frames is number physically present in reconstructed file.
    # span_frames includes gaps if any existed.
    span_frames = last_index - first_index

    meta_out.write_text(
        f"first_sample_index={first_index}\n"
        f"num_frames={total_written_frames}\n"
        f"span_frames={span_frames}\n"
        f"rec_avg={rec_avg}\n"
        f"frame_bytes={frame_bytes}\n"
        f"gap_count={len(gaps)}\n"
        f"overlap_count={len(overlaps)}\n"
    )

    print("\nReconstruction complete")
    print(f"  output              : {out_path}")
    print(f"  output meta         : {meta_out}")
    print(f"  first_sample_index  : {first_index}")
    print(f"  frames written      : {total_written_frames}")
    print(f"  index span          : {span_frames}")
    print(f"  gaps                : {len(gaps)}")
    print(f"  overlaps            : {len(overlaps)}")
    print(f"  output bytes        : {out_path.stat().st_size}")

    if gaps:
        print("\nGap ranges:")
        for a, b, n in gaps:
            print(f"  [{a}, {b}) : {n} frames")

    if overlaps:
        print("\nOverlap ranges:")
        for a, b, n in overlaps:
            print(f"  [{a}, {b}) : {n} frames")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
