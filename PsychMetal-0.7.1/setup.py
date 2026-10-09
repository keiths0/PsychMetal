"""Builds psychmetal._psychmetal: the engine and the Python front end in one
extension. Everything else about the package is in pyproject.toml.

The engine is Objective-C++ (PsychMetalEngine.mm), so this only teaches
setuptools the .mm suffix and adds ARC for that file; clang picks the language
from the suffix. The package folder is never added with -I: on a
case-insensitive disk its VERSION file would answer #include <version>, and the
sources include each other with quotes, which needs no search path.

Two targets: a Mac (Apple silicon), and an iPhone or iPad, which is what
sys.platform reports as 'ios' when cibuildwheel builds for one
(cibuildwheel --platform ios). They differ only in the system frameworks the
engine links."""
import os
import platform
import sys
import sysconfig

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext

PHONE = sys.platform == 'ios'
options = {}
if PHONE:
    # The engine needs iOS 15. The compiler takes that from the environment; the
    # wheel's name would otherwise carry the version this Python was built for.
    target = os.environ.setdefault('IPHONEOS_DEPLOYMENT_TARGET', '15.0')
    system, _, rest = sysconfig.get_platform().split('-', 2)      # ios-13.0-arm64-iphoneos
    options['bdist_wheel'] = {'plat_name': f'{system}-{target}-{rest}'}
else:
    os.environ.setdefault('MACOSX_DEPLOYMENT_TARGET', '14.0')


class BuildExt(build_ext):
    def build_extensions(self):
        if not PHONE and (sys.platform != 'darwin' or platform.machine() != 'arm64'):
            sys.exit('psychmetal needs macOS on Apple silicon (arm64) with an arm64 Python, or an iOS build.')
        compiler = self.compiler
        compiler.src_extensions.append('.mm')
        compile_one = compiler._compile

        def compile_with_arc(obj, src, ext, cc_args, extra_postargs, pp_opts):
            extra = list(extra_postargs) + (['-fobjc-arc'] if src.endswith('.mm') else [])
            compile_one(obj, src, ext, cc_args, extra, pp_opts)

        compiler._compile = compile_with_arc
        super().build_extensions()


if PHONE:
    frameworks = ['UIKit', 'Foundation', 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText']
else:
    frameworks = ['Cocoa', 'Metal', 'QuartzCore', 'CoreGraphics', 'Carbon', 'CoreText', 'IOKit']
setup(
    ext_modules=[Extension(
        'psychmetal._psychmetal',
        sources=['PsychMetalPython.cpp', 'PsychMetalShared.cpp', 'PsychMetalEngine.mm'],
        language='c++',
        depends=['PsychMetalDisplayLink.h', 'PsychMetalEngine.h', 'PsychMetalInternal.h', 'PsychMetalIOS.h',
                 'PsychMetalReadback.h', 'PsychMetalKeyboardQueue.h', 'PsychMetalShaders.h'],
        extra_compile_args=['-std=c++17', '-stdlib=libc++', '-fexceptions', '-fwrapv', '-ffp-contract=off',
                            '-O2', '-DNDEBUG', '-Wall', '-Wextra'],
        extra_link_args=['-stdlib=libc++'] + [arg for f in frameworks for arg in ('-framework', f)],
    )],
    cmdclass={'build_ext': BuildExt},
    options=options,
)
