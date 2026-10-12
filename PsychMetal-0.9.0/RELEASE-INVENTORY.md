# PsychMetal 0.9.0 release payload

RELEASE-MANIFEST.txt lists the exact release payload; SHA256SUMS covers every
listed file except itself. `tests/make_release_manifest.py` writes both from
the files git would commit here plus this version's two phone wheels, and
refuses a binary older than its sources; `tests/package_release.py` validates
and stages the payload.
The release ZIP contains shared engine/front ends, Mac binaries, source,
demos, tests, documentation, phone sources/resources/store tools, and fresh device
and simulator wheels. The Python Mac wheel and source archive are separate assets
in dist/. Generated Xcode projects, app products, caches, logs and build
intermediates are excluded. No prior release folders are modified by staging.

See VALIDATION.md for completed checks and explicit GPU/device limitations.
The GitHub package is not a signed App Store archive. See phone/READY-TO-TEST.md.
