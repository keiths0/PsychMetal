function report = PsychMetalInventoryTest(verbose)
% PsychMetalInventoryTest  Exercise every command PsychMetal exposes.
%
%   report = PsychMetalInventoryTest        % run everything
%   report = PsychMetalInventoryTest(true)  % print each check as it passes
%
% Coverage, not timing. The timing tests measure how well things work;
% this one establishes that they work at all, that every documented command
% accepts what its help says it accepts, and that the ones which are supposed
% to reject bad input actually do.
%
% It is deliberately blunt about the last part. Several defects in 0.3.1 were
% arguments quietly accepted in the wrong slot or in the wrong units, which no
% amount of timing measurement would have caught: a colour passed in the range
% 0-255 to a command expecting 0-1, a drawable count landing in the
% waitForConfirm position, a texture handle used after CloseTexture. Every
% command therefore gets at least one deliberate misuse, and a command that
% fails to complain is a failure here.
%
% THE COMMAND LIST IS DERIVED FROM THE SOURCE, not written out by hand. If a
% command is added to PsychMetal.m and not covered here, the final check fails
% and names it. That is the point: an inventory test that can silently fall
% behind the inventory is worse than none.
%
% Roughly 25 seconds. Every check is independent; a failure is recorded and the
% run continues, so one broken command does not hide the state of the rest.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(verbose), verbose = false; end

w = []; tex = [];
results = struct('name', {}, 'ok', {}, 'detail', {});

  function record(name, ok, detail)
   results(end+1) = struct('name', name, 'ok', logical(ok), 'detail', detail);
   if verbose
    if ok, fprintf('  ok    %s\n', name);
    else,  fprintf('  FAIL  %s: %s\n', name, detail); end
   end
  end

  function check(name, fn)
   % A check that must run cleanly.
   try
    fn(); record(name, true, '');
   catch e
    record(name, false, e.message);
   end
  end

  function reject(name, fn)
   % A check that must RAISE. Silence here is the failure.
   try
    fn();
    record(name, false, 'accepted invalid input without error');
   catch
    record(name, true, '');
   end
  end

