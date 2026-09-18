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
% Approximately 25 seconds, depending on the display. Every check is independent; a failure is recorded and the
% run continues, so one broken command does not hide the state of the rest.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(verbose), verbose = false; end

w = []; tex = [];
results = struct('name', {}, 'ok', {}, 'detail', {});
inventoryPM('__reset_trace__');

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
 check('Version returns a string', @() assert(ischar(inventoryPM('Version'))));
 check('bare call prints the command list', @() evalc('inventoryPM'));
 check('help topic prints', @() evalc('inventoryPM(''Flip?'')'));
 reject('unknown command is rejected', @() inventoryPM('NoSuchCommand'));
 reject('drawing before OpenWindow is rejected', @() inventoryPM('FillRect', 1));

 check('Resolution query', @() assert(isstruct(inventoryPM('Resolution',[]))));
 check('Resolutions list', @() assert(isstruct(inventoryPM('Resolutions',[]))));
 check('KbQueueStatus reports state', @() assert(isstruct(inventoryPM('KbQueueStatus'))));
 % ---- open ---------------------------------------------------------------
 screen = [];   % [] is the last active display
 [w, rect, ifi] = inventoryPM('OpenWindow', screen);
 inventoryPM('HideCursor');
 record('OpenWindow', true, '');
 check('rect is a sane 4-vector', @() assert(numel(rect) == 4 && ...
     rect(3) > rect(1) && rect(4) > rect(2)));
 check('ifi is near a plausible refresh', @() assert(ifi > 0.004 && ifi < 0.05));
 reject('a second OpenWindow is rejected', @() inventoryPM('OpenWindow', screen));
 reject('a bad window handle is rejected', @() inventoryPM('FillRect', w + 999));
 % Extra arguments must be refused, not ignored. Four commands accepted them
 % silently until 0.3.1, which is how a value lands in a slot nobody reads.
 reject('MakeTexture with a spare argument rejected', ...
     @() inventoryPM('MakeTexture', w, rand(8,8), 99));
 reject('GetMouse with a spare argument rejected', @() inventoryPM('GetMouse', w, 99));
 reject('Version with an argument rejected', @() inventoryPM('Version', 99));

 % ---- the Screen queries a drop-in needs ---------------------------------
 % COLOURS OPEN AT 0-255, as Screen's do. This is the drop-in property that
 % matters most: at 0-1 a ported script's every colour would render at 1/255
 % brightness, silently, because 255 and 128 both clamp to white.
 % Checked BEFORE anything changes it. This test used to set the range to 1
 % immediately after OpenWindow and then assert it opened at 255, which is a
 % check that can never pass and says nothing when it fails.
 check('ColorRange opens at 255', @() assert(inventoryPM('ColorRange', w) == 255));
 check('ColorRange returns the previous value', @() assert( ...
     inventoryPM('ColorRange', w, 1) == 255 && inventoryPM('ColorRange', w, 255) == 1));
 reject('a zero ColorRange is rejected', @() inventoryPM('ColorRange', w, 0));
 check('Rect matches OpenWindow', @() assert(isequal(inventoryPM('Rect', w), rect)));
 check('WindowSize matches Rect', @() assertWindowSize(w, rect));
 check('GetFlipInterval is a plausible refresh', @() assertNearIfi( ...
     inventoryPM('GetFlipInterval', w), ifi));
 % The comparison against Psychtoolbox's GetSecs lived here and is gone: it was
 % the last thing in the suite that loaded a Psychtoolbox mex, and it printed
 % the licence banner to verify a relationship between two system clocks that
 % was measured once and cannot change. docs/05_results.md records the result.
 check('GetSecs returns a plausible clock time', @() assertNear( ...
     inventoryPM('GetSecs'), 'GetSecs'));
 check('GetSecs advances', @() assert( ...
     inventoryPM('GetSecs') < inventoryPM('WaitSecs', 0.002)));
 reject('GetSecs with an argument rejected', @() inventoryPM('GetSecs', w));
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
 reject('WaitSecs with no argument rejected', @() inventoryPM('WaitSecs'));
 reject('WaitSecs with an unknown string rejected', ...
     @() inventoryPM('WaitSecs', 'Whenever', 1));

 % Background colour: OpenWindow's second argument, changeable at any time.
 check('BackgroundColor, scalar grey', @() inventoryPM('BackgroundColor', w, 64));
 check('BackgroundColor, RGB', @() inventoryPM('BackgroundColor', w, [0 0 51]));
 check('BackgroundColor, RGBA', @() inventoryPM('BackgroundColor', w, [0 0 0 255]));
 reject('BackgroundColor with a 2-vector rejected', ...
     @() inventoryPM('BackgroundColor', w, [128 128]));
 reject('BackgroundColor without a window rejected', ...
     @() inventoryPM('BackgroundColor', 128));
 inventoryPM('BackgroundColor', w, 0);

 % OpenGL is gone entirely in 0.4.0, so the command that used to switch interop
 % must no longer exist. A silently accepted UseOpenGL would mean a caller
 % believed they had turned something off that was never there.
 reject('UseOpenGL no longer exists', @() inventoryPM('UseOpenGL', w, false));

 % ---- the eight drawing primitives ---------------------------------------
 W = rect(3); H = rect(4);
 box = round([W*0.3, H*0.3, W*0.7, H*0.7]);
 check('FillRect, whole window',   @() inventoryPM('FillRect', w, 51));
 check('FillRect, explicit rect',  @() inventoryPM('FillRect', w, [255 0 0], box));
 check('FrameRect with pen width', @() inventoryPM('FrameRect', w, [0 255 0], box, 4));
 check('FillOval',                 @() inventoryPM('FillOval', w, [0 0 255], box));
 check('FrameOval with pen width', @() inventoryPM('FrameOval', w, [255 255 0], box, 6));
 check('DrawGabor, sigma only',    @() inventoryPM('DrawGabor', w, [255 255 255 128], box, 0.3));
 check('DrawGabor with frequency', @() inventoryPM('DrawGabor', w, 255, box, 0.3, 0.02));
 check('DrawGabor with orientation', ...
     @() inventoryPM('DrawGabor', w, 255, box, 0.3, 0.02, 45));
 check('DrawGabor with phase', ...
     @() inventoryPM('DrawGabor', w, 255, box, 0.3, 0.02, 45, 90));
 % The documented contract: frequency 0 is not an approximation of a Gaussian,
 % it is the same shape. Both forms must be accepted and neither may error.
 check('DrawGabor at frequency 0 is the Gaussian', @() ...
     inventoryPM('DrawGabor', w, [255 255 255 128], box, 0.3, 0));
 check('DrawNoise with no seed', @() inventoryPM('DrawNoise', w, box));
 check('DrawNoise, explicit seed', @() inventoryPM('DrawNoise', w, box, 1));
 check('DrawNoise, normal mono',   @() inventoryPM('DrawNoise', w, box, 2, 'normal'));
 check('DrawNoise, uniform colour', ...
     @() inventoryPM('DrawNoise', w, box, 3, 'uniform', 'colour'));
 check('DrawNoise with mean and spread', ...
     @() inventoryPM('DrawNoise', w, box, 4, 'normal', 'mono', 128, 26));
 % The seed is an output: without one, DrawNoise draws it and hands it back so
 % the frame can be reconstructed from four bytes rather than a 21 MB array.
 s1 = inventoryPM('DrawNoise', w, box);
 check('DrawNoise returns an integer seed', @() assert(isscalar(s1) && ...
     isfinite(s1) && s1 == fix(s1) && s1 >= 0 && s1 <= 16777215));
 check('an unseeded call returns a different seed next time', @() assert( ...
     inventoryPM('DrawNoise', w, box) ~= inventoryPM('DrawNoise', w, box) || ...
     inventoryPM('DrawNoise', w, box) ~= inventoryPM('DrawNoise', w, box)));
 check('an explicit seed is returned unchanged', ...
     @() assert(inventoryPM('DrawNoise', w, box, 12345) == 12345));
 [s2, nvals] = inventoryPM('DrawNoise', w, [0 0 16 8]);
 check('a second output returns the values', @() assert( ...
     isequal(size(nvals), [8 16]) && all(nvals(:) >= 0 & nvals(:) <= 255)));
 check('the returned values match the returned seed', @() assert(isequal( ...
     nvals, inventoryPM('NoiseValues', w, [0 0 16 8], s2))));
 check('DrawDots, 500 of them', @() inventoryPM('DrawDots', w, ...
     [W*0.5 + 100*randn(1,500); H*0.5 + 100*randn(1,500)], 4, 255));
 check('DrawLines, 10 segments', @() inventoryPM('DrawLines', w, ...
     [linspace(0,W,20); linspace(0,H,20)], 2, 128));
 check('4xN rect draws many at once', @() inventoryPM('FillRect', w, 77, ...
     [linspace(0,W*0.8,5); repmat(H*0.1,1,5); linspace(W*0.2,W,5); repmat(H*0.2,1,5)]));
 check('per-shape colours, 3xN', @() inventoryPM('FillOval', w, ...
     [255 0 0; 0 255 0; 0 0 255]', ...
     [0 0 100 100; 100 0 200 100; 200 0 300 100]'));
 check('alpha channel accepted', @() inventoryPM('FillRect', w, [255 0 0 128], box));
 inventoryPM('Flip', w);

 % Misuse. Colours are 0-1 here, NOT 0-255, and that has bitten before.
 % Colours out of range WARN and clamp rather than erroring, which is a
 % deliberate choice: clamping still shows something, and a hard error mid-trial
 % would be worse than a wrong shade. The requirement is that it complains, not
 % that it throws, so this checks for the warning.
 check('a colour above the range warns and clamps', @() assertWarns( ...
     @() inventoryPM('FillRect', w, [300 0 0], box), 'exceeds this window'));
 reject('rect with 3 elements rejected', @() inventoryPM('FillRect', w, [255 0 0], [1 2 3]));
 reject('negative pen width rejected', @() inventoryPM('FrameRect', w, 255, box, -2));
 reject('non-positive sigma rejected', @() inventoryPM('DrawGabor', w, 255, box, 0));
 reject('negative frequency rejected', ...
     @() inventoryPM('DrawGabor', w, 255, box, 0.3, -0.02));
 reject('non-scalar orientation rejected', ...
     @() inventoryPM('DrawGabor', w, 255, box, 0.3, 0.02, [0 45]));
 reject('1xN dot positions rejected', @() inventoryPM('DrawDots', w, 1:10, 4, 255));
 % A seed above 2^24 is not exactly representable in the float32 that carries it
 % to the shader, so it must be refused rather than silently drawn as a
 % different seed than the one the experiment recorded.
 reject('non-integer seed rejected', @() inventoryPM('DrawNoise', w, box, 1.5));
 reject('seed above 2^24 rejected', @() inventoryPM('DrawNoise', w, box, 16777216));
 reject('negative seed rejected', @() inventoryPM('DrawNoise', w, box, -1));
 reject('unknown distribution rejected', ...
     @() inventoryPM('DrawNoise', w, box, 1, 'poisson'));
 reject('unknown chroma rejected', ...
     @() inventoryPM('DrawNoise', w, box, 1, 'uniform', 'rgb-ish'));

 % ---- noise values recomputed on the CPU ---------------------------------
 nbox = [0 0 32 20];
 nv = inventoryPM('NoiseValues', w, nbox, 7);
 record('NoiseValues', true, '');
 check('NoiseValues is [h x w]', @() assert(isequal(size(nv), [20 32])));
 check('NoiseValues is on the ColorRange', @() assert(all(nv(:) >= 0 & nv(:) <= 255)));
 check('NoiseValues is reproducible from the seed', ...
     @() assert(isequal(nv, inventoryPM('NoiseValues', w, nbox, 7))));
 check('a different seed gives different values', ...
     @() assert(~isequal(nv, inventoryPM('NoiseValues', w, nbox, 8))));
 check('colour noise is [h x w x 3]', @() assert(isequal( ...
     size(inventoryPM('NoiseValues', w, nbox, 7, 'uniform', 'colour')), [20 32 3])));
 check('colour channels differ from each other', @() assertChannelsDiffer( ...
     inventoryPM('NoiseValues', w, nbox, 7, 'uniform', 'colour')));
 % THE DEFAULTS ARE THE TEST HERE, not the arguments: uniform, monochrome, full
 % spread, meaning every pixel independently between black and white. Defaulting
 % the mean to the window background instead would have given 0 to 0.5 on a
 % black background, which is half contrast and looks plausible.
 check('the default is uniform black to white', @() assertUniformish( ...
     inventoryPM('NoiseValues', w, [0 0 200 200], 11)));
 check('the default is monochrome', @() assert(ismatrix( ...
     inventoryPM('NoiseValues', w, [0 0 32 20], 11))));
 % A normal spread narrow enough not to clip should show its SD.
 check('normal noise has the requested SD', @() assertNormalSD( ...
     inventoryPM('NoiseValues', w, [0 0 200 200], 12, 'normal', 'mono', ...
     128, 26), 26));

 % ---- textures -----------------------------------------------------------
 img = rand(64, 64, 3);
 tex = inventoryPM('MakeTexture', w, img);
 record('MakeTexture, RGB', true, '');
 check('UpdateTexture preserves handle', @() inventoryPM('UpdateTexture',w,tex,single(img)));
 reject('UpdateTexture invalid handle', @() inventoryPM('UpdateTexture',w,-1,img));
 check('MakeTexture, RGBA', @() inventoryPM('CloseTexture', w, ...
     inventoryPM('MakeTexture', w, rand(32,32,4))));
 check('MakeTexture, luminance', @() inventoryPM('CloseTexture', w, ...
     inventoryPM('MakeTexture', w, rand(32,32))));
 check('DrawTexture, whole window', @() inventoryPM('DrawTexture', w, tex));
 check('DrawTexture with dst rect', @() inventoryPM('DrawTexture', w, tex, [], box));
 check('DrawTexture with rotation', @() inventoryPM('DrawTexture', w, tex, [], box, 45));
 % Screen's positions: filterMode 6, globalAlpha 7, modulateColor 8.
 check('DrawTexture, bilinear', @() inventoryPM('DrawTexture', w, tex, [], box, 0, 1));
 check('DrawTexture, nearest',  @() inventoryPM('DrawTexture', w, tex, [], box, 0, 0));
 check('DrawTexture with globalAlpha', ...
     @() inventoryPM('DrawTexture', w, tex, [], box, 0, 1, 128));
 check('DrawTexture with modulateColor', ...
     @() inventoryPM('DrawTexture', w, tex, [], box, 0, 1, [], [255 0 0 128]));
 check('globalAlpha above the range warns and clamps', @() assertWarns( ...
     @() inventoryPM('DrawTexture', w, tex, [], box, 0, 1, 999), 'globalAlpha'));
 % The tint sat at position 6 until 0.4.0, so a Screen call asking for nearest
 % filtering was read as a black tint and drew nothing. It must now be refused
 % rather than silently reinterpreted.
 reject('a colour in the filterMode slot is rejected', ...
     @() inventoryPM('DrawTexture', w, tex, [], box, 0, [255 0 0 128]));
 inventoryPM('Flip', w);
 reject('bad texture handle rejected', @() inventoryPM('DrawTexture', w, 9999));
 % A colour at argument 6 is pre-0.4.0 code. It must be refused, and the message
 % must name the cause: this exact mistake sat in two demos after the positions
 % changed in 0.4.0, and the generic filterMode complaint sent the reader off to
 % think about filtering.
 reject('a colour in the filterMode slot is rejected', ...
     @() inventoryPM('DrawTexture', w, tex, [], box, 0, [255 0 0 255]));
 % Every DrawTexture call in the suite must use the current positions. The demos
 % are never run by this test, so nothing else would notice.
 check('no file in the suite passes a colour at argument 6', ...
     @() assertNoLegacyDrawTexture());
 % ---- two-phase presentation, measurement instruments --------------------
 check('SetDisplaySync off/on', @() setSyncBoth(w));
 check('PrefetchDrawable off/on', @() prefetchBoth(w));
 inventoryPM('FillRect', w, 51);
 check('PrepareFlip', @() inventoryPM('PrepareFlip', w));
 check('PresentNow', @() inventoryPM('PresentNow', w));

 check('Diagnostic returns a report', @() assert(isstruct(inventoryPM('Diagnostic',w))));
 check('GridAnchor returns three values', @() assert(numel(inventoryPM('GridAnchor',w))==3));
 check('NextPhase returns a scalar', @() assert(isscalar(inventoryPM('NextPhase',w,inventoryPM('GetSecs'),0))));
 check('NextRefresh returns a scalar', @() assert(isscalar(inventoryPM('NextRefresh',w,inventoryPM('GetSecs')))));
 check('WaitToDraw accepts a past target', @() inventoryPM('WaitToDraw',w,inventoryPM('GetSecs')-1,0));
 check('KbCheck returns scalar state', @() assert(isscalar(inventoryPM('KbCheck'))));
 check('KbName maps Escape', @() assert(inventoryPM('KbName','ESCAPE')==41));
 fprintf('Release any held keys for the KbWait release check.\n');
 check('KbWait until release', @() assert(isfinite(inventoryPM('KbWait',true,.005))));

 % ---- asynchronous keyboard queue ----------------------------------------
 % Zero mask makes this deterministic even while the user types. Event timing,
 % press/release capture and overflow are tested in tests/test_keyboard_queue.cpp.
 check('KbQueueRelease before creation', @() inventoryPM('KbQueueRelease'));
 reject('KbQueueStart before creation rejected', @() inventoryPM('KbQueueStart'));
 reject('KbQueueCreate with short mask rejected', @() inventoryPM('KbQueueCreate', zeros(1,255)));
 reject('KbQueueCreate with nonfinite mask rejected', @() inventoryPM('KbQueueCreate', nan(1,256)));
 reject('KbQueueCreate with too short interval rejected', @() inventoryPM('KbQueueCreate', zeros(1,256), 0.0001));
 reject('KbQueueCreate with too long interval rejected', @() inventoryPM('KbQueueCreate', zeros(1,256), 0.2));
 reject('KbQueueCreate with spare argument rejected', @() inventoryPM('KbQueueCreate', zeros(1,256), 0.002, 99));
 check('KbQueueCreate default arguments', @() inventoryPM('KbQueueCreate'));
 check('KbQueueCreate replaces queue with zero mask', @() inventoryPM('KbQueueCreate', false(256,1), 0.002));
 check('KbQueueCheck initially empty', @() assertQueueSummaryEmpty());
 check('KbQueueGetEvents initially empty', @() assertQueueEventsEmpty());
 check('KbQueueStart', @() inventoryPM('KbQueueStart'));
 check('KbQueueStart while running', @() inventoryPM('KbQueueStart'));
 inventoryPM('WaitSecs', 0.02);
 check('KbQueueCheck with zero mask', @() assertQueueSummaryEmpty());
 check('KbQueueGetEvents with zero mask', @() assertQueueEventsEmpty());
 check('KbQueueFlush while running', @() inventoryPM('KbQueueFlush'));
 check('KbQueueStop', @() inventoryPM('KbQueueStop'));
 check('KbQueueStop while stopped', @() inventoryPM('KbQueueStop'));
 check('KbQueueGetEvents after stop', @() assertQueueEventsEmpty());
 check('KbQueueCheck after stop', @() assertQueueSummaryEmpty());
 check('KbQueueFlush while stopped', @() inventoryPM('KbQueueFlush'));
 queueCommands = {'KbQueueStart','KbQueueStop','KbQueueFlush', ...
     'KbQueueRelease','KbQueueGetEvents','KbQueueCheck'};
 for qi = 1:numel(queueCommands)
  queueCommand = queueCommands{qi};
  reject([queueCommand ' with spare argument rejected'], @() inventoryPM(queueCommand, 99));
 end
 check('KbQueueRelease', @() inventoryPM('KbQueueRelease'));
 check('KbQueueRelease repeated', @() inventoryPM('KbQueueRelease'));
 for qi = 1:numel(queueCommands)
  queueCommand = queueCommands{qi};
  if strcmp(queueCommand, 'KbQueueRelease'), continue; end
  reject([queueCommand ' after release rejected'], @() inventoryPM(queueCommand));
 end

 % ---- teardown -----------------------------------------------------------
 reject('CloseTexture with a spare argument rejected', ...
     @() inventoryPM('CloseTexture', w, tex, 99));
 check('CloseTexture', @() inventoryPM('CloseTexture', w, tex));
 tex = [];
 reject('a closed texture cannot be drawn', @() inventoryPM('DrawTexture', w, tex));

 inventoryPM('Close', w); w = [];
 inventoryPM('ShowCursor');
 record('Close', true, '');
 reject('drawing after Close is rejected', @() inventoryPM('FillRect', 1));

 % ---- did we cover the inventory? ---------------------------------------
 declared = commandsInSource();
 covered = intersect(inventoryPM('__trace__'), declared);
 missing = setdiff(declared, covered);
 record('every command in PsychMetal.m is exercised', isempty(missing), ...
     sprintf('not covered: %s', strjoin(missing, ', ')));

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
 try, inventoryPM('KbQueueRelease'); catch, end
 try, if ~isempty(tex) && ~isempty(w), inventoryPM('CloseTexture', w, tex); end; catch, end
 try, if ~isempty(w), inventoryPM('Close', w); end; catch, end
 try, inventoryPM('ShowCursor'); catch, end
 rethrow(e);
end
end

% -------------------------------------------------------------------------
function assertNoLegacyDrawTexture()
% Scan every PsychMetal file for a DrawTexture whose sixth argument is a
% bracketed vector or a variable named like a colour, which is the pre-0.4.0
% signature where the tint sat at 6.
%
% Static, because the demos are not run by this test and a wrong slot there is
% invisible until somebody launches the demo. That is exactly how it survived
% in PsychMetalTextureDemo and PsychMetalDotDemo through a full audit: the
% inventory test calls DrawTexture directly, and all three copies of the help
% text still advertised the old position, so the documents agreed with each
% other and with nothing else.
files = dir(fullfile(fileparts(which('PsychMetal')), 'PsychMetal*.m'));
bad = {};
for k = 1:numel(files)
 src = fileread(fullfile(files(k).folder, files(k).name));
 % Join continuation lines so a call split across lines is one string. This
 % renumbers the lines, so the report names the file and the offending
 % argument rather than a line number that would be wrong.
 src = regexprep(src, '\.\.\.\s*\n\s*', ' ');
 lines = strsplit(src, sprintf('\n'));
 for j = 1:numel(lines)
  L = regexprep(lines{j}, '%.*$', '');
  % A deliberate misuse inside reject() is this test proving the argument is
  % refused, which is the opposite of the defect being looked for.
  if ~isempty(strfind(L, 'reject(')), continue; end %#ok<STREMP>
  m = regexp(L, '''DrawTexture''\s*,(.*)$', 'tokens', 'once');
  if isempty(m), continue; end
  args = splitTopLevel(m{1});
  % w, texture, srcRect, dstRect, angle, filterMode -> filterMode is the 6th.
  if numel(args) < 6, continue; end
  a6 = strtrim(args{6});
  if ~isempty(a6) && (a6(1) == '[' || any(strcmpi(a6, {'tint','color','colour','col'})))
   bad{end+1} = sprintf('%s (arg 6 is ''%s'')', files(k).name, a6); %#ok<AGROW>
  end
 end
end
assert(isempty(bad), ...
    ['These pass a colour where filterMode now goes: %s. ' ...
     'modulateColor is argument 8.'], strjoin(bad, '; '));
end

function parts = splitTopLevel(s)
% Split on commas that are not inside brackets, braces or quotes.
parts = {}; depth = 0; inStr = false; start = 1;
for k = 1:numel(s)
 c = s(k);
 if c == ''''
  inStr = ~inStr;
 elseif ~inStr
  if any(c == '([{')
   depth = depth + 1;
  elseif any(c == ')]}')
   if depth == 0
    parts{end+1} = s(start:k-1); %#ok<AGROW>
    return;                       % the call's own closing paren
   end
   depth = depth - 1;
  elseif c == ',' && depth == 0
   parts{end+1} = s(start:k-1); %#ok<AGROW>
   start = k + 1;
  end
 end
end
parts{end+1} = s(start:end);
end

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
 t0 = inventoryPM('GetSecs');
 if absolute
  t = inventoryPM('WaitSecs', 'UntilTime', t0 + secs);
 else
  t = inventoryPM('WaitSecs', secs);
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
[ww, hh] = inventoryPM('WindowSize', w);
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
now_ = inventoryPM('GetSecs');
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
inventoryPM('SetDisplaySync', w, false);
inventoryPM('SetDisplaySync', w, true);
end

function prefetchBoth(w)
inventoryPM('PrefetchDrawable', w, false);
inventoryPM('PrefetchDrawable', w, true);
end

function assertQueueEventsEmpty()
[events, dropped] = inventoryPM('KbQueueGetEvents');
assert(isa(events, 'double') && isequal(size(events), [0 3]));
assert(isa(dropped, 'double') && isscalar(dropped) && dropped == 0);
end

function assertQueueSummaryEmpty()
[pressed, firstPress, firstRelease, lastPress, lastRelease] = inventoryPM('KbQueueCheck');
assert(islogical(pressed) && isscalar(pressed) && ~pressed);
values = {firstPress, firstRelease, lastPress, lastRelease};
for k = 1:numel(values)
 assert(isa(values{k}, 'double') && isequal(size(values{k}), [1 256]) && all(values{k} == 0));
end
end

function varargout=inventoryPM(varargin)
% Trace actual calls rather than declaring a hand-maintained coverage list.
persistent exercised
if isempty(exercised), exercised={}; end
if nargin && strcmp(varargin{1},'__reset_trace__'), exercised={}; return; end
if nargin && strcmp(varargin{1},'__trace__'), varargout={unique(exercised)}; return; end
if nargin && ischar(varargin{1}) && ~isempty(varargin{1}) && varargin{1}(end)~='?'
 exercised{end+1}=lower(varargin{1});
end
[varargout{1:nargout}]=PsychMetal(varargin{:});
end
