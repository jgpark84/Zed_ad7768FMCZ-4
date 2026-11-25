#!/usr/bin/env python3
"""Fetch closed ZedBoard spill segments matching local recording metadata."""
import argparse
import hashlib
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

REQUIRED = ('run_id', 'session_id', 'first_sample_index', 'num_frames', 'rec_avg', 'frame_bytes')
NAME = re.compile(r'spill_[0-9]{8}_[0-9]{6}_[0-9]+\.bin\.meta')


def parse_meta(raw):
    d = dict(line.split('=', 1) for line in raw.decode('utf-8').splitlines() if '=' in line)
    for k in REQUIRED:
        if k not in d:
            raise ValueError(f'missing metadata field: {k}')
    for k in REQUIRED[1:]:
        d[k] = int(d[k])
        if d[k] < 0 or (k in ('rec_avg', 'frame_bytes') and d[k] == 0):
            raise ValueError(f'invalid {k}')
    return d


def key(d):
    return d['run_id'], d['session_id']


def size(d):
    return d['num_frames'] * d['frame_bytes']


def digest(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.digest()


def ssh(host, cmd):
    return subprocess.check_output(['ssh', '-o', 'BatchMode=yes', host, cmd])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('recordings', type=Path)
    ap.add_argument('--host', default='ad7768')
    ap.add_argument('--remote-dir', default='/root')
    ap.add_argument('--run-id')
    ap.add_argument('--session-id', type=int)
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()
    if not a.recordings.is_dir():
        raise ValueError('recordings directory does not exist')
    formats = {}
    for p in sorted(a.recordings.glob('record_*.bin.meta')):
        d = parse_meta(p.read_bytes())
        if a.run_id is not None and d['run_id'] != a.run_id:
            continue
        if a.session_id is not None and d['session_id'] != a.session_id:
            continue
        data = p.with_suffix('')
        if not data.is_file() or data.stat().st_size != size(d):
            raise ValueError(f'local recording size mismatch: {data}')
        formats.setdefault(key(d), set()).add((d['rec_avg'], d['frame_bytes']))
    if not formats:
        raise ValueError('no matching local record_*.bin.meta files')
    if len(formats) != 1:
        print('Multiple recording sessions; select --run-id and --session-id:')
        for run, session in sorted(formats):
            print(f'  {run}  session_id={session}')
        return 2
    selected, fmt = next(iter(formats.items()))
    if len(fmt) != 1:
        raise ValueError('mixed local recording formats')
    print(f'Selected run_id={selected[0]}, session_id={selected[1]}', flush=True)
    remote = a.remote_dir.rstrip('/') or '/'
    listing = ssh(a.host, 'find ' + shlex.quote(remote) + " -maxdepth 1 -type f -name 'spill_*.bin.meta' -print")
    dest = a.recordings / 'spill'
    matched = fetched = skipped = 0
    for path in sorted(listing.decode().splitlines()):
        name = path.rsplit('/', 1)[-1]
        if not NAME.fullmatch(name):
            continue
        raw = ssh(a.host, 'cat -- ' + shlex.quote(path))
        d = parse_meta(raw)
        if key(d) != selected:
            continue
        if (d['rec_avg'], d['frame_bytes']) not in fmt:
            raise ValueError(f'format mismatch: {path}')
        matched += 1
        print(f'{name}: first={d["first_sample_index"]}, frames={d["num_frames"]}, bytes={size(d)}', flush=True)
        if a.dry_run:
            continue
        dest.mkdir(parents=True, exist_ok=True)
        meta = dest / name
        data = meta.with_suffix('')
        with tempfile.TemporaryDirectory(dir=dest) as tmp:
            temp = Path(tmp) / data.name
            with temp.open('wb') as f:
                subprocess.run(['ssh', '-o', 'BatchMode=yes', a.host, 'cat -- ' + shlex.quote(path[:-5])], stdout=f, check=True)
            if temp.stat().st_size != size(d):
                raise ValueError(f'remote data size mismatch: {path}')
            if ssh(a.host, 'cat -- ' + shlex.quote(path)) != raw:
                raise ValueError(f'remote metadata changed: {path}')
            if data.exists():
                if not data.is_file() or digest(data) != digest(temp):
                    raise ValueError(f'local data conflict, not overwritten: {data}')
            if meta.exists() and meta.read_bytes() != raw:
                raise ValueError(f'local metadata conflict, not overwritten: {meta}')
            if data.exists() and meta.exists():
                skipped += 1
                print('  Already present and verified')
                continue
            if not data.exists():
                temp.replace(data)
            if not meta.exists():
                temp_meta = Path(tmp) / name
                temp_meta.write_bytes(raw)
                temp_meta.replace(meta)
            fetched += 1
            print('  Saved')
    print(f'Matched={matched}, fetched={fetched}, already_present={skipped}')
    if not matched:
        print('No closed spill segments found for this session.')
    if not a.dry_run:
        print(f'Destination: {dest}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        print(f'ERROR: {e}', file=sys.stderr)
        sys.exit(1)
