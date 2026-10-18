#!/usr/bin/env python3
"""Portable local regression runner. Steps that need a built binary, Octave, a
Mac or a GPU run where those exist and say so where they do not."""
from pathlib import Path
import os
import argparse
import shutil
import subprocess
import sys
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-media-fixtures', action='store_true',
                    help='explicitly omit AVFoundation test-movie encoding/decoding; no movie validation is claimed')
args = parser.parse_args()
root=Path(__file__).resolve().parents[1]
# UndefinedBehaviorSanitizer otherwise logs some faults and returns success.
# A regression suite must fail, not quietly accept a misaligned access.
os.environ['UBSAN_OPTIONS'] = os.environ.get('UBSAN_OPTIONS', '') + ':halt_on_error=1'
skipped=[]  # what this run did not check, repeated at the end
def run(args, skip=False):
    print('+ '+' '.join(map(str,args)),flush=True)
    result=subprocess.run(list(map(str,args)),cwd=root)
    if skip and result.returncode==77:
        print('Metal pixel validation SKIPPED; run on a Mac with an accessible GPU.',flush=True)
        skipped.append('Metal pixel validation ('+Path(str(args[0])).name+')')
    elif result.returncode:
        raise SystemExit(result.returncode)
octave=shutil.which('octave')
# MATLAB/Octave wrapper against its .m mock, then headless against the real
# PsychMetalCore built in this folder (make octave).
# The committed binaries are for macOS: only a Mac can load them.
mac=sys.platform=='darwin'
tests=['test_wrapper']+(['test_headless'] if mac and (root/'PsychMetalCore.mex').exists() else [])
for test in tests if octave else []:
    # Run outside the package directory so the explicit mock path can take precedence.
    expression="addpath('%s'); %s('%s');" % (str(root/'tests').replace("'","''"),test,str(root).replace("'","''"))
    result=subprocess.run(['octave','--no-gui','--quiet','--eval',expression],cwd=tempfile.gettempdir())
    if result.returncode: raise SystemExit(result.returncode)
if not octave: print('Octave not found: MATLAB wrapper tests SKIPPED.'); skipped.append('MATLAB wrapper tests (no Octave)')
elif 'test_headless' not in tests: print('No PsychMetalCore.mex for this machine (make octave on a Mac): real-MEX headless test SKIPPED.'); skipped.append('real-MEX headless test')
# Engine internals, boundary and parity, both front ends against the scripted
# engine, and the real Python extension headless.
for test in ['test_noise_demo.py','test_hdr_demo.py','test_hdr_readback.py','test_imaging_program.py','test_resource_lifetime.py','test_texture_upload.py','test_display_modes.py','test_store_packaging.py','test_readback_unpack.py','test_stimulus_native.py','test_masked_image_native.py','test_shader_native.py','test_masked_image_demo.py','test_play_timeline.py','test_engine_header.py','test_typecheck.py','test_mouse_dispatch.py','test_native_dispatch.py','test_noise_layout.py','test_mask_cache.py','test_fingers.py',
             'test_timing_target.py','test_wait_margin.py','test_flip_status.py','test_queue_results.py','test_virtual_queue.py','test_export_render.py','test_export_lifecycle.py','test_render_failure.py','test_secure_input.py','test_startup_ready.py','test_frontends.py',
             'test_python_headless.py','test_phone_reports.py','test_recording_writer.py','test_record_demo_replay.py','test_recording_interleave.py','test_recording_lifetime.py','test_audio_recovery.py','test_audio_mac_recovery.py','test_recording_file.py','test_movie_prefetch.py','test_movie_presentations.py','test_movie_audio_bounds.py','test_movie_metadata.py','test_offline_recording_audio.py']:
    run([sys.executable,root/'tests'/test])
