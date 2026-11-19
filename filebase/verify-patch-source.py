#!/usr/bin/env python3
"""Verify every imported build input against the pinned reviewed source tree."""
import hashlib
import pathlib
import subprocess

SOURCE = '29e7c87140a9d88ffd3cf26ff07852bb81dc0a4a'
root = pathlib.Path(__file__).resolve().parents[1]
paths = subprocess.check_output(
    ['git', 'ls-tree', '-r', '--name-only', SOURCE, '--', 'images/nginx'],
    cwd=root, text=True,
).splitlines()
for name in paths:
    expected = subprocess.check_output(['git', 'show', f'{SOURCE}:{name}'], cwd=root)
    actual = (root / name).read_bytes()
    if actual != expected:
        raise SystemExit(f'Imported source differs: {name}')
patches = sorted((root / 'images/nginx/rootfs/patches').glob('*.patch'))
assert len(patches) == 59, f'Expected patches 00-58, got {len(patches)}'
assert [int(p.name.split('_')[0]) for p in patches] == list(range(59))
for p in patches:
    print(hashlib.sha256(p.read_bytes()).hexdigest(), p.relative_to(root))
print(f'PASS: {len(paths)} imported files match {SOURCE}; 59 ordered patches')
