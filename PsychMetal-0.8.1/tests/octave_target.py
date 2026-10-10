"""Use a Mac deployment target no older than the installed Octave libraries."""
from pathlib import Path
import re
import subprocess


def target():
    minimum = (14, 0)
    directory = subprocess.check_output(['mkoctfile', '-p', 'OCTLIBDIR'], text=True).strip()
    for name in ('liboctmex.dylib', 'liboctinterp.dylib', 'liboctave.dylib'):
        binary = Path(directory) / name
        output = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        values = re.findall(r'\bminos\s+([0-9.]+)', output)
        values += re.findall(r'cmd LC_VERSION_MIN_MACOSX.*?\bversion\s+([0-9.]+)', output, re.S)
        if not values:
            raise RuntimeError('Cannot determine minimum macOS version: ' + str(binary))
        for value in values:
            minimum = max(minimum, tuple(map(int, value.split('.')[:2])))
    return '.'.join(map(str, minimum))


if __name__ == '__main__':
    print(target())
