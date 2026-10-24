#!/usr/bin/env python3
"""Build the hash-verified, offline Git runtime and native prompt helper."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
build = args.build_dir.resolve()
subprocess.run(['cmake', '-S', str(root / 'native'), '-B', str(build), '-G', 'Ninja'], check=True)
subprocess.run(['cmake', '--build', str(build)], check=True)
subprocess.run([str(build / 'git-runtime/bin/git'), '--version'], check=True)
