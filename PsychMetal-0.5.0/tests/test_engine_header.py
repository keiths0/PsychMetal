#!/usr/bin/env python3
"""The engine boundary is consistent with itself and both front ends.

1. PsychMetalEngine.h compiles standalone as C++17 with only standard headers,
   and every function it declares is defined exactly once by the engine.
2. Every command PsychMetalMex.cpp dispatches has an engine entry in the header.
3. The header, the MEX front end and the Python front end list the Diagnostic
   fields in the same order, and the history has 17 columns.
4. Sources spell PsychMetal:* identifiers only through the header's constants.
"""
from pathlib import Path
import collections
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
read = lambda name: (root / name).read_text()
header, engine, shared = read('PsychMetalEngine.h'), read('PsychMetalEngine.mm'), read('PsychMetalShared.cpp')
mex, python = read('PsychMetalMex.cpp'), read('PsychMetalPython.cpp')
failures = []


def fail(message):
    failures.append(message)


# 1. Header -----------------------------------------------------------------------
includes = re.findall(r'^\s*#\s*(?:include|import)\s*[<"]([^>"]+)', header, re.M)
for inc in includes:
    if inc not in {'array', 'cstddef', 'cstdint', 'optional', 'stdexcept', 'string', 'vector'}:
        fail(f'header includes non-standard or host header <{inc}>')
declared = set(re.findall(r'^\s*(?:\[\[noreturn\]\]\s+)?(?:PM_BLOCKING\s+)?(?:const\s+)?[\w:<>, ]+?[\s*&]+(\w+)\(',
                          header, re.M)) - {'Error', 'count', 'id', 'runtime_error'}
definitions = collections.Counter(re.findall(r'^[\w:<>, *&]*?\bpm::(\w+)\([^;]*?\)\s*(?:noexcept\s*)?\{', engine + shared, re.M))
for name in sorted(declared):
    if definitions[name] != 1:
        fail(f'pm::{name} is defined {definitions[name]} times in the engine')
compiler = shutil.which('clang++') or shutil.which('g++')
if compiler:
    probe = '#include "PsychMetalEngine.h"\n' + ''.join(
        f'static const void *p_{n} = reinterpret_cast<const void *>(&pm::{n});\n' for n in sorted(declared))
    with tempfile.TemporaryDirectory() as temp:
        src = Path(temp) / 'probe.cpp'
        src.write_text(probe)
        r = subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Wpedantic', '-Wno-unused-variable',
                            '-fsyntax-only', '-iquote', str(root), str(src)], capture_output=True, text=True)
        if r.returncode:
            fail('header does not compile standalone:\n' + r.stderr)
print(f'Header: {len(declared)} functions, standard headers only, each defined once.')

# 2. Commands ------------------------------------------------------------------------
commands = set(re.findall(r'\bis\("(\w+)"\)', mex))
documented = set(re.findall(r"'(\w+)'", header))
for c in sorted(commands - documented):
    fail(f'MEX command {c} has no engine entry in the header')
print(f'Commands: {len(commands)}, each with an engine entry.')

# 3. Diagnostic fields and history columns ----------------------------------------------
m = re.search(r'const char \*n\[\] = \{(.*?)\};', mex, re.S)
mex_fields = re.findall(r'"(\w+)"', m.group(1))
body = re.sub(r'//[^\n]*', '', re.search(r'struct DiagnosticSummary \{(.*?)\n\};', header, re.S).group(1))
struct_fields = []
for decl in filter(None, (d.strip() for d in body.split(';'))):
    struct_fields += [f.strip() for f in re.sub(r'^(?:double|bool|std::string|Rect4)\s+', '', decl).split(',')]
py_body = python[python.index('PyObject *py_diagnostic('):python.index('#define PM_METHOD')]
py_fields = re.findall(r'\b(?:num|flag|text|r4)\("(\w+)"', py_body)
if mex_fields != struct_fields:
    fail('DiagnosticSummary order differs from the MEX field list')
if py_fields != mex_fields:
    fail('Python diagnostic fields differ from the MEX field list')
record = re.sub(r'//[^\n]*', '', re.search(r'struct FrameRecord \{(.*?)\n\};', header, re.S).group(1))
members = sum(len(d.split(',')) for d in record.split(';') if d.strip())
if members != 17:
    fail(f'FrameRecord has {members} members, not 17')
print(f'Diagnostic: {len(mex_fields)} fields in the same order in header, MEX and Python; 17 history columns.')

# 4. Identifiers -----------------------------------------------------------------------------
named = set(re.findall(r'=\s*"(PsychMetal:\w+)"', header))
for name, text in [('engine', engine), ('shared', shared), ('MEX', mex), ('Python', python)]:
    for i in sorted(set(re.findall(r'"(PsychMetal:\w+)"', text))):
        fail(f'{name} front end spells identifier {i} directly; use the header constant')
print(f'Identifiers: {len(named)} constants, used everywhere.')

if failures:
    print('\n'.join('FAIL: ' + f for f in failures))
    sys.exit(1)