with tempfile.TemporaryDirectory(prefix='psychmetal-tests-') as temp:
    for sanitizer in ('address,undefined','thread'):
        binary=Path(temp)/('recording-clock-'+sanitizer.replace(',','-'))
        run(['clang++','-std=c++17','-pthread','-iquote',root,'-fsanitize='+sanitizer,root/'tests/test_recording_clock.cpp','-o',binary]);run([binary])
    for sanitizer in ('address,undefined','thread'):
        binary=Path(temp)/('audio-stream-'+sanitizer.replace(',','-'))
        run(['clang++','-std=c++17','-pthread','-iquote',root,'-fsanitize='+sanitizer,root/'tests/test_audio_stream.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'live-timeline'
    run(['clang++','-std=c++17','-pthread','-fsanitize=address,undefined',root/'tests/test_live_timeline.cpp',root/'PsychMetalShared.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'timeline'
    run(['clang++','-std=c++17','-fsanitize=address,undefined',root/'tests/test_timeline.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'audio-core'
    run(['clang++','-std=c++17','-pthread','-Wall','-Wextra','-Wpedantic','-fsanitize=address,undefined','-iquote',root,root/'tests/test_audio_core.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'audio-core-threads'
    run(['clang++','-std=c++17','-pthread','-fsanitize=thread','-iquote',root,root/'tests/test_audio_core.cpp','-o',binary]);run([binary])
    for sanitizer in ['address,undefined', 'thread']:
        binary=Path(temp)/('audio-host-' + sanitizer.replace(',', '-'))
        run(['clang++','-std=c++17','-pthread','-Wall','-Wextra','-Wpedantic','-fsanitize='+sanitizer,'-iquote',root,root/'tests/test_audio_host.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'shared'
    run(['clang++','-std=c++17','-Wall','-Wextra','-fsanitize=address,undefined','-iquote',root,root/'tests/test_shared.cpp',root/'PsychMetalShared.cpp','-o',binary]);run([binary])
    binary=Path(temp)/'queue'
    run(['clang++','-std=c++17','-pthread','-fsanitize=address,undefined',root/'tests/test_keyboard_queue.cpp','-o',binary]);run([binary])
    if sys.platform=='darwin':
        binary=Path(temp)/'readback-buffer'
        run(['clang++','-std=c++17','-fobjc-arc','-iquote',root,'-framework','Foundation','-framework','Metal',root/'tests/test_readback_buffer.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'imaging-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_imaging_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal','-framework','CoreGraphics',root/'tests/test_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'display-link-handoff'
        run(['clang++','-std=c++17','-fobjc-arc','-mmacosx-version-min=14.0','-Wall','-Wextra','-Wpedantic','-framework','Foundation','-framework','QuartzCore','-framework','Metal',root/'tests/test_display_link.mm','-o',binary]);run([binary])
        binary=Path(temp)/'stimulus-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_stimulus_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'masked-image-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_masked_image_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'polygon-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_polygon_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'arc-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_arc_metal.mm','-o',binary]);run([binary],skip=True)
        binary=Path(temp)/'transform-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_transform_metal.mm','-o',binary]);run([binary],skip=True)
        # Movies with every frame numbered, for the inventory tests and the movie demo.
        binary=Path(temp)/'make-test-movie'
        run(['clang++','-std=c++17','-fobjc-arc','-mmacosx-version-min=14.0','-Wall','-Wextra','-framework','Foundation',
             '-framework','AVFoundation','-framework','CoreMedia','-framework','CoreVideo','-framework','CoreGraphics',root/'tests/make_test_movie.mm','-o',binary])
        if args.skip_media_fixtures:
            print('Movie encoding/decoding fixtures SKIPPED by explicit --skip-media-fixtures; media hardware validation remains pending.', flush=True)
            skipped.append('movie encoding/decoding fixtures (--skip-media-fixtures)')
        else:
            movies=root/'tests'/'movies'
            movies.mkdir(exist_ok=True)
            for name,args in [('frames_prores4444.mov',['prores4444']),('frames_h264.mp4',['h264']),('frames_hevc.mov',['hevc']),
                              ('frames_24fps.mov',['prores422','160','96','24','48']),
                              ('frames_portrait.mov',['hevc','160','96','30','30','0','90'])]:
                run([binary,movies/name]+args)
        binary=Path(temp)/'custom-shader-metal'
        run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','Metal',root/'tests/test_custom_shader_metal.mm','-o',binary]);run([binary],skip=True)
    else:
        print('Not macOS: Metal shader/pixel validation SKIPPED.')
        skipped.append('everything that needs macOS: Metal, AVFoundation, the real engine')
# 0.10.1 was validated with the movie fixtures skipped, and its test-movie generator,
# broken in that release, went unnoticed. A run that skipped anything says so last.
if skipped:
    print('Regression checks passed, but this run did not check:\n  ' + '\n  '.join(skipped) +
          '\nIt is not a release validation. Run make test on a Mac with a GPU and nothing skipped.')
else:
    print('All regression checks passed; nothing was skipped.')
