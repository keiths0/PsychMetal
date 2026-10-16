# PsychMetal 0.10.0 release payload

RELEASE-MANIFEST.txt is the exact payload; SHA256SUMS covers every entry except
itself. tests/make_release_manifest.py selects tracked/untracked nonignored
files plus this version's two local iOS wheels, and applies RELEASE-EXCLUDES.txt.
The experimental probes and alternate Makefile remain local. Generated Xcode
projects, caches, logs, object files and dist are excluded. No previous version
folder is modified. tests/package_release.py verifies checksums before staging.

The ZIP contains engine/front ends, Mac native modules, source, demos, tests,
documentation, required phone artwork/sample movie and both iOS wheels. The
Python Mac wheel and source archive are separate assets. Do not commit the
entire working folder or force-add generated phone builds. Use the reviewed
manifest to select files; iOS wheels can remain release-only assets.

See RELEASE-0.10.0.md and VALIDATION.md for acceptance and explicit limits.
