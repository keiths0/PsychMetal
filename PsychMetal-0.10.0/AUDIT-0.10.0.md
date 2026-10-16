# 0.10.0 efficiency and repository audit — 2026-10-15

This pass reviewed native draw/resource bookkeeping, texture packing and cleanup,
queued-frame reporting, movie metadata/prefetch/audio caching, audio event ownership,
recording/export bookkeeping, and repository/package exclusions. It is a targeted
source audit, not proof of optimality or a physical performance benchmark.

## Fixed

- Close now releases the float32 packing scratch buffer, matching the existing
  half-float and byte scratch cleanup. Previously a large packed float upload
  could leave its CPU allocation resident after closing the window.
- Draw encoding counts custom shaders during its existing resource scan rather
  than scanning the list again; shader retention reserves only the actual count.
  Completion ownership remains intact for textures, masks and custom shaders.
- Repeated movie-frame draws and fully preloaded frame draws no longer submit
  redundant asynchronous prefetch jobs. Serial synchronization and exact frame
  identity remain; seeks and advancing buffered playback still fill lookahead.
- Movie timing metadata selects its median in the existing gap vector, eliminating
  a second full copy; space for the gap vector is reserved once.
- QueueResults compacts unfinished tokens in its existing buffer, avoiding a
  replacement vector and repeated buffer growth. Pending/late outcomes keep
  their previous semantics.
- A clamped contiguous float upload stops its preliminary direct-buffer scan at
  the first value that requires packing. The packing path still validates every
  pixel, including nonfinite values after that first clamped pixel.

## Repository size versus shipped size

The local tree measured about 359 MiB before the rebuild: about 197 MiB was
phone/build and 21 MiB was the native build directory. Generated projects,
caches, wheels, logs, object files and dist are already ignored; none of those
paths had tracked files in this version folder. Generated phone wheels remain
usable locally and can be explicit release assets without committing app builds.

Makefile.new is an older untracked alternate recipe; it is now explicitly
ignored and preserved locally. Existing experimental probes were preserved and
are outside this pass. Do not stage them incidentally.

Keep source, tests, build tools, relevant documentation, required demo assets,
and intentional ready-to-run native binaries. The bundled phone movie is a
required demo asset, not a generated recording. Do not delete UI icons simply
because multiple resolutions exist: the app build uses them.

At audit time the inherited release manifest/checksums described 0.9.0.
Release preparation regenerated them for the selected 0.10.0 payload on
October 15. Copying or committing the entire working folder is not the release
procedure; RELEASE-EXCLUDES.txt preserves local-only experiments outside it.

## Remaining profiling candidates and limitations

- Playing a short movie excerpt currently decodes the soundtrack before cropping
  it. A native range-decoding API could reduce startup work and peak memory,
  but must preserve resampling and pitch-stretch boundary behavior.
- Custom shader creation compiles the built-in source with the custom wrapper
  and creates target/blend pipelines up front. A reduced shared shader prelude
  or lazy pipelines may reduce setup work; neither is in the per-frame path.
- Movie and recorder paths flush the Core Video texture cache per decoded/written
  frame. Changing that policy requires measuring memory and frame cost with real
  decoder/pixel-buffer pools, not assuming the flush is unnecessary.
- Recording late/unreported statistics consult bounded presentation history at
  stop. Older overwritten records count as unreported, and token collection is
  capped at one million. This is not a complete long-recording timing ledger.
- Offline audio retains its bounded command/sound history until export ends.
  Streaming reclamation could reduce memory for long exports, but must keep
  queued/active mixer sounds alive; removing ownership blindly is unsafe.
- Mac activation retains a documented deprecated API for reliable CLI activation;
  shader compile options retain an older-SDK fallback. These are deliberate
  compatibility paths, not unused alternative rendering engines.

## Verification

Mac Octave, MATLAB and Python 3.15 modules rebuilt successfully. The full available
regression runner passed with --skip-media-fixtures. Real macOS, iPhone and
simulator SDK type checks passed. Focused tests verify no redundant prefetch jobs,
custom-shader completion ownership, queue report semantics, and rejection of a
nonfinite float pixel after a clamped prefix. Sanitizer fixtures passed.

GPU pixel checks explicitly skipped because execution has no Metal device.
Real movie encoding/decoding fixtures were explicitly omitted; no hardware
speedup, display reliability, or codec fidelity claim follows from this pass.
Both phone wheels and the generic device app build were refreshed successfully;
bundle/privacy preflight passed. The regenerated pip source archive contains
49 files (248,877 bytes), with no generated projects or native build binaries.
No commit, push, release, or App Store upload was performed.
