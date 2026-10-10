# PsychMetal 0.8.0 worklist — October 9, 2026

Release scope includes the 0.7.2 optimization work. The 0.7.1 App Store
submission remains independent; GitHub publication does not upload a phone app.

| Work item | Implemented | Remaining acceptance |
|---|---|---|
| Environment report | Shared native metadata, all Mac bindings, strict JSON, phone collection outside trials | Compare reports across physical devices |
| Native stimulus timeline | Captured scene, periodic frame-counted tracks, linear keyframes, Python live parameter updates, cancellation, demos | Physical timing, touch/lifecycle transitions |
| Reusable GPU masks | Gaussian, ellipse, annulus, raised cosine, optional image coverage | GPU pixel fixtures and cross-device visuals |
| Masked still images | Shared sampler, crop/rotation/filter/alpha, retained versions, draggable demos | User accepted Mac Octave visuals/drag; remaining GPU and device matrix |
| Custom Metal shaders | Fixed fragment contract, upfront pipeline compilation/cache, target/blend/clip/mask integration, shared spiral demo | Actual MSL compilation and GPU pixels on accessible hardware |
| Phone reports | Local persistence, matching environment snapshots, iPhone/iPad Share sheet, cancellation and reopening | Actual UIKit sharing, iPad popover and background/resume |
| Phone UI cleanup | Idle main-thread cyclic GC policy, safe exit while worker closes | Main Thread Checker across repeated transitions; cause/fix not yet proven on device |
| Video and audio | Explicitly deferred at user request | Future releases |

MATLAB/Octave expose blocking playback/keyframes; live updates and explicit
cancellation calls are Python/native APIs. MATLAB/Octave use Escape to stop.

See TIMELINE.md, GPU-MASKS.md, MASKED-IMAGES.md, CUSTOM-SHADERS.md and VALIDATION.md.
All new APIs have boundary/lifetime tests. Scripted presentation validates host
contracts, not GPU-generated pixels. Native sanitizer tests exercise the actual
playback implementation and concurrent control, not physical presentation.

Timeline samples advance once per submission; missed physical presentations are
reported rather than silently repaired. Live changes override periodic/keyframe
values until playback ends. Host callbacks, automatic timeline dragging and custom
shader parameter tracks are not part of this implementation. Live controllers
can use a second Python thread; MATLAB/Octave cannot run ordinary code while a
blocking MEX call owns their execution thread.

Hardware acceptance matrix: MATLAB/Octave/Python on the same Mac; fixed 60 Hz and
high-refresh screens; native-pixel/HiDPI and multiple monitor selection; iPhone
60 Hz/ProMotion and iPad; portrait/landscape, touch, background/resume and report
reopening/sharing. Run phone timing from Home Screen with Xcode disconnected.
Run Main Thread Checker separately for UIKit lifecycle checks. GPU/software
records do not replace photodiode validation of emitted light.
