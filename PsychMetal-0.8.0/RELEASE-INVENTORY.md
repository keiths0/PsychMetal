# 0.8.0 unpublished development package

RELEASE-MANIFEST.txt lists the exact candidate payload; SHA256SUMS covers every
listed file except itself. `tests/package_release.py` validates and stages it.
The development ZIP contains shared engine/front ends, Mac binaries, source,
demos, tests, documentation, phone sources/resources/store tools, and fresh device
and simulator wheels. The Python Mac wheel and source archive are separate assets
in dist/. Generated Xcode projects, app products, caches, logs and build
intermediates are excluded. No prior release folders are modified by staging.

This is prepared for hardware acceptance, not an official published release.
See VALIDATION.md and phone/READY-TO-TEST.md. No GitHub/Apple upload was performed.
