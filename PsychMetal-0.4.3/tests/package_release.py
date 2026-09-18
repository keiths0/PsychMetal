#!/usr/bin/env python3
"""Validate and stage the exact release payload, without rebuilding binaries."""
from pathlib import Path
import hashlib, shutil, sys
root=Path(sys.argv[1]).resolve()
dest=Path(sys.argv[2]).resolve()
if dest == root or root.is_relative_to(dest):
    raise SystemExit('Refusing to replace the source or a parent directory')
names=(root/'RELEASE-MANIFEST.txt').read_text().splitlines()
if len(names)!=len(set(names)) or not names:
    raise SystemExit('Invalid manifest')
for name in names:
    p=Path(name)
    if p.is_absolute() or '..' in p.parts or not (root/p).is_file() or (root/p).is_symlink():
        raise SystemExit('Unsafe or missing file: '+name)
expected={}
for line in (root/'SHA256SUMS').read_text().splitlines():
    digest,name=line.split('  ',1)
    if name in expected: raise SystemExit('Duplicate checksum')
    expected[name]=digest
if set(expected)!=set(names)-{'SHA256SUMS'}:
    raise SystemExit('Checksum list does not match manifest')
for name,digest in expected.items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Checksum mismatch: '+name)
# An existing destination is not silently deleted.
if dest.exists():
    raise SystemExit('Destination already exists; choose a fresh staging directory: '+str(dest))
dest.mkdir(parents=True)
for name in names:
    target=dest/name; target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(root/name,target)
print('Verified and staged %d files: %s' % (len(names),dest))
