#!/usr/bin/env python3
"""Write RELEASE-MANIFEST.txt and SHA256SUMS for this package folder.

Run from anywhere after the final builds and validation:

    python3 tests/make_release_manifest.py

The payload is every file git would commit here (tracked, or untracked and not
ignored), plus this version's two phone wheels, which phone/.gitignore ignores
and the release commits with `git add -f`. The manifest is sorted and lists
itself and SHA256SUMS; SHA256SUMS covers every listed file except itself.
tests/package_release.py checks the result.

Refuses symbolic links, a missing or extra phone wheel, and a committed binary
older than the native sources it is built from. Warns while CHANGELOG.md or
VALIDATION.md still describe a release in development.
"""
from pathlib import Path
import hashlib, subprocess, sys

root = Path(__file__).resolve().parent.parent
version = (root / 'VERSION').read_text().strip()
MANIFEST, SUMS = 'RELEASE-MANIFEST.txt', 'SHA256SUMS'

listed = subprocess.run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '.'],
                        cwd=root, check=True, capture_output=True).stdout.decode().split('\0')
names = {n for n in listed if n and (root / n).exists()}       # a tracked file since deleted is not shipped

wheels = sorted(p.relative_to(root).as_posix() for p in (root / 'phone' / 'wheels').glob('*.whl'))
expected = ['phone/wheels/psychmetal-%s-cp314-cp314-ios_15_0_arm64_%s.whl' % (version, sdk)
            for sdk in ('iphoneos', 'iphonesimulator')]
if wheels != expected:
    raise SystemExit('phone/wheels must hold exactly this version\'s two wheels:\n  ' + '\n  '.join(expected) +
                     '\nfound:\n  ' + ('\n  '.join(wheels) or '(none)'))
names |= set(wheels) | {MANIFEST, SUMS}

for name in names:
    if (root / name).is_symlink():
        raise SystemExit('Symbolic link in the payload: ' + name)

# Binaries are committed, so one built before a source change would ship stale.
native = [p for pattern in ('*.h', '*.mm', '*.cpp', '*.metal') for p in root.glob(pattern)]
python = list((root / 'python' / 'psychmetal').glob('*.py'))
binaries = {'PsychMetalCore.mex': native, 'PsychMetalCore.mexmaca64': native}
binaries.update({p.relative_to(root).as_posix(): native for p in (root / 'python' / 'psychmetal').glob('_psychmetal*.so')})
binaries.update({w: native + python for w in wheels})
for binary, sources in binaries.items():
    if binary not in names:
        raise SystemExit('Binary missing from the payload: ' + binary)
    newest = max(sources, key=lambda p: p.stat().st_mtime)
    if (root / binary).stat().st_mtime < newest.stat().st_mtime:
        raise SystemExit('%s is older than %s; rebuild before writing the manifest.'
                         % (binary, newest.relative_to(root).as_posix()))

ordered = sorted(names)
(root / MANIFEST).write_text('\n'.join(ordered) + '\n')
(root / SUMS).write_text(''.join('%s  %s\n' % (hashlib.sha256((root / n).read_bytes()).hexdigest(), n)
                                 for n in ordered if n != SUMS))
print('Wrote %s and %s: %d files, version %s.' % (MANIFEST, SUMS, len(ordered), version))

if '— development' in (root / 'CHANGELOG.md').read_text().split('\n## ', 2)[1].splitlines()[0]:
    print('Warning: CHANGELOG.md still says development; set the release date and run this again.', file=sys.stderr)
if 'in progress' in (root / 'VALIDATION.md').read_text().splitlines()[0]:
    print('Warning: VALIDATION.md is still marked in progress.', file=sys.stderr)
