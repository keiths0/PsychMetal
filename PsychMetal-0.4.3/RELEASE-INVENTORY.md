# Release inventory: 0.4.3

The renamed ready folder was inventoried before cleanup. The tested wrapper, native source, headers, shaders and both MEX binaries are unchanged. The 0.4.1 and 0.4.2 changelog history is retained.

Included: source, generated shader header, Octave and MATLAB ARM64 binaries, MIT license, build instructions, final release notes, validation record, supported demos and diagnostics, repeated-open and motion tests, regression tests, and optional Psychtoolbox comparisons.

Archived outside the release: four candidate instruction documents, packing benchmark output/source, and the two experimental startup/timing-policy comparison programs. Historical measurement files, standalone k-space programs/images, publisher credentials, build intermediates and Git metadata are not release payload.

README, changelog, keyboard notes and validation notes were consolidated for the final release. Packaging now verifies a manifest and checksums and does not rebuild the tested binaries. RELEASE-MANIFEST.txt defines every payload file; SHA256SUMS covers every manifest entry except itself.
