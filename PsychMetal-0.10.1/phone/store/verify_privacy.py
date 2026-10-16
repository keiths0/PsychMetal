#!/usr/bin/env python3
"""Verify the two OpenSSL framework manifests in a built app or Xcode archive."""
from pathlib import Path
import plistlib, subprocess, sys
p=Path(sys.argv[1]).expanduser().resolve()
apps=list((p/'Products/Applications').glob('*.app')) if p.suffix=='.xcarchive' else [p]
if len(apps)!=1: raise SystemExit('Expected one app in the archive.')
app=apps[0]
info=plistlib.loads((app/'Info.plist').read_bytes())
for module in ('_ssl','_hashlib'):
 framework=app/'Frameworks'/(module+'.framework')
 manifest=framework/'PrivacyInfo.xcprivacy'
 if not manifest.is_file(): raise SystemExit('Missing: '+str(manifest))
 data=plistlib.loads(manifest.read_bytes())
 if not isinstance(data.get('NSPrivacyTracking'),bool): raise SystemExit('Invalid tracking declaration: '+str(manifest))
 for key in ('NSPrivacyCollectedDataTypes','NSPrivacyAccessedAPITypes','NSPrivacyTrackingDomains'):
  if not isinstance(data.get(key),list):raise SystemExit('Missing/invalid '+key+': '+str(manifest))
 subprocess.run(['codesign','--verify','--strict',str(framework)],check=True)
 print('PASS:',module,'manifest embedded and signature valid.')
print('App:',info['CFBundleShortVersionString'],'build',info['CFBundleVersion'])
