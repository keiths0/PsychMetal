#!/usr/bin/env python3
"""Exercise release selection and artifact guards without network or builds."""
from contextlib import contextmanager
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

from package_target import select
from check_distributions import check


@contextmanager
def fixture():
    before = Path.cwd()
    with tempfile.TemporaryDirectory() as folder:
        os.chdir(folder)
        try:
            subprocess.run(['git', 'init', '-q'], check=True)
            yield
        finally:
            os.chdir(before)


def package(version, declared=None):
    p = Path('PsychMetal-' + version)
    p.mkdir()
    (p / 'VERSION').write_text(version + '\n')
    (p / 'pyproject.toml').write_text(f'[project]\nname="psychmetal"\nversion="{declared or version}"\n')


def commit():
    subprocess.run(['git', 'add', '.'], check=True)
    subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-qm', 'fixture'], check=True)
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()


def distributions(version='0.11.0'):
    Path('dist').mkdir()
    metadata = f'Metadata-Version: 2.4\nName: psychmetal\nVersion: {version}\n'.encode()
    with zipfile.ZipFile('dist/test.whl', 'w') as z:
        z.writestr(f'psychmetal-{version}.dist-info/METADATA', metadata)
    with tarfile.open('dist/test.tar.gz', 'w:gz') as t:
        info = tarfile.TarInfo(f'psychmetal-{version}/PKG-INFO')
        info.size = len(metadata)
        t.addfile(info, io.BytesIO(metadata))


class Workflows(unittest.TestCase):
    def test_branch_selects_numeric_latest(self):
        with fixture():
            for v in ['0.9.0', '0.10.1', '0.11.0']:
                package(v)
            commit()
            self.assertEqual(select()['package_dir'], 'PsychMetal-0.11.0')

    def test_tag_pins_old_sources(self):
        with fixture():
            package('0.11.0')
            original = commit()
            subprocess.run(['git', 'tag', 'v0.11.0'], check=True)
            package('0.12.0')
            commit()
            result = select('v0.11.0', publish=True)
            self.assertEqual(result['version'], '0.11.0')
            self.assertEqual(result['commit'], original)
            self.assertEqual(result['publish'], 'true')

    def test_publication_requires_tag(self):
        with self.assertRaises(ValueError):
            select(publish=True)

    def test_bad_tag_rejected(self):
        for tag in ['main', 'v0.11.0;echo bad', '../v0.11.0', 'v00.11.0']:
            with self.assertRaises(ValueError):
                select(tag)

    def test_version_mismatch_rejected(self):
        with fixture():
            package('0.11.0', '0.10.1')
            commit()
            with self.assertRaises(ValueError):
                select()
            subprocess.run(['git', 'tag', 'v0.11.0'], check=True)
            with self.assertRaises(ValueError):
                select('v0.11.0')

    def test_distribution_versions(self):
        with fixture():
            distributions()
            check('dist', '0.11.0')
            with self.assertRaises(ValueError):
                check('dist', '0.10.1')

    def test_unexpected_artifact_rejected(self):
        with fixture():
            distributions()
            Path('dist/old-release.zip').touch()
            with self.assertRaises(ValueError):
                check('dist', '0.11.0')

    def test_missing_wheel_rejected(self):
        with fixture():
            distributions()
            Path('dist/test.whl').unlink()
            with self.assertRaises(ValueError):
                check('dist', '0.11.0')


if __name__ == '__main__':
    unittest.main()
