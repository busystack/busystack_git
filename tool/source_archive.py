#!/usr/bin/env python3
"""Create a deterministic, source-complete package archive (no build/cache data)."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import tarfile

EXCLUDED = {'.git', '.dart_tool', 'build', 'coverage', '__pycache__', '.idea', '.codex', '.agents'}

def files(root):
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if any(part in EXCLUDED for part in relative.parts) or path.suffix in {'.pyc', '.log', '.snap'}:
            continue
        if path.is_symlink():
            raise ValueError(f'Source archives require regular files: {relative}')
        if path.is_file():
            yield path

def tree_digest(root):
    digest = hashlib.sha256()
    for path in files(root):
        digest.update(path.relative_to(root).as_posix().encode() + b'\0')
        digest.update(b'x' if path.stat().st_mode & 0o111 else b'-')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()

def archive(root, output):
    root = root.resolve()
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode='w', format=tarfile.PAX_FORMAT) as tar:
        for path in files(root):
            body = path.read_bytes()
            entry = tarfile.TarInfo(f'{root.name}/{path.relative_to(root).as_posix()}')
            entry.size = len(body)
            entry.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            entry.uid = entry.gid = entry.mtime = 0
            tar.addfile(entry, io.BytesIO(body))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(gzip.compress(payload.getvalue(), mtime=0))
    return {'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'tree_sha256': tree_digest(root)}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    for key, value in archive(args.package, args.output).items():
        print(f'{key}={value}')
