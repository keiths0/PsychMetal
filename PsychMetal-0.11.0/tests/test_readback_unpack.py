"""Compile the actual readback converters with sanitizers, plus scalar fallback."""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as t:
    exe=Path(t)/'unpack'
    for extra in ([],['-DPM_READBACK_SCALAR']):
        subprocess.run(['clang++','-std=c++17','-O1','-g','-fsanitize=address,undefined','-fno-sanitize-recover=all','-iquote',str(root),*extra,str(root/'tests/test_readback_unpack.cpp'),'-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True)
    if '--benchmark' in sys.argv:
        subprocess.run(['clang++','-std=c++17','-O3','-iquote',str(root),str(root/'tests/test_readback_unpack.cpp'),'-o',str(exe)],check=True)
        subprocess.run([str(exe),'benchmark'],check=True)
