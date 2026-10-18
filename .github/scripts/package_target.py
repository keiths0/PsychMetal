#!/usr/bin/env python3
"""Select a package from a release tag or the newest version in this checkout."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tomllib

VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def select(tag='', publish=False):
    if publish and not tag:
        raise ValueError('PyPI publication requires an explicit release tag.')
    if tag:
        if not tag.startswith('v') or not VERSION.fullmatch(tag[1:]):
            raise ValueError('Release tag must have the form vMAJOR.MINOR.PATCH.')
        version = tag[1:]
        commit = git('rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}')
        folder = f'PsychMetal-{version}'
        version_text = git('show', f'{commit}:{folder}/VERSION')
        metadata = tomllib.loads(git('show', f'{commit}:{folder}/pyproject.toml'))
    else:
        candidates = []
        for p in Path('.').glob('PsychMetal-*'):
            version = p.name.removeprefix('PsychMetal-')
            if p.is_dir() and VERSION.fullmatch(version):
                candidates.append((tuple(map(int, version.split('.'))), p))
        if not candidates:
            raise ValueError('No versioned PsychMetal package was found.')
        _, path = max(candidates)
        folder = path.name
        version = folder.removeprefix('PsychMetal-')
        commit = git('rev-parse', 'HEAD')
        version_text = (path / 'VERSION').read_text().strip()
        metadata = tomllib.loads((path / 'pyproject.toml').read_text())
    if version_text != version or metadata['project']['version'] != version:
        raise ValueError(f'{folder}: folder, VERSION and Python package version must agree.')
    if metadata['project']['name'] != 'psychmetal':
        raise ValueError('Selected project is not psychmetal.')
    return {'package_dir': folder, 'version': version, 'commit': commit,
            'tag': tag, 'publish': str(bool(publish)).lower()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', default='')
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    result = select(args.tag, args.publish)
    lines = ''.join(f'{key}={value}\n' for key, value in result.items())
    print(lines, end='')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
            out.write(lines)


if __name__ == '__main__':
    main()