try
 fprintf('\nPsychMetal inventory test. About 25 seconds.\n\n');

 % ---- commands that work without a window --------------------------------
 check('Version returns a string', @() assert(ischar(PsychMetal('Version'))));
 check('bare call prints the command list', @() evalc('PsychMetal'));
 check('help topic prints', @() evalc('PsychMetal(''Flip?'')'));
 reject('unknown command is rejected', @() PsychMetal('NoSuchCommand'));
 reject('drawing before OpenWindow is rejected', @() PsychMetal('FillRect', 1));

 % ---- open ---------------------------------------------------------------
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen);
 PsychMetal('HideCursor');
 record('OpenWindow', true, '');
 check('rect is a sane 4-vector', @() assert(numel(rect) == 4 && ...
     rect(3) > rect(1) && rect(4) > rect(2)));
 check('ifi is near a plausible refresh', @() assert(ifi > 0.004 && ifi < 0.05));
 reject('a second OpenWindow is rejected', @() PsychMetal('OpenWindow', screen));
 reject('a bad window handle is rejected', @() PsychMetal('FillRect', w + 999));
 % Extra arguments must be refused, not ignored. Four commands accepted them
 % silently until 0.3.1, which is how a value lands in a slot nobody reads.
 reject('MakeTexture with a spare argument rejected', ...
     @() PsychMetal('MakeTexture', w, rand(8,8), 99));
 reject('GetMouse with a spare argument rejected', @() PsychMetal('GetMouse', w, 99));
 reject('Version with an argument rejected', @() PsychMetal('Version', 99));

 % ---- the Screen queries a drop-in needs ---------------------------------
 % COLOURS OPEN AT 0-255, as Screen's do. This is the drop-in property that
 % matters most: at 0-1 a ported script's every colour would render at 1/255
 % brightness, silently, because 255 and 128 both clamp to white.
 % Checked BEFORE anything changes it. This test used to set the range to 1
 % immediately after OpenWindow and then assert it opened at 255, which is a
 % check that can never pass and says nothing when it fails.
 check('ColorRange opens at 255', @() assert(PsychMetal('ColorRange', w) == 255));
 check('ColorRange returns the previous value', @() assert( ...
     PsychMetal('ColorRange', w, 1) == 255 && PsychMetal('ColorRange', w, 255) == 1));
 reject('a zero ColorRange is rejected', @() PsychMetal('ColorRange', w, 0));
 check('Rect matches OpenWindow', @() assert(isequal(PsychMetal('Rect', w), rect)));
 check('WindowSize matches Rect', @() assertWindowSize(w, rect));
 check('GetFlipInterval is a plausible refresh', @() assertNearIfi( ...
     PsychMetal('GetFlipInterval', w), ifi));
 % The comparison against Psychtoolbox's GetSecs lived here and is gone: it was
 % the last thing in the suite that loaded a Psychtoolbox mex, and it printed
 % the licence banner to verify a relationship between two system clocks that
 % was measured once and cannot change. docs/05_results.md records the result.
 check('GetSecs returns a plausible clock time', @() assertNear( ...
     PsychMetal('GetSecs'), 'GetSecs'));
 check('GetSecs advances', @() assert( ...
     PsychMetal('GetSecs') < PsychMetal('WaitSecs', 0.002)));
 reject('GetSecs with an argument rejected', @() PsychMetal('GetSecs', w));
 % WaitSecs is measured, not just called. A wait that returns early is a missed
 % deadline and a wait that overshoots by a millisecond is a missed frame, and
 % neither shows up in a test that only checks the call succeeds.
 % Different tolerances on purpose. The absolute form is handed a deadline and
 % has only the kernel's timer slack to beat. The relative form reads the clock
 % INSIDE the wrapper, so its deadline is set one dispatch later than the caller
 % thinks: measured 250 us against the absolute form's 60. That is the reason
 % the help says to use 'UntilTime' in a stimulus loop, and asserting it here
 % keeps the claim honest rather than decorative.
 check('WaitSecs, UntilTime', @() assertWait(0.010, true, 200e-6));
 check('WaitSecs, relative', @() assertWait(0.010, false, 600e-6));
 reject('WaitSecs with no argument rejected', @() PsychMetal('WaitSecs'));
 reject('WaitSecs with an unknown string rejected', ...
     @() PsychMetal('WaitSecs', 'Whenever', 1));

 % Background colour: OpenWindow's second argument, changeable at any time.
 check('BackgroundColor, scalar grey', @() PsychMetal('BackgroundColor', w, 64));
 check('BackgroundColor, RGB', @() PsychMetal('BackgroundColor', w, [0 0 51]));
 check('BackgroundColor, RGBA', @() PsychMetal('BackgroundColor', w, [0 0 0 255]));
 reject('BackgroundColor with a 2-vector rejected', ...
     @() PsychMetal('BackgroundColor', w, [128 128]));
 reject('BackgroundColor without a window rejected', ...
     @() PsychMetal('BackgroundColor', 128));
 PsychMetal('BackgroundColor', w, 0);

 % OpenGL is gone entirely in 0.4.0, so the command that used to switch interop
 % must no longer exist. A silently accepted UseOpenGL would mean a caller
 % believed they had turned something off that was never there.
 reject('UseOpenGL no longer exists', @() PsychMetal('UseOpenGL', w, false));

 % ---- the eight drawing primitives ---------------------------------------
 W = rect(3); H = rect(4);
 box = [W*0.3, H*0.3, W*0.7, H*0.7];
 check('FillRect, whole window',   @() PsychMetal('FillRect', w, 51));
 check('FillRect, explicit rect',  @() PsychMetal('FillRect', w, [255 0 0], box));
 check('FrameRect with pen width', @() PsychMetal('FrameRect', w, [0 255 0], box, 4));
 check('FillOval',                 @() PsychMetal('FillOval', w, [0 0 255], box));
 check('FrameOval with pen width', @() PsychMetal('FrameOval', w, [255 255 0], box, 6));
 check('DrawGabor, sigma only',    @() PsychMetal('DrawGabor', w, [255 255 255 128], box, 0.3));
 check('DrawGabor with frequency', @() PsychMetal('DrawGabor', w, 255, box, 0.3, 0.02));
 check('DrawGabor with orientation', ...
     @() PsychMetal('DrawGabor', w, 255, box, 0.3, 0.02, 45));
 check('DrawGabor with phase', ...
     @() PsychMetal('DrawGabor', w, 255, box, 0.3, 0.02, 45, 90));
 % The documented contract: frequency 0 is not an approximation of a Gaussian,
 % it is the same shape. Both forms must be accepted and neither may error.
 check('DrawGabor at frequency 0 is the Gaussian', @() ...
     PsychMetal('DrawGabor', w, [255 255 255 128], box, 0.3, 0));
 check('DrawNoise with no seed', @() PsychMetal('DrawNoise', w, box));
 check('DrawNoise, explicit seed', @() PsychMetal('DrawNoise', w, box, 1));
 check('DrawNoise, normal mono',   @() PsychMetal('DrawNoise', w, box, 2, 'normal'));
 check('DrawNoise, uniform colour', ...
     @() PsychMetal('DrawNoise', w, box, 3, 'uniform', 'colour'));
 check('DrawNoise with mean and spread', ...
     @() PsychMetal('DrawNoise', w, box, 4, 'normal', 'mono', 128, 26));
 % The seed is an output: without one, DrawNoise draws it and hands it back so
 % the frame can be reconstructed from four bytes rather than a 21 MB array.
 s1 = PsychMetal('DrawNoise', w, box);
 check('DrawNoise returns an integer seed', @() assert(isscalar(s1) && ...
     isfinite(s1) && s1 == fix(s1) && s1 >= 0 && s1 <= 16777215));
 check('an unseeded call returns a different seed next time', @() assert( ...
     PsychMetal('DrawNoise', w, box) ~= PsychMetal('DrawNoise', w, box) || ...
     PsychMetal('DrawNoise', w, box) ~= PsychMetal('DrawNoise', w, box)));
 check('an explicit seed is returned unchanged', ...
     @() assert(PsychMetal('DrawNoise', w, box, 12345) == 12345));
 [s2, nvals] = PsychMetal('DrawNoise', w, [0 0 16 8]);
 check('a second output returns the values', @() assert( ...
     isequal(size(nvals), [8 16]) && all(nvals(:) >= 0 & nvals(:) <= 255)));
 check('the returned values match the returned seed', @() assert(isequal( ...
     nvals, PsychMetal('NoiseValues', w, [0 0 16 8], s2))));
 check('DrawDots, 500 of them', @() PsychMetal('DrawDots', w, ...
     [W*0.5 + 100*randn(1,500); H*0.5 + 100*randn(1,500)], 4, 255));
 check('DrawLines, 10 segments', @() PsychMetal('DrawLines', w, ...
     [linspace(0,W,20); linspace(0,H,20)], 2, 128));
 check('4xN rect draws many at once', @() PsychMetal('FillRect', w, 77, ...
     [linspace(0,W*0.8,5); repmat(H*0.1,1,5); linspace(W*0.2,W,5); repmat(H*0.2,1,5)]));
 check('per-shape colours, 3xN', @() PsychMetal('FillOval', w, ...
     [255 0 0; 0 255 0; 0 0 255]', ...
     [0 0 100 100; 100 0 200 100; 200 0 300 100]'));
 check('alpha channel accepted', @() PsychMetal('FillRect', w, [255 0 0 128], box));
 PsychMetal('Flip', w);

 % Misuse. Colours are 0-1 here, NOT 0-255, and that has bitten before.
 % Colours out of range WARN and clamp rather than erroring, which is a
 % deliberate choice: clamping still shows something, and a hard error mid-trial
 % would be worse than a wrong shade. The requirement is that it complains, not
 % that it throws, so this checks for the warning.
 check('a colour above the range warns and clamps', @() assertWarns( ...
     @() PsychMetal('FillRect', w, [300 0 0], box), 'exceeds this window'));
 reject('rect with 3 elements rejected', @() PsychMetal('FillRect', w, [255 0 0], [1 2 3]));
 reject('negative pen width rejected', @() PsychMetal('FrameRect', w, 255, box, -2));
 reject('non-positive sigma rejected', @() PsychMetal('DrawGabor', w, 255, box, 0));
 reject('negative frequency rejected', ...
     @() PsychMetal('DrawGabor', w, 255, box, 0.3, -0.02));
 reject('non-scalar orientation rejected', ...
     @() PsychMetal('DrawGabor', w, 255, box, 0.3, 0.02, [0 45]));
 reject('1xN dot positions rejected', @() PsychMetal('DrawDots', w, 1:10, 4, 255));
 % A seed above 2^24 is not exactly representable in the float32 that carries it
 % to the shader, so it must be refused rather than silently drawn as a
 % different seed than the one the experiment recorded.
 reject('non-integer seed rejected', @() PsychMetal('DrawNoise', w, box, 1.5));
 reject('seed above 2^24 rejected', @() PsychMetal('DrawNoise', w, box, 16777216));
 reject('negative seed rejected', @() PsychMetal('DrawNoise', w, box, -1));
 reject('unknown distribution rejected', ...
     @() PsychMetal('DrawNoise', w, box, 1, 'poisson'));
 reject('unknown chroma rejected', ...
     @() PsychMetal('DrawNoise', w, box, 1, 'uniform', 'rgb-ish'));

 % ---- noise values recomputed on the CPU ---------------------------------
 nbox = [0 0 32 20];
 nv = PsychMetal('NoiseValues', w, nbox, 7);
 record('NoiseValues', true, '');
 check('NoiseValues is [h x w]', @() assert(isequal(size(nv), [20 32])));
 check('NoiseValues is on the ColorRange', @() assert(all(nv(:) >= 0 & nv(:) <= 255)));
 check('NoiseValues is reproducible from the seed', ...
     @() assert(isequal(nv, PsychMetal('NoiseValues', w, nbox, 7))));
 check('a different seed gives different values', ...
     @() assert(~isequal(nv, PsychMetal('NoiseValues', w, nbox, 8))));
 check('colour noise is [h x w x 3]', @() assert(isequal( ...
     size(PsychMetal('NoiseValues', w, nbox, 7, 'uniform', 'colour')), [20 32 3])));
 check('colour channels differ from each other', @() assertChannelsDiffer( ...
     PsychMetal('NoiseValues', w, nbox, 7, 'uniform', 'colour')));
 % THE DEFAULTS ARE THE TEST HERE, not the arguments: uniform, monochrome, full
 % spread, meaning every pixel independently between black and white. Defaulting
 % the mean to the window background instead would have given 0 to 0.5 on a
 % black background, which is half contrast and looks plausible.
 check('the default is uniform black to white', @() assertUniformish( ...
     PsychMetal('NoiseValues', w, [0 0 200 200], 11)));
 check('the default is monochrome', @() assert(ismatrix( ...
     PsychMetal('NoiseValues', w, [0 0 32 20], 11))));
 % A normal spread narrow enough not to clip should show its SD.
 check('normal noise has the requested SD', @() assertNormalSD( ...
     PsychMetal('NoiseValues', w, [0 0 200 200], 12, 'normal', 'mono', ...
     128, 26), 26));

 % ---- textures -----------------------------------------------------------
 img = rand(64, 64, 3);
 tex = PsychMetal('MakeTexture', w, img);
 record('MakeTexture, RGB', true, '');
 check('MakeTexture, RGBA', @() PsychMetal('CloseTexture', w, ...
     PsychMetal('MakeTexture', w, rand(32,32,4))));
 check('MakeTexture, luminance', @() PsychMetal('CloseTexture', w, ...
     PsychMetal('MakeTexture', w, rand(32,32))));
 check('DrawTexture, whole window', @() PsychMetal('DrawTexture', w, tex));
 check('DrawTexture with dst rect', @() PsychMetal('DrawTexture', w, tex, [], box));
 check('DrawTexture with rotation', @() PsychMetal('DrawTexture', w, tex, [], box, 45));
 % Screen's positions: filterMode 6, globalAlpha 7, modulateColor 8.
 check('DrawTexture, bilinear', @() PsychMetal('DrawTexture', w, tex, [], box, 0, 1));
 check('DrawTexture, nearest',  @() PsychMetal('DrawTexture', w, tex, [], box, 0, 0));
 check('DrawTexture with globalAlpha', ...
     @() PsychMetal('DrawTexture', w, tex, [], box, 0, 1, 128));
 check('DrawTexture with modulateColor', ...
     @() PsychMetal('DrawTexture', w, tex, [], box, 0, 1, [], [255 0 0 128]));
 check('globalAlpha above the range warns and clamps', @() assertWarns( ...
     @() PsychMetal('DrawTexture', w, tex, [], box, 0, 1, 999), 'globalAlpha'));
 % The tint sat at position 6 until 0.4.0, so a Screen call asking for nearest
 % filtering was read as a black tint and drew nothing. It must now be refused
 % rather than silently reinterpreted.
 reject('a colour in the filterMode slot is rejected', ...
     @() PsychMetal('DrawTexture', w, tex, [], box, 0, [255 0 0 128]));
 PsychMetal('Flip', w);
 reject('bad texture handle rejected', @() PsychMetal('DrawTexture', w, 9999));

 % ---- presentation -------------------------------------------------------
 % THE FIRST FLIP FROM A COLD WINDOW, deliberately. The refresh grid has no
 % anchor until a presentation is confirmed, and this is where Flip used to
 % return NaN. Keep it before any warm-up.
 vbl0 = PsychMetal('Flip', w);
 record('Flip, unscheduled', true, '');
 check('the very first Flip returns a finite time', ...
     @() assertNear(vbl0, 'first VBLTimestamp'));
 for k = 1:20
  PsychMetal('FillRect', w, 51);
  PsychMetal('Flip', w);
 end
 vbl = PsychMetal('Flip', w);
 check('Flip returns five values', @() assert(nargout_of(@() PsychMetal('Flip', w)) >= 1));
 [v2, onset, ft, missed, slipped] = PsychMetal('Flip', w);
 record('Flip five outputs unpack', true, '');
 check('VBLTimestamp is finite and near now', @() assertNear(v2, 'VBLTimestamp'));
 check('StimulusOnsetTime matches VBLTimestamp', @() assert(onset == v2, ...
     'onset %.6f differs from vbl %.6f', onset, v2));
 check('FlipTimestamp is a clock time', @() assertNear(ft, 'FlipTimestamp'));
 check('Missed is zero when unscheduled', @() assert(missed == 0));
 check('Slipped is finite', @() assert(isfinite(slipped)));

 vbl = PsychMetal('Flip', w);
 check('Flip with when, 3 refreshes ahead', ...
     @() PsychMetal('Flip', w, vbl + 2.5*ifi));
 vbl = PsychMetal('Flip', w);
 check('Flip with a past when presents anyway', ...
     @() PsychMetal('Flip', w, PsychMetal('GetSecs') - 0.05));
 reject('negative when is rejected', @() PsychMetal('Flip', w, -1));

 % ---- timing helpers -----------------------------------------------------
 check('NextRefresh returns a finite time near now', ...
     @() assertNear(PsychMetal('NextRefresh', w, PsychMetal('GetSecs')), 'NextRefresh'));
 check('NextPhase at phase 0.5 is finite', ...
     @() assertNear(PsychMetal('NextPhase', w, PsychMetal('GetSecs'), 0.5), 'NextPhase'));
 check('GridAnchor returns a struct or vector', @() assert( ...
     ~isempty(PsychMetal('GridAnchor', w))));
 check('WaitToDraw returns three values', @() assert(numel_of3( ...
     @() PsychMetal('WaitToDraw', w, PsychMetal('GetSecs') + 4*ifi, 0.004))));
 check('SetDisplaySync off then on', @() setSyncBoth(w));
 check('PrefetchDrawable off then on', @() prefetchBoth(w));

 % ---- diagnostics --------------------------------------------------------
 d = PsychMetal('Diagnostic', w);
 record('Diagnostic', true, '');
 for f = {'actualTimestamp','actualStatus','projectedTimestamp','committedTime', ...
          'measuredLeadMs','pipelineLeadMs','drawableWaitMs','summary'}
  check(sprintf('Diagnostic has %s', f{1}), @() assert(isfield(d, f{1})));
 end
 check('Diagnostic has one row per flip', @() assert( ...
     numel(d.actualStatus) == numel(d.flipNumber) && numel(d.actualStatus) >= 5));
 check('summary reports the drawable count', ...
     @() assert(d.summary.drawableCountReadback >= 2));
 % The display-link path went in 0.4.0, and with it every field derived from
 % CAMetalDisplayLink's target timestamps. They reported NaN in direct mode for
 % a release before that, which is a field that exists to say it means nothing.
 check('display-link summary fields are gone', @() assert( ...
     ~isfield(d.summary, 'calibratedTargetLagFrames') && ...
     ~isfield(d.summary, 'observedTargetOffsetFrames') && ...
     ~isfield(d.summary, 'displayLinkRestarts') && ...
     ~isfield(d.summary, 'presentMode')));
 check('the history has no display-link columns', @() assert( ...
     ~isfield(d, 'displayLinkTick') && ~isfield(d, 'rawAppleTargetTimestamp') && ...
     ~isfield(d, 'appleTargetTimestamp') && ~isfield(d, 'cadenceSlipRefreshes')));
 % The run tally and the clear colour were tracked but never surfaced before
 % 0.3.1. A slip count computed every flip and then discarded is the one number
 % an experiment most wants at the end of a run.
 check('summary reports the run tally', @() assert( ...
     isfield(d.summary, 'flips') && isfield(d.summary, 'slipFlips') && ...
     isfield(d.summary, 'lastSlipFlip') && ...
     d.summary.flips > 0 && d.summary.slipFlips >= 0));
 check('summary reports the background colour', @() assert( ...
     isfield(d.summary, 'backgroundColor') && ...
     numel(d.summary.backgroundColor) == 4));
 check('removed frame-latency fields are gone', @() assert( ...
     ~isfield(d.summary, 'requestedFrameLatency') && ...
     ~isfield(d.summary, 'frameLatencyReadback')));

 % ---- input --------------------------------------------------------------
 [mx, my, buttons] = PsychMetal('GetMouse', w);
 record('GetMouse', true, '');
 % Cursor control is PsychMetal's own now, not Screen('HideCursorHelper').
 check('ShowCursor', @() PsychMetal('ShowCursor'));
 check('HideCursor', @() PsychMetal('HideCursor'));
 reject('HideCursor with an argument rejected', @() PsychMetal('HideCursor', w));
 check('mouse is inside the window rect', @() assert( ...
     mx >= rect(1) - 1 && mx <= rect(3) + 1 && ...
     my >= rect(2) - 1 && my <= rect(4) + 1));
 check('buttons is a logical-ish vector', @() assert(~isempty(buttons)));

 % Keyboard. Nothing can be asserted about WHICH keys are down during an
 % unattended test, so what is checked is the shape of the answer and the
 % index convention, which is the part that can be silently wrong.
 [keyIsDown, kbSecs, keyCode] = PsychMetal('KbCheck');
 record('KbCheck', true, '');
 check('keyCode is 1x256 logical', @() assert( ...
     islogical(keyCode) && isequal(size(keyCode), [1 256])));
 check('keyIsDown agrees with keyCode', @() assert( ...
     logical(keyIsDown) == any(keyCode)));
 check('KbCheck time is on the PsychMetal clock', @() assert( ...
     abs(kbSecs - PsychMetal('GetSecs')) < 1.0));
 reject('KbCheck with a deviceNumber rejected', @() PsychMetal('KbCheck', 0));
 % The index convention is the whole point of the usage-code table: get it
 % wrong by one and every ported KbName constant reads the neighbouring key,
 % which looks like a working keyboard until somebody checks.
 check('KbName round-trips ESCAPE at 41', @() assert( ...
     PsychMetal('KbName', 'ESCAPE') == 41 && ...
     strcmp(PsychMetal('KbName', 41), 'ESCAPE')));
 check('KbName agrees with Psychtoolbox on space and the arrows', @() assert( ...
     PsychMetal('KbName', 'space') == 44 && ...
     PsychMetal('KbName', 'LeftArrow') == 80 && ...
     PsychMetal('KbName', 'UpArrow') == 82));
 check('KbName names a keyCode vector', @() assert(isequal( ...
     PsychMetal('KbName', sparseKey(44)), {'space'})));
 reject('KbName rejects an unknown name', @() PsychMetal('KbName', 'NoSuchKey'));
 record('KbName', true, '');
 % KbWait must return promptly when it is already satisfied. Waiting for a
 % PRESS cannot be tested unattended; waiting for release can, because no key
 % is down. The tolerance is loose deliberately: this asserts it returns, not
 % how fast, since the poll interval is the floor.
 t0 = PsychMetal('GetSecs');
 check('KbWait for release returns when no key is down', @() ...
     PsychMetal('KbWait', true));
 check('KbWait returned promptly', @() assert(PsychMetal('GetSecs') - t0 < 1.0));
 record('KbWait', true, '');

 % ---- two-phase presentation, measurement instruments --------------------
 PsychMetal('FillRect', w, 51);
 check('PrepareFlip', @() PsychMetal('PrepareFlip', w));
 check('PresentNow', @() PsychMetal('PresentNow', w));

 % ---- teardown -----------------------------------------------------------
 reject('CloseTexture with a spare argument rejected', ...
     @() PsychMetal('CloseTexture', w, tex, 99));
 check('CloseTexture', @() PsychMetal('CloseTexture', w, tex));
 tex = [];
 reject('a closed texture cannot be drawn', @() PsychMetal('DrawTexture', w, tex));

 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');
 record('Close', true, '');
 reject('drawing after Close is rejected', @() PsychMetal('FillRect', 1));

 % ---- did we cover the inventory? ---------------------------------------
 covered = lower({'Version','OpenWindow','BackgroundColor', ...
     'ColorRange','Rect','WindowSize','GetFlipInterval', ...
     'HideCursor','ShowCursor','GetSecs','WaitSecs','Resolution','Resolutions', ...
     'FillRect','FrameRect', ...
     'FillOval','FrameOval','DrawGabor','DrawNoise','NoiseValues', ...
     'DrawDots','DrawLines', ...
     'MakeTexture','DrawTexture','CloseTexture','Flip','NextRefresh', ...
     'NextPhase','GridAnchor','WaitToDraw','SetDisplaySync', ...
     'PrefetchDrawable','Diagnostic','GetMouse','KbCheck','KbWait','KbName', ...
     'PrepareFlip','PresentNow', ...
     'Close'});
 declared = commandsInSource();
 missing = setdiff(declared, covered);
 extra = setdiff(covered, declared);
 record('every command in PsychMetal.m is exercised', isempty(missing), ...
     sprintf('not covered: %s', strjoin(missing, ', ')));
 record('no test covers a command that no longer exists', isempty(extra), ...
     sprintf('stale: %s', strjoin(extra, ', ')));

 % ---- report -------------------------------------------------------------
 okAll = [results.ok];
 report = struct('checks', numel(results), 'passed', sum(okAll), ...
     'failed', sum(~okAll), 'results', results, ...
     'commandsDeclared', numel(declared));

 fprintf('\n===== inventory =====\n');
 fprintf('%d checks over %d commands: %d passed, %d failed.\n', ...
     numel(results), numel(declared), sum(okAll), sum(~okAll));
 if any(~okAll)
  fprintf('\nFailures:\n');
  for k = find(~okAll)
   fprintf('  %-48s %s\n', results(k).name, results(k).detail);
  end
  fprintf(['\nA failed rejection means a command accepted input it should have\n' ...
      'refused, which is how a wrong argument reaches the GPU silently.\n']);
 else
  fprintf('Every command ran, and every deliberate misuse was refused.\n');
 end

catch e
 try, if ~isempty(tex) && ~isempty(w), PsychMetal('CloseTexture', w, tex); end; catch, end
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

% -------------------------------------------------------------------------
function v = sparseKey(usage)
% A keyCode vector shaped like KbCheck's, with one key down.
v = false(1, 256);
v(usage) = true;
end

function out = commandsInSource()
% Read the dispatch switch out of PsychMetal.m rather than trusting a list
% written here, so a new command cannot be added without this test noticing.
src = fileread(which('PsychMetal'));
a = strfind(src, 'switch lower');
b = strfind(src, 'function printCommandHelp');
body = src(a(1):b(1));
tok = regexp(body, '\n\s*case\s+(\{[^}]*\}|''[a-z0-9]+'')', 'tokens');
out = {};
for k = 1:numel(tok)
 % A case may list several names: case {'fillrect','filloval',...}
 names = regexp(tok{k}{1}, '''([a-z0-9]+)''', 'tokens');
 for j = 1:numel(names)
  out{end+1} = names{j}{1}; %#ok<AGROW>
 end
end
% unique on the CELL. An earlier version did unique([out{:}]), which
% concatenates every name into one string and returns its unique characters,
% so the coverage check compared command names against the alphabet.
out = unique(out);
end

function assertChannelsDiffer(v)
% Colour noise must draw an independent value per channel. If the channel
% decorrelation in the hash were wrong the result would be grey noise, which
% looks plausible and is the wrong stimulus.
r = v(:,:,1); g = v(:,:,2); b = v(:,:,3);
if isequal(r,g) || isequal(g,b) || isequal(r,b)
 error('colour channels are identical, so the noise is monochrome');
end
end

function assertUniformish(v)
% Not a test of randomness quality, a test that the scaling is right: uniform
% on mean +/- spread should reach both ends and average near the middle. Values
% are on the window's ColorRange, so black to white is 0 to 255.
if min(v(:)) > 5 || max(v(:)) < 250
 error('range is %.1f to %.1f, expected to span nearly 0 to 255', ...
     min(v(:)), max(v(:)));
end
if abs(mean(v(:)) - 127.5) > 5
 error('mean is %.2f, expected near 127.5', mean(v(:)));
end
end

function assertNormalSD(v, want)
% Normal noise at a spread narrow enough not to clip should reproduce it as the
% standard deviation, in the window's ColorRange units.
got = std(v(:));
if abs(got - want) > 0.1 * want
 error('SD is %.2f, expected near %.2f', got, want);
end
if abs(mean(v(:)) - 127.5) > 3
 error('mean is %.2f, expected near 127.5', mean(v(:)));
end
end

function assertWait(secs, absolute, tol)
% Neither form may return EARLY, and neither may overshoot by more than its
% tolerance. The spin in the mex is what keeps the overshoot small; without it
% the kernel's timer slack put every wait 2.0 ms late, which is what this
% check caught the first time it ran.
n = 9; err = zeros(n,1);
for k = 1:n
 % Discard the first: the mex margin adapts on its first overrun.
 t0 = PsychMetal('GetSecs');
 if absolute
  t = PsychMetal('WaitSecs', 'UntilTime', t0 + secs);
 else
  t = PsychMetal('WaitSecs', secs);
 end
 err(k) = t - (t0 + secs);
end
err = err(2:end);
if any(err < -1e-6)
 error('returned %.1f us EARLY, before the deadline', min(err)*1e6);
end
% The first wait may pay for the adaptive margin finding its level, so judge on
% the median rather than the worst. 200 us is what a spin should deliver once
% the margin exceeds the kernel's timer slack; the first attempt used a 500 us
% margin against 2.0 ms of slack and overshot by 2.0 ms every time.
if median(err) > tol
 error('median overshoot %.1f us (worst %.1f), tolerance %.0f us', ...
     median(err)*1e6, max(err)*1e6, tol*1e6);
end
end

function assertWindowSize(w, rect)
[ww, hh] = PsychMetal('WindowSize', w);
if ww ~= rect(3) - rect(1) || hh ~= rect(4) - rect(2)
 error('WindowSize gave %gx%g, Rect implies %gx%g', ...
     ww, hh, rect(3)-rect(1), rect(4)-rect(2));
end
end

function assertNearIfi(got, nominal)
% Measured or nominal, it must be a real refresh interval. The measured value
% is a least-squares fit and will differ from nominal in the last few digits;
% anything beyond a percent means the wrong quantity came back.
if ~isfinite(got) || got <= 0.004 || got >= 0.05
 error('GetFlipInterval returned %g, not a plausible refresh interval', got);
end
if abs(got - nominal) / nominal > 0.01
 error('GetFlipInterval %g differs from OpenWindow''s %g by more than 1%%', ...
     got, nominal);
end
end

function assertNear(t, name)
% Finite, and within a second of now. Reports the value, because a bare
% "assert failed" on a NaN is not enough to act on.
if ~isfinite(t)
 error('%s is %g, not a finite timestamp', name, t);
end
now_ = PsychMetal('GetSecs');
if abs(t - now_) > 1
 error('%s is %.6f, which is %.3f s from now', name, t, t - now_);
end
end

function assertWarns(fn, fragment)
% The call must emit a warning containing `fragment`. The warning is EXPECTED,
% so its display is suppressed: a test log full of stack traces from warnings
% the test asked for makes the one unexpected warning impossible to spot.
old = warning('off', 'PsychMetal:ColorRange');
restore = onCleanup(@() warning(old));
lastwarn('');
fn();
[msg, ~] = lastwarn();
if isempty(msg)
 error('no warning was emitted');
end
if isempty(strfind(lower(msg), lower(fragment)))
 error('warning did not mention "%s": %s', fragment, msg);
end
end

function n = nargout_of(fn)
v = fn(); n = numel(v);
end

function tf = numel_of3(fn)
[a, b, c] = fn();
tf = isfinite(a) && isfinite(b) && isfinite(c);
end

function setSyncBoth(w)
PsychMetal('SetDisplaySync', w, false);
PsychMetal('SetDisplaySync', w, true);
end

function prefetchBoth(w)
PsychMetal('PrefetchDrawable', w, false);
PsychMetal('PrefetchDrawable', w, true);
end
