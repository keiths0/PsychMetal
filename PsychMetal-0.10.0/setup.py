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
import subprocess
import sys
import sysconfig
from pathlib import Path

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
    # The engine needs macOS 14 (CAMetalDisplayLink): a lower inherited target
    # would build a wheel labelled for systems it cannot run on.
    requested=os.environ.get('MACOSX_DEPLOYMENT_TARGET','14.0')
    major,minor=(requested.split('.')+['0'])[:2]
    target=requested if (int(major),int(minor))>=(14,0) else '14.0'
    os.environ['MACOSX_DEPLOYMENT_TARGET']=target
    # python.org Python is universal2; this toolbox supports Apple silicon only.
    # Match compiler slices and wheel tags instead of advertising an Intel build.
    os.environ['ARCHFLAGS']='-arch arm64'
    options['bdist_wheel']={'plat_name':f'macosx-{target}-arm64'}


class BuildExt(build_ext):
    def build_extensions(self):
        if not PHONE and (sys.platform != 'darwin' or platform.machine() != 'arm64'):
            sys.exit('psychmetal needs macOS on Apple silicon (arm64) with an arm64 Python, or an iOS build.')
        # The built-in shaders, compiled for this platform and embedded in the
        # engine; in the build's own directory, never beside the sources.
        if PHONE:
            sdk = 'iphonesimulator' if sysconfig.get_platform().endswith('iphonesimulator') else 'iphoneos'
        else:
            sdk = 'macosx'
        shaders = Path(self.build_temp).resolve() / 'shaders'
        subprocess.run([sys.executable, str(Path(__file__).resolve().parent / 'tests' / 'build_metallib.py'),
                        sdk, str(shaders)], check=True)
        compiler = self.compiler
        compiler.src_extensions.append('.mm')
        compile_one = compiler._compile

        def compile_with_arc(obj, src, ext, cc_args, extra_postargs, pp_opts):
            extra = list(extra_postargs) + (['-fobjc-arc', '-iquote', str(shaders)] if src.endswith('.mm') else [])
            compile_one(obj, src, ext, cc_args, extra, pp_opts)

        compiler._compile = compile_with_arc
        super().build_extensions()


if PHONE:
    frameworks = ['UIKit', 'Foundation', 'Metal', 'QuartzCore', 'CoreGraphics', 'CoreText', 'AudioToolbox', 'AVFoundation', 'CoreMedia', 'CoreVideo']
else:
    frameworks = ['Cocoa', 'Metal', 'QuartzCore', 'CoreGraphics', 'Carbon', 'CoreText', 'IOKit', 'AudioToolbox', 'CoreAudio', 'AVFoundation', 'CoreMedia', 'CoreVideo']
setup(
    ext_modules=[Extension(
        'psychmetal._psychmetal',
        sources=['PsychMetalPython.cpp', 'PsychMetalShared.cpp', 'PsychMetalEngine.mm'],
        language='c++',
        depends=['PsychMetalDisplayLink.h', 'PsychMetalEngine.h', 'PsychMetalInternal.h', 'PsychMetalIOS.h',
                 'PsychMetalCustomShader.h', 'PsychMetalLiveTimeline.h', 'PsychMetalKeyframes.h', 'PsychMetalTimeline.h', 'PsychMetalReadback.h', 'PsychMetalKeyboardQueue.h', 'PsychMetalShaders.h',
                 'PsychMetalAudio.h', 'PsychMetalAudioHost.h', 'PsychMetalAudioEngine.h', 'PsychMetalMovie.h', 'PsychMetalShaders.metal'],
        extra_compile_args=['-std=c++17', '-stdlib=libc++', '-fexceptions', '-fwrapv', '-ffp-contract=off',
                            '-O2', '-DNDEBUG', '-Wall', '-Wextra'],
        extra_link_args=['-stdlib=libc++'] + [arg for f in frameworks for arg in ('-framework', f)],
    )],
    cmdclass={'build_ext': BuildExt},
    options=options,
)
