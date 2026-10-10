"""Exercise App Store preparation and the real package-copy filter without Xcode."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

phone = Path(__file__).resolve().parents[1] / 'phone'
with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp) / 'phone'
    store = base / 'store'
    store.mkdir(parents=True)
    for name in ('prepare_xcode.py', 'PrivacyInfo.xcprivacy', 'OpenSSL.xcprivacy'):
        shutil.copy2(phone / 'store' / name, store / name)
    shutil.copy2(phone / 'pyproject.toml', base / 'pyproject.toml')
    root = base / 'build/psychmetaldemos/ios/xcode'
    project = root / 'PsychMetal Demos.xcodeproj/project.pbxproj'
    project.parent.mkdir(parents=True)
    app = root / 'PsychMetalDemos'
    app.mkdir()
    import plistlib
    info = app / 'PsychMetalDemos-Info.plist'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.github.keiths0.psychmetaldemos'}))
    project.write_text('''/* Begin PBXFileReference section */
/* Begin PBXBuildFile section */
                610000000000000000100500 /* PsychMetalDemos-Info.plist */,
                60A04BC728B35FD000DAA9E5 /* app in Resources */,
rsync -au --delete source/ destination
'''.replace('                ', '\t\t\t\t'))
    utils = root / 'Support/Python.xcframework/build/utils.sh'
    utils.parent.mkdir(parents=True)
    # Exercise the support-package helper, including its signing boundary.
    utils.write_text('#!/bin/bash\n    echo "Signing framework as $EXPANDED_CODE_SIGN_IDENTITY_NAME ($EXPANDED_CODE_SIGN_IDENTITY)..."\n')
    # Real support-module layout, including both simulator architecture slices.
    module_dirs=[]
    for platform in ('ios-arm64/lib-arm64', 'ios-arm64_x86_64-simulator/lib-arm64', 'ios-arm64_x86_64-simulator/lib-x86_64'):
        directory=root/'Support/Python.xcframework'/platform/'python3.14/lib-dynload'
        directory.mkdir(parents=True)
        module_dirs.append(directory)
        for module in ('_ssl', '_hashlib'):
            (directory/(module+'.cpython-314.so')).write_bytes(b'native module')
    utils.write_text(utils.read_text()+'\n# upstream relocation: $MODULE_PATH/$MODULE_NAME.xcprivacy\n')
    python_info=root/'Support/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Info.plist'
    python_info.parent.mkdir(parents=True)
    python_info.write_bytes(plistlib.dumps({'MinimumOSVersion':'13.0','CFBundlePackageType':'FMWK'}))
    def prepare():
        subprocess.run([sys.executable, str(store / 'prepare_xcode.py')], check=True,
                       stdout=subprocess.PIPE, text=True)
    prepare()
    assert plistlib.loads(python_info.read_bytes())['MinimumOSVersion']=='17.0'
    expected_privacy=plistlib.loads((store/'OpenSSL.xcprivacy').read_bytes())
    for directory in module_dirs:
        for module in ('_ssl', '_hashlib'):
            assert plistlib.loads((directory/(module+'.xcprivacy')).read_bytes())==expected_privacy
    # A newer upstream manifest must not be overwritten by the fallback.
    newer=module_dirs[0]/'_ssl.xcprivacy'
    newer.write_bytes(plistlib.dumps(dict(expected_privacy, NSPrivacyTrackingDomains=['vendor-test.invalid'])))
    newer_bytes=newer.read_bytes()
    first = project.read_bytes()
    first_utils = utils.read_bytes()
    prepare()
    assert newer.read_bytes()==newer_bytes
    assert project.read_bytes() == first, 'preparation must be idempotent'
    assert utils.read_bytes() == first_utils
    helper = utils.read_text()
    assert helper.index('plutil -replace MinimumOSVersion') < helper.index('    echo "Signing framework')
    assert 'CFBundlePackageType -string FMWK' in helper
    assert plistlib.loads(info.read_bytes())['CFBundleVersion'] == '1'
    # Check the actual injected commands against an existing (stale) plist.
    framework = base / 'App.app/Frameworks/example.framework'
    framework.mkdir(parents=True)
    plist = framework / 'Info.plist'
    plist.write_bytes(plistlib.dumps({'MinimumOSVersion': '13.0', 'CFBundlePackageType': 'APPL'}))
    import os
    env = dict(os.environ, IPHONEOS_DEPLOYMENT_TARGET='17.0',
               CODESIGNING_FOLDER_PATH=str(base / 'App.app'),
               FRAMEWORK_FOLDER='Frameworks/example.framework')
    commands = '\n'.join(line for line in helper.splitlines() if line.strip().startswith(
        ('plutil -replace MinimumOSVersion', 'plutil -replace CFBundlePackageType')))
    if shutil.which('plutil'):      # a Mac's tool: elsewhere the commands are only checked as text
        subprocess.run(['/bin/bash', '-ec', commands], env=env, check=True)
        metadata = plistlib.loads(plist.read_bytes())
        assert metadata['MinimumOSVersion'] == '17.0' and metadata['CFBundlePackageType'] == 'FMWK'
        env.pop('IPHONEOS_DEPLOYMENT_TARGET')
        assert subprocess.run(['/bin/bash', '-ec', commands], env=env, capture_output=True).returncode != 0
    else:
        print('No plutil (not a Mac): running the injected plist commands SKIPPED.')

    assert (app / 'PrivacyInfo.xcprivacy').read_bytes() == (store / 'PrivacyInfo.xcprivacy').read_bytes()
    assert plistlib.loads(info.read_bytes())['CADisableMinimumFrameDurationOnPhone'] is True
    command = next(line for line in project.read_text().splitlines() if line.startswith('rsync '))
    if not shutil.which('rsync'):
        print('No rsync: running the package copy SKIPPED.')
    else:
        import shlex
        flags = shlex.split(command)[:-2]
        source = base / 'packages'
        dest = base / 'app_packages'
        for folder in (source, dest):
            (folder / 'numpy/random/lib').mkdir(parents=True)
            (folder / 'numpy/random/lib/libnpyrandom.a').write_bytes(b'!<arch>\n')
            (folder / 'numpy/random/_generator.so').write_bytes(b'runtime extension')
        (source / 'numpy/__init__.py').write_text('# runtime module\n')
        subprocess.run(flags + [str(source) + '/', str(dest)], check=True)
        assert not list(dest.rglob('*.a')), 'remove new and stale static libraries'
        assert list(source.rglob('*.a')), 'keep original build dependencies intact'
        assert (dest / 'numpy/random/_generator.so').read_bytes() == b'runtime extension'
        assert (dest / 'numpy/__init__.py').is_file()
print('PASS: preparation is idempotent; package copy excludes static archives, cleans stale copies, and retains runtime files.')
