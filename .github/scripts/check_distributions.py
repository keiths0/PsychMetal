#!/usr/bin/env python3
"""Refuse mixed versions, missing distributions and non-package artifacts."""
import argparse
from email.parser import BytesParser
from pathlib import Path
import tarfile
import zipfile


def check(folder, version):
    wheels = sources = 0
    for path in sorted(Path(folder).iterdir()):
        if path.name.endswith('.whl'):
            with zipfile.ZipFile(path) as archive:
                members = [n for n in archive.namelist() if n.endswith('.dist-info/METADATA')]
                if len(members) != 1:
                    raise ValueError(f'{path}: expected one METADATA file')
                metadata = BytesParser().parsebytes(archive.read(members[0]))
            wheels += 1
        elif path.name.endswith('.tar.gz'):
            with tarfile.open(path) as archive:
                members = [m for m in archive.getmembers()
                           if m.name.endswith('/PKG-INFO') and len(Path(m.name).parts) == 2]
                if len(members) != 1:
                    raise ValueError(f'{path}: expected one root PKG-INFO file')
                metadata = BytesParser().parsebytes(archive.extractfile(members[0]).read())
            sources += 1
        else:
            raise ValueError(f'Unexpected distribution artifact: {path}')
        if metadata['Name'] != 'psychmetal' or metadata['Version'] != version:
            raise ValueError(f'{path}: metadata does not match psychmetal {version}')
        print(f'PASS: {path.name} metadata is psychmetal {version}')
    if wheels < 1 or sources != 1:
        raise ValueError('Expected at least one wheel and exactly one source archive.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder')
    parser.add_argument('version')
    args = parser.parse_args()
    check(args.folder, args.version)
