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
% wrong position, a texture handle used after CloseTexture. Every
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
 check('Environment returns GPU/OS information', @() assert(isfield(inventoryPM('Environment'),'gpuAvailable')));
 reject('Environment arguments rejected', @() inventoryPM('Environment',99));
 check('Version returns a string', @() assert(ischar(inventoryPM('Version'))));
 check('bare call prints the command list', @() evalc('inventoryPM'));
 check('help topic prints', @() evalc('inventoryPM(''Flip?'')'));
 reject('unknown command is rejected', @() inventoryPM('NoSuchCommand'));
 reject('drawing before OpenWindow is rejected', @() inventoryPM('FillRect', 1));

 check('Resolution query', @() assert(isstruct(inventoryPM('Resolution',[]))));
 check('Resolutions list', @() assert(isstruct(inventoryPM('Resolutions',[]))));
 check('Screens lists the displays, 0 first, one main', @() assertScreens());
 check('KbQueueStatus reports state', @() assert(isstruct(inventoryPM('KbQueueStatus'))));
 % ---- audio: output only (no microphone prompt), silent (gain 0) ---------------
 check('AudioDevices lists devices', @() assert(isstruct(inventoryPM('AudioDevices'))));
 try
  inventoryPM('OpenAudio');
 catch
  inventoryPM('OpenAudio', struct('routes', 'any'));   % Bluetooth or AirPlay output: untimed, still testable
 end
 check('AudioStatus reports an open output', @() assert(getfield(inventoryPM('AudioStatus'), 'open')));
 stream=inventoryPM('MakeAudioStream',128,1);
 check('refill PCM stream',@() assert(inventoryPM('RefillSound',stream,single(zeros(32,1)),true)==32));
 check('stream seal/capacity',@() assert(inventoryPM('AudioStreamStatus',stream).sealed));
 reject('sealed stream refill refused',@() inventoryPM('RefillSound',stream,single(0)));
 inventoryPM('CloseSound',stream);
 tone = inventoryPM('MakeSound', inventoryPM('Tone', 440, 0.01, 48000), 48000);
 click = inventoryPM('MakeSound', inventoryPM('Click', 48000));
 check('WhiteNoise is reproducible from its seed', @() assert(isequal(inventoryPM('WhiteNoise', 0.01, 48000, 0.3, 1), inventoryPM('WhiteNoise', 0.01, 48000, 0.3, 1))));
 reject('WhiteNoise without a rate rejected', @() inventoryPM('WhiteNoise', 0.01));
 check('Play schedules a silent sound', @() assert(inventoryPM('Play', tone, inventoryPM('GetSecs') + 0.02, [], [], 0) > 0));
 check('AudioResults reports its start', @() assert(soundStarted()));
 voice = inventoryPM('Play', tone, [], [], [], 0, 0);
 check('Modulate modulates a voice', @() inventoryPM('Modulate', voice, 4, 0, 1));
 reject('Modulate depth above 1 rejected', @() inventoryPM('Modulate', voice, 4, 0, 2));
 check('StopSound stops every voice', @() inventoryPM('StopSound'));
 reject('Play with a time and a frame rejected', @() inventoryPM('Play', click, 1, 1));
 inventoryPM('CloseSound', click);
 reject('closed sound rejected', @() inventoryPM('Play', click));
 reject('StartRecording without input rejected', @() inventoryPM('StartRecording'));
 reject('StopRecording without input rejected', @() inventoryPM('StopRecording'));
 reject('GetRecording without input rejected', @() inventoryPM('GetRecording'));
 reject('VoiceKey without input rejected', @() inventoryPM('VoiceKey', 0.5));
 reject('InputRecent without input rejected', @() inventoryPM('InputRecent'));
 inventoryPM('CloseAudio');
 % ---- open ---------------------------------------------------------------
 screen = [];   % [] is the last active display
 [w, rect, ifi] = inventoryPM('OpenWindow', screen);
 stimulus=inventoryPM('MakeStimulus','grating',struct('contrast',.5));
 check('procedural stimulus draw', @() inventoryPM('DrawStimulus',w,stimulus,[0 0 32 32]));
 reject('invalid stimulus frequency', @() inventoryPM('MakeStimulus','grating',struct('frequency',1)));
 reject('invalid stimulus options', @() inventoryPM('MakeStimulus','noise',struct('unknown',1)));
 check('native timeline playback', @() assert(inventoryPM('PlayTimeline',w,2,[1 1 1 4 360 0]).submitted==2));
 reject('timeline odd period rejected', @() inventoryPM('PlayTimeline',w,2,[1 1 1 3 360 0]));
 maskRecipe=inventoryPM('MakeMask','annulus',struct('inner',.4,'edge',.1));
 check('analytic GPU mask draw',@() inventoryPM('DrawStimulus',w,stimulus,[0 0 32 32],maskRecipe));
 check('recent frame snapshot',@() assert(size(inventoryPM('RecentFrames',w),2)==4));
 reject('recent frame count rejected',@() inventoryPM('RecentFrames',w,0));
 report=[tempname '.json'];
 check('environment JSON export',@() assert(strcmp(inventoryPM('ExportEnvironment',report,w),report) && exist(report,'file')==2));
 reject('environment export never overwrites',@() inventoryPM('ExportEnvironment',report));
 if exist(report,'file'),delete(report);end
 reject('invalid annulus width',@() inventoryPM('MakeMask','annulus',struct('inner',1)));
 reject('invalid mask kind',@() inventoryPM('MakeMask','unknown'));
 imageTexture=inventoryPM('MakeTexture',w,uint8(ones(8,12,3)*255));
 check('masked still-image draw',@() inventoryPM('DrawMaskedTexture',w,imageTexture,maskRecipe));
 reject('masked image crop outside source',@() inventoryPM('DrawMaskedTexture',w,imageTexture,maskRecipe,[-1 0 12 8]));
 inventoryPM('CloseTexture',w,imageTexture);
 check('SDR HDR info',@() assert(~inventoryPM('HDRInfo',w).enabled));
 reject('HDR exposure requires HDR',@() inventoryPM('HDRExposure',w,1));
 pipeline=inventoryPM('CreateImagePipeline',w,{struct('type','gaussian','sigma',2),struct('type','exposure','stops',-.5)});
 pipelineSource=inventoryPM('MakeTexture',w,single(ones(8,8)));
 processed=inventoryPM('ProcessImage',w,pipeline,pipelineSource);
 check('pipeline output handle',@() assert(processed>0));
 check('pipeline output reuse',@() assert(inventoryPM('ProcessImage',w,pipeline,pipelineSource,processed)==processed));
 reject('unknown image operation refused',@() inventoryPM('CreateImagePipeline',w,{struct('type','blurr')}));
 inventoryPM('CloseImagePipeline',w,pipeline);
 reject('closed pipeline refused',@() inventoryPM('ProcessImage',w,pipeline,pipelineSource));
 inventoryPM('CloseTexture',w,processed);inventoryPM('CloseTexture',w,pipelineSource);
 shader=inventoryPM('CreateShader',w,'float4 psychmetal_main(float2 pixel,float2 uv,constant float4* p){return p[0];}');
 check('custom shader draw',@() inventoryPM('DrawShader',w,shader,[.5 .25 .75 1],[0 0 32 32],maskRecipe));
 inventoryPM('CloseShader',w,shader);
 reject('closed shader rejected',@() inventoryPM('DrawShader',w,shader));
 shader=inventoryPM('CreateShader',w,'float4 psychmetal_main(float2 pixel,float2 uv,constant float4* p){return p[0];}');
 check('every drawing command turns by a trailing angle', @() assertAngles(w, stimulus, shader));
 inventoryPM('CloseShader',w,shader);
 reject('an angle that is not finite rejected', @() inventoryPM('FillRect', w, 255, [0 0 10 10], [], NaN));
 reject('two angles for one rect rejected', @() inventoryPM('FillRect', w, 255, [0 0 10 10], [], [10 20]));
 check('Translate, Rotate and Scale compose: the last applies first', @() assertTransformMatrix(w));
 reject('PopMatrix without a push rejected', @() inventoryPM('PopMatrix', w));
 reject('Rotate about the x axis rejected', @() inventoryPM('Rotate', w, 30, 1, 0, 0));
 reject('Translate in depth rejected', @() inventoryPM('Translate', w, 1, 2, 3));
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

 % ---- the eight drawing primitives ---------------------------------------
 W = rect(3); H = rect(4);
 box = round([W*0.3, H*0.3, W*0.7, H*0.7]);
 check('FillRect, whole window',   @() inventoryPM('FillRect', w, 51));
 check('FillRect, explicit rect',  @() inventoryPM('FillRect', w, [255 0 0], box));
 check('FrameRect with pen width', @() inventoryPM('FrameRect', w, [0 255 0], box, 4));
 check('FillOval',                 @() inventoryPM('FillOval', w, [0 0 255], box));
 check('FrameOval with pen width', @() inventoryPM('FrameOval', w, [255 255 0], box, 6));
 check('FillArc: a wedge, Screen angles', @() inventoryPM('FillArc', w, [255 128 0], box, 30, 120));
 check('FrameArc with pen width, negative sweep', @() inventoryPM('FrameArc', w, [0 255 128], box, 0, -90, 4));
 check('DrawArc', @() inventoryPM('DrawArc', w, 255, box, 90, 270));
 check('FillArc: 4xN with one angle per rect', @() inventoryPM('FillArc', w, 200, [box(:) box(:)], [0 180], [90 45]));
 reject('FillArc without angles rejected', @() inventoryPM('FillArc', w, 255, box));
 reject('FillArc with a non-finite angle rejected', @() inventoryPM('FillArc', w, 255, box, NaN, 90));
 reject('FrameArc with zero pen rejected', @() inventoryPM('FrameArc', w, 255, box, 0, 90, 0));
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
 reject('GetImage without readback is rejected', @() inventoryPM('GetImage', w));
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
 % Screen's positions: a colour belongs at 8, and at 6 it is not a filter mode.
 reject('a colour in the filterMode slot is rejected', ...
     @() inventoryPM('DrawTexture', w, tex, [], box, 0, [255 0 0 128]));
 % DrawTextures: one value for every draw, or one per draw, as Screen's.
 check('DrawTextures, one texture at several places', ...
     @() inventoryPM('DrawTextures', w, tex, [], [box; box + 20]'));
 check('DrawTextures, every argument per texture', @() inventoryPM('DrawTextures', w, ...
     [tex tex], [0 0 32 32; 32 32 64 64]', [box; box + 20]', [0 45], [1 0], [255 128], ...
     [255 0 0; 0 255 0]'));
 reject('DrawTextures with mismatched counts rejected', ...
     @() inventoryPM('DrawTextures', w, [tex tex tex], [], [box; box + 20]'));
 reject('DrawTextures with a bad handle rejected', @() inventoryPM('DrawTextures', w, [tex 9999]));
 reject('DrawTextures with a bad filter mode rejected', ...
     @() inventoryPM('DrawTextures', w, tex, [], box, 0, 2));
 inventoryPM('Flip', w);
 reject('bad texture handle rejected', @() inventoryPM('DrawTexture', w, 9999));

 % ---- partial updates, blending, linearization, text, the link --------------
 patch = single(img(1:16, 1:24, :));
 check('UpdateTexture with a rect replaces part in place', @() inventoryPM('UpdateTexture', w, tex, patch, [8 4 32 20]));
 check('a partial update keeps the texture size', @() drawAndFlip(w, tex, box));
 reject('UpdateTexture rect of another size rejected', @() inventoryPM('UpdateTexture', w, tex, patch, [8 4 30 20]));
 reject('UpdateTexture rect outside the texture rejected', @() inventoryPM('UpdateTexture', w, tex, patch, [48 56 72 72]));
 reject('UpdateTexture rect with another image type rejected', ...
     @() inventoryPM('UpdateTexture', w, tex, zeros(16, 24, 3, 'uint8'), [8 4 32 20]));
 check('BlendFunction reports and sets the mode', @() assert(isequal({inventoryPM('BlendFunction', w), ...
     inventoryPM('BlendFunction', w, 'add'), inventoryPM('BlendFunction', w, 'alpha')}, {'alpha','alpha','add'})));
 reject('an unknown blend mode is rejected', @() inventoryPM('BlendFunction', w, 'multiply'));
 check('Linearize by gamma, per channel, by table, then off', @() assertLinearize(w));
 reject('a gamma of zero is rejected', @() inventoryPM('Linearize', w, 0));
 reject('a table with values above 1 is rejected', @() inventoryPM('Linearize', w, linspace(0, 2, 64)' * [1 1 1]));
 reject('a table with two columns is rejected', @() inventoryPM('Linearize', w, zeros(64, 2)));
 check('TextBounds measures a line', @() assertTextBounds(w));
 check('DrawText centres by default', @() assertCentred(inventoryPM('DrawText', w, 'PsychMetal'), rect));
 check('DrawText at a position, in a colour, size and font', @() assert(isequal(firstTwo( ...
     inventoryPM('DrawText', w, native2unicode(uint8([71 114 195 188 195 159 101 44 32 228 189 160 229 165 189]), 'UTF-8'), ...
     40, 60, [255 255 0], 48, 'Menlo')), [40 60])));
 reject('DrawText with a character matrix rejected', @() inventoryPM('DrawText', w, ['one'; 'two']));
 reject('DrawText with no text rejected', @() inventoryPM('DrawText', w, ''));
 reject('DrawText with a size of zero rejected', @() inventoryPM('DrawText', w, 'a', 0, 0, 255, 0));
 reject('TextBounds with a number rejected', @() inventoryPM('TextBounds', w, 42));
 inventoryPM('Flip', w);
 check('LinkInfo reports the link and what the picture needs', @() assertLink(inventoryPM('LinkInfo', w)));
 reject('LinkInfo with a spare argument rejected', @() inventoryPM('LinkInfo', w, 99));

 % ---- offscreen windows, polygons, the clip rect, lines of text ------------------
 [off, offRect] = inventoryPM('OpenOffscreenWindow', w, [0 0 0 0], [0 0 256 128]);
 record('OpenOffscreenWindow', true, '');
 check('an offscreen window has its own rect', @() assertOffscreenRect(off, offRect));
 star = [128 10; 150 90; 240 90; 165 120; 128 60; 90 120; 16 90; 106 90];
 check('every kind of draw goes into an offscreen window', @() drawEverything(off, tex, star));
 check('an offscreen window is drawn as a texture', @() drawOffscreen(w, off, tex, box));
 reject('an offscreen window drawn into itself rejected', @() inventoryPM('DrawTexture', off, off));
 reject('UpdateTexture of an offscreen window rejected', @() inventoryPM('UpdateTexture', w, off, img));
 reject('an offscreen window of no size rejected', @() inventoryPM('OpenOffscreenWindow', w, 0, [0 0 0 10]));
 check('BlendFunction ''copy'' clears an offscreen window', @() clearOffscreen(off));
 check('Close closes an offscreen window', @() inventoryPM('Close', off));
 reject('drawing into a closed offscreen window rejected', @() inventoryPM('FillRect', off, 0));
 centred = star + repmat([rect(3) / 2 - 128, rect(4) / 2 - 64], size(star, 1), 1);
 check('FillPoly, concave', @() inventoryPM('FillPoly', w, [255 255 0], centred));
 check('FramePoly with a pen width', @() inventoryPM('FramePoly', w, [0 255 255], centred, 3));
 check('FillPoly, points as 2xN', @() inventoryPM('FillPoly', w, 255, centred'));
 reject('a polygon of two points rejected', @() inventoryPM('FillPoly', w, 255, [1 2; 3 4]));
 reject('a polygon with a non-finite point rejected', @() inventoryPM('FillPoly', w, 255, [1 2; 3 NaN; 5 6]));
 reject('FramePoly with a pen of zero rejected', @() inventoryPM('FramePoly', w, 255, centred, 0));
 check('Clip confines draws and returns the old rect', @() assertClip(w, box));
 reject('a clip rect of no area rejected', @() inventoryPM('Clip', w, [10 10 10 20]));
 check('DrawText with lines and a wrap width', @() assertLines(w));
 inventoryPM('Flip', w);

 % ---- frames queued ahead, input events --------------------------------------------
 check('queued frames are shown in order, each at the refresh asked for', @() assertQueue(w, ifi));
 check('QueueCancel abandons frames not yet handed over', @() assertCancel(w, ifi));
 reject('QueueFlip without a time rejected', @() inventoryPM('QueueFlip', w));
 reject('QueueFlip with a time of zero rejected', @() inventoryPM('QueueFlip', w, 0));
 check('a Flip after queued frames', @() inventoryPM('Flip', w));
 check('a frame a wait ahead, then frames for the next refreshes', @() assertWaitThenNext(w, ifi));
 check('MouseEvents returns events and a count', @() assertMouseEvents(w));
 check('TouchEvents returns events and a count', @() assertTouchEvents(w));
 check('KbQueueStatus says where key times come from', @() assertKeyTimes());
 % ---- presentation reports ------------------------------------------------
 inventoryPM('FillRect', w, 51);
 check('FlipInfo reports the last flip', @() assertFlipInfo(inventoryPM('FlipInfo', w)));
 reject('FlipInfo with a spare argument rejected', @() inventoryPM('FlipInfo', w, 99));

 check('Diagnostic returns a report', @() assert(isstruct(inventoryPM('Diagnostic',w))));
 check('GridAnchor returns three values', @() assert(numel(inventoryPM('GridAnchor',w))==3));
 check('NextPhase returns a scalar', @() assert(isscalar(inventoryPM('NextPhase',w,inventoryPM('GetSecs'),0))));
 check('NextRefresh returns a scalar', @() assert(isscalar(inventoryPM('NextRefresh',w,inventoryPM('GetSecs')))));
 check('WaitToDraw accepts a past target', @() inventoryPM('WaitToDraw',w,inventoryPM('GetSecs')-1,0));
 check('KbCheck returns scalar state', @() assert(isscalar(inventoryPM('KbCheck'))));
 check('KbName maps Escape', @() assert(inventoryPM('KbName','ESCAPE')==41));
 fprintf('Release any held keys for the KbWait release check.\n');
 check('KbWait until release', @() assert(isfinite(inventoryPM('KbWait',true,.005))));
 check('SetMouse moves the cursor to a window pixel', @() assertSetMouse(w, rect));
 reject('SetMouse outside the window rejected', @() inventoryPM('SetMouse', w, -5, 10));
 reject('SetMouse with a non-finite position rejected', @() inventoryPM('SetMouse', w, NaN, 10));
 reject('SetMouse without a position rejected', @() inventoryPM('SetMouse', w));

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

 % ---- readback: a session of its own, because it is chosen at open --------
 [w, rbRect] = inventoryPM('OpenWindow', struct('backgroundColor', [51 102 153], 'readback', true));
 inventoryPM('FillRect', w, [255 128 0], [10 20 110 70]);
 inventoryPM('Flip', w);
 shot = inventoryPM('GetImage', w);
 record('GetImage', true, '');
 check('GetImage is [h w 3] uint8', @() assert(isequal(size(shot), [rbRect(4) rbRect(3) 3]) && isa(shot, 'uint8')));
 check('GetImage returns the rectangle that was drawn', @() assert( ...
     all(all(shot(21:70, 11:110, 1) == 255 & shot(21:70, 11:110, 2) == 128 & shot(21:70, 11:110, 3) == 0))));
 check('GetImage returns the background beside it', @() assert( ...
     all(all(shot(1:20, :, 1) == 51 & shot(1:20, :, 2) == 102 & shot(1:20, :, 3) == 153))));
 check('GetImage with a rect is that part of the frame', @() assert( ...
     isequal(inventoryPM('GetImage', w, [5 15 120 80]), shot(16:80, 6:120, :))));
 reject('GetImage with a rect outside the window rejected', @() inventoryPM('GetImage', w, [0 0 rbRect(3) + 1 10]));
 reject('GetImage with a fractional rect rejected', @() inventoryPM('GetImage', w, [0.5 0 10 10]));
 reject('GetImage with an empty rect rejected', @() inventoryPM('GetImage', w, [10 10 10 20]));
 reject('GetImage with a three-element rect rejected', @() inventoryPM('GetImage', w, [0 0 10]));
 reject('GetImage with a spare argument rejected', @() inventoryPM('GetImage', w, [], 99));
 check('Diagnostic reports readback', @() assert(getfield(getfield(inventoryPM('Diagnostic', w), 'summary'), 'readbackEnabled')));
 check('transforms and a turned rect land where they should', @() assertTransformedPixels(w));
 % ---- movies: tests/movies, made by make test (tests/make_test_movie.mm) ---
 movieFile = fullfile(fileparts(which('PsychMetal')), 'tests', 'movies', 'frames_h264.mp4');
 movie = [];
 try
  [movie, movieInfo] = inventoryPM('OpenMovie', w, movieFile);
  record('OpenMovie', true, '');
 catch e
  record('OpenMovie', false, [e.message ' (make test writes the test movies)']);
 end
 if ~isempty(movie)
  check('OpenMovie reports frames, rate, size and sound', @() assert(movieInfo.frames == 90 && ...
      abs(movieInfo.frameRate - 30) < 1e-6 && movieInfo.width == 160 && movieInfo.height == 96 && ...
      movieInfo.soundChannels == 2 && movieInfo.constantRate));
  reject('TranscodeMovie: same destination refused', @() inventoryPM('TranscodeMovie', movieFile, movieFile, 'h264'));
  reject('TranscodeMovie: unsupported codec refused', @() inventoryPM('TranscodeMovie', movieFile, [tempname '.mp4'], 'wrong'));
  check('PrepareMovie: bounded lookahead', @() assert(inventoryPM('PrepareMovie', movie, 4, 64*1024*1024)==4));
  reject('PrepareMovie: negative count', @() inventoryPM('PrepareMovie', movie, -1));
  reject('PrepareMovie: fractional budget', @() inventoryPM('PrepareMovie', movie, 4, 1.5));
  check('MovieFrameTimes: one per frame, 1/30 s apart', @() assert(numel(inventoryPM('MovieFrameTimes', movie)) == 90 && ...
      all(abs(diff(inventoryPM('MovieFrameTimes', movie)) - 1/30) < 1e-9)));
  % In order, back, forward past a key frame, and the last; numbered from 1 here.
  check('DrawMovieFrame draws the frame asked for, in any order', @() assertMovieFrames(w, movie, [1 2 3 38 4 90 17]));
  check('MovieSound: the track from the first frame, clicks on whole seconds', ...
      @() assertMovieSound(inventoryPM('MovieSound', movie, 48000), 48000));
  reject('MovieSound at 1 Hz rejected', @() inventoryPM('MovieSound', movie, 1));
  check('RefreshesPerFrame: nearest whole number, a half rounded up', @() assert(isequal( ...
      [inventoryPM('RefreshesPerFrame', 60, 30), inventoryPM('RefreshesPerFrame', 60, 24), ...
       inventoryPM('RefreshesPerFrame', 120, 50), inventoryPM('RefreshesPerFrame', 60, 120)], [2 3 2 1])));
  check('PlayMovie shows every frame for the same number of refreshes', @() assertPlayMovie(w, movie));
  check('every test movie (ProRes 4444 and 422, H.264, HEVC, sideways) has its frames, first to last', ...
      @() assertTestMovies(w, fileparts(movieFile)));
  reject('OpenMovie of a missing file rejected', @() inventoryPM('OpenMovie', w, '/missing/movie.mov'));
  reject('DrawMovieFrame past the last frame rejected', @() inventoryPM('DrawMovieFrame', w, movie, 91));
  reject('DrawMovieFrame with index 0 rejected', @() inventoryPM('DrawMovieFrame', w, movie, 0));
  reject('DrawMovieFrame with a source outside the frame rejected', @() inventoryPM('DrawMovieFrame', w, movie, 1, [0 0 161 96]));
  reject('PlayMovie past the end rejected', @() inventoryPM('PlayMovie', w, movie, struct('first', 81, 'count', 20)));
  reject('PlayMovie with an unknown sound mode rejected', @() inventoryPM('PlayMovie', w, movie, struct('sound', 'loud')));
  reject('PlayMovie sound resample without audio rejected', @() inventoryPM('PlayMovie', w, movie, struct('count', 2, 'sound', 'resample')));
  reject('PlayMovie with an unknown option rejected', @() inventoryPM('PlayMovie', w, movie, struct('speed', 2)));
  check('StartMovieRecording and StopMovieRecording: every frame at the refresh it was aimed at', ...
      @() assertRecording(w, rbRect));
  reject('StartMovieRecording with an unknown codec rejected', ...
      @() inventoryPM('StartMovieRecording', w, fullfile(tempdir, 'x.mov'), struct('codec', 'vp9')));
  reject('StartMovieRecording of ProRes to .mp4 rejected', @() inventoryPM('StartMovieRecording', w, fullfile(tempdir, 'x.mp4')));
  reject('StartMovieRecording at scale 0 rejected', ...
      @() inventoryPM('StartMovieRecording', w, fullfile(tempdir, 'x.mov'), struct('scale', 0)));
  reject('StopMovieRecording when not recording rejected', @() inventoryPM('StopMovieRecording', w));
  check('CloseMovie', @() inventoryPM('CloseMovie', movie));
  reject('a closed movie cannot be drawn', @() inventoryPM('DrawMovieFrame', w, movie, 1));
  reject('CloseMovie twice rejected', @() inventoryPM('CloseMovie', movie));
 end
 reject('readback that is not true or false is rejected at open', @() inventoryPM('OpenWindow', struct('readback', 2)));
 inventoryPM('Close', w); w = [];

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

function k = movieFrameNumber(image)
% The number make_test_movie writes into a frame's top half: 16 bars, bit i in bar i.
[h, wide, ~] = size(image);
row = mean(double(image(floor(h / 4) + 1, :, :)), 3);
k = 0;
for bar = 0:15
 if row(floor((2 * bar + 1) * wide / 32) + 1) >= 128, k = k + 2^bar; end
end
end

function assertMovieFrames(w, movie, frames)
for k = frames
 inventoryPM('FillRect', w, 0);
 inventoryPM('DrawMovieFrame', w, movie, k, [], [0 0 160 96], 0, 0);
 inventoryPM('Flip', w);
 got = movieFrameNumber(inventoryPM('GetImage', w, [0 0 160 96]));
 if got ~= k - 1, error('frame %d drawn, frame %d seen', k, got + 1); end
end
end

function assertTestMovies(w, folder)
% Each movie make_test_movie writes: its frame count, and its first and last frames by number.
names = {'frames_prores4444.mov', 'frames_h264.mp4', 'frames_hevc.mov', 'frames_24fps.mov', 'frames_portrait.mov'};
expected = [90 30 160 96; 90 30 160 96; 90 30 160 96; 48 24 160 96; 30 30 96 160];
problems = {};
for j = 1:numel(names)
 [movie, info] = inventoryPM('OpenMovie', w, fullfile(folder, names{j}));
 got = [info.frames, round(info.frameRate * 1e6) / 1e6, info.width, info.height];
 if ~isequal(got, expected(j, :))
  problems{end+1} = sprintf('%s: %s, not %s', names{j}, mat2str(got), mat2str(expected(j, :))); %#ok<AGROW>
 elseif info.width > info.height        % the sideways one is checked by eye in the movie demo
  for k = [1, info.frames, 2]
   inventoryPM('FillRect', w, 0);
   inventoryPM('DrawMovieFrame', w, movie, k, [], [0 0 160 96], 0, 0);
   inventoryPM('Flip', w);
   seen = movieFrameNumber(inventoryPM('GetImage', w, [0 0 160 96])) + 1;
   if seen ~= k, problems{end+1} = sprintf('%s: frame %d drawn, frame %d seen', names{j}, k, seen); end %#ok<AGROW>
  end
 else
  inventoryPM('DrawMovieFrame', w, movie, info.frames, [], [0 0 96 160]);
  inventoryPM('Flip', w);
 end
 inventoryPM('CloseMovie', movie);
end
if ~isempty(problems), error('%s', strjoin(problems, '; ')); end
end

function drawNumber(w, rect, k)
% The test movies' pattern across the window: 16 bars in the top half, bar i white if bit i of k is set.
W = rect(3); H = rect(4);
inventoryPM('FillRect', w, 0);
bits = find(bitand(k, 2 .^ (0:15)));
if ~isempty(bits)
 inventoryPM('FillRect', w, 255, [W * (bits - 1) / 16; zeros(1, numel(bits)); W * bits / 16; H / 2 + zeros(1, numel(bits))]);
end
end

function assertRecording(w, rect)
% Ten frames on consecutive refreshes, then one three refreshes later, queued so their aims are exact;
% recorded, opened as a movie, and each frame read back by its number.
path = [tempname '.mov'];
cleanup = onCleanup(@() deleteIfThere(path)); %#ok<NASGU>
inventoryPM('StartMovieRecording', w, path, struct('scale', 0.25));
try
 inventoryPM('StartMovieRecording', w, path);
 error('a second StartMovieRecording was accepted');
catch e
 if strcmp(e.message, 'a second StartMovieRecording was accepted'), rethrow(e); end
end
ifi = inventoryPM('GetFlipInterval', w);
t0 = inventoryPM('GetSecs') + 10 * ifi;
for k = 0:10
 drawNumber(w, rect, k);
 inventoryPM('QueueFlip', w, t0 + (k + 2 * (k == 10)) * ifi);
end
inventoryPM('QueueResults', w);
report = inventoryPM('StopMovieRecording', w);
assert(report.frames == 11 && report.refreshes == 13 && strcmp(report.codec, 'prores4444'), 'recording report');
[movie, info] = inventoryPM('OpenMovie', w, path);
steps = round(diff(inventoryPM('MovieFrameTimes', movie)) * report.refreshHz * 1000) / 1000;
assert(info.frames == 11 && isequal(steps(:)', [ones(1, 9) 3]), 'recorded frame times');
for k = 0:10
 inventoryPM('FillRect', w, 0);
 inventoryPM('DrawMovieFrame', w, movie, k + 1, [], [0 0 160 96], 0, 0);
 inventoryPM('Flip', w);
 seen = movieFrameNumber(inventoryPM('GetImage', w, [0 0 160 96]));
 if seen ~= k, inventoryPM('CloseMovie', movie); error('recorded frame %d plays back as %d', k, seen); end
end
inventoryPM('CloseMovie', movie);
end

function deleteIfThere(path)
if exist(path, 'file'), delete(path); end
end

function assertMovieSound(samples, rate)
% make_test_movie's sound: 90 frames at 30 per second is 3 s; a click at 0.9 starting each second.
assert(size(samples, 2) == 2 && abs(size(samples, 1) - 3 * rate) <= 1025, 'sound length');
loud = find(abs(samples(:, 1)) > .5);
starts = (loud([true; diff(loud) > rate / 10]) - 1) / rate;
assert(numel(starts) == 3 && all(abs(starts(:)' - [0 1 2]) < .002), 'clicks at %s', mat2str(starts'));
end

function assertPlayMovie(w, movie)
r = inventoryPM('PlayMovie', w, movie, struct('first', 11, 'count', 6, 'sound', 'off', 'dstRect', [0 0 160 96]));
assert(r.frames == 6 && r.submitted == 6 * r.refreshes && strcmp(r.sound, 'off') && ~r.cancelled);
assert(movieFrameNumber(inventoryPM('GetImage', w, [0 0 160 96])) == 15, 'the last frame shown is not frame 16');
end

% -------------------------------------------------------------------------
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
% Octave does not record a disabled warning in lastwarn, so there the warning
% stays on and is displayed; MATLAB records it either way.
if ~exist('OCTAVE_VERSION', 'builtin')
 old = warning('off', 'PsychMetal:ColorRange');
 restore = onCleanup(@() warning(old));
end
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

function drawAndFlip(w, tex, box)
inventoryPM('DrawTexture', w, tex, [0 0 64 64], box);
inventoryPM('Flip', w);
end

function v = firstTwo(r)
v = r(1:2);
end

function assertLinearize(w)
ramp = linspace(0, 1, 64)' .^ (1 / 2.2) * [1 1 1];
assert(isempty(inventoryPM('Linearize', w)), 'Linearization is not off at open.');
specs = {2.2, [2.1 2.2 2.3], ramp};
for k = 1:numel(specs)
 inventoryPM('Linearize', w, specs{k});
 inventoryPM('FillRect', w, 128);
 inventoryPM('Flip', w);
 assert(isequal(inventoryPM('Linearize', w), specs{k}), 'Linearize did not report its setting.');
end
inventoryPM('Linearize', w, []);
inventoryPM('Flip', w);
assert(isempty(inventoryPM('Linearize', w)), 'Linearize(w, []) did not turn it off.');
end

function assertTextBounds(w)
[small, ascent] = inventoryPM('TextBounds', w, 'PsychMetal', 48);
large = inventoryPM('TextBounds', w, 'PsychMetal', 96);
assert(isequal(small(1:2), [0 0]) && small(3) > 48 && small(3) < 480 && small(4) >= 40 && small(4) <= 96 && ...
    ascent > 0 && ascent < small(4), 'TextBounds returned %s, ascent %g.', mat2str(small), ascent);
assert(large(3) > 1.8 * small(3) && large(4) > 1.8 * small(4) - 4, 'Text at twice the size measured %s against %s.', ...
    mat2str(large), mat2str(small));
longer = inventoryPM('TextBounds', w, 'PsychMetal PsychMetal', 48);
assert(longer(3) > small(3), 'A longer line is not wider.');
% A line is measured without being rendered; what it measures must be what it
% then draws as, and what it measures again once its rendering is kept.
line = 'Measured, then drawn';
[before, rise] = inventoryPM('TextBounds', w, line, 48);
drawn = inventoryPM('DrawText', w, line, 0, 0, 255, 48);
[after, riseAfter] = inventoryPM('TextBounds', w, line, 48);
assert(isequal(before, drawn) && isequal(before, after) && rise == riseAfter, ...
    'A line measured %s, drew as %s and then measured %s.', mat2str(before), mat2str(drawn), mat2str(after));
end

function assertCentred(where, rect)
centre = [where(1) + where(3), where(2) + where(4)] / 2;
assert(all(abs(centre - rect(3:4) / 2) <= 1), 'Text drawn at %s is not centred in %s.', mat2str(where), mat2str(rect));
end

function assertLink(k)
assert(isstruct(k) && isequal(fieldnames(k), {'lanes';'laneGbps';'payloadGbps';'pixelGbps';'compressed'}));
assert(k.pixelGbps > 0, 'pixelGbps is %g.', k.pixelGbps);
if isfinite(k.lanes)
 assert(k.lanes >= 1 && k.laneGbps > 0 && k.payloadGbps > 0 && k.payloadGbps < k.lanes * k.laneGbps);
end
assert(isnan(k.compressed) || any(k.compressed == [0 1]), 'compressed is %g.', k.compressed);
end

function assertOffscreenRect(off, offRect)
[a, b] = inventoryPM('WindowSize', off);
assert(isequal(offRect, [0 0 256 128]) && isequal(inventoryPM('Rect', off), [0 0 256 128]) && a == 256 && b == 128);
end

function drawEverything(off, tex, star)
inventoryPM('FillRect', off, 51);
inventoryPM('FrameRect', off, 255, [2 2 254 126], 2);
inventoryPM('FillOval', off, [255 0 0], [10 10 60 60]);
inventoryPM('FrameOval', off, 255, [10 10 60 60], 2);
inventoryPM('DrawDots', off, [70 80; 20 20], 6, 255);
inventoryPM('DrawLines', off, [0 256; 64 64], 1, 128);
inventoryPM('DrawGabor', off, 255, [100 20 180 100], 0.2, 0.05);
inventoryPM('DrawNoise', off, [200 10 240 50], 3);
inventoryPM('DrawTexture', off, tex, [], [10 70 60 120]);
inventoryPM('DrawText', off, 'abc', [], [], 255, 24);
inventoryPM('FillPoly', off, [255 255 0], star);
end

function drawOffscreen(w, off, tex, box)
inventoryPM('DrawTexture', w, off);
inventoryPM('DrawTextures', w, [off tex], [], [box; box + 20]', [0 30]);
inventoryPM('Flip', w);
end

function clearOffscreen(off)
inventoryPM('BlendFunction', off, 'copy');
inventoryPM('FillRect', off, [0 0 0 0]);
inventoryPM('BlendFunction', off, 'alpha');
end

function assertClip(w, box)
assert(isempty(inventoryPM('Clip', w)), 'A clip rect is set at open.');
inner = [box(1) + 10, box(2) + 10, box(3) - 10, box(4) - 10];
assert(isempty(inventoryPM('Clip', w, inner)), 'Clip did not return the old rect.');
inventoryPM('FillRect', w, [255 0 255]);
assert(isequal(inventoryPM('Clip', w, []), inner) && isempty(inventoryPM('Clip', w)), 'Clip(w, []) did not end the clip.');
inventoryPM('Flip', w);
end

function assertAngles(w, stimulus, shader)
% Every drawing command takes a trailing angle, and leaves no transform behind.
r = [40 40 120 80];
inventoryPM('FillRect', w, 255, [r; 130 40 170 60]', [], [30 60]);
inventoryPM('FrameRect', w, 255, r, 2, 30);
inventoryPM('FillOval', w, 255, r, [], 30);
inventoryPM('FrameOval', w, 255, r, 2, [], [], 30);
inventoryPM('FillArc', w, 255, r, 0, 90, 30);
inventoryPM('FrameArc', w, 255, r, 0, 90, 2, [], [], 30);
inventoryPM('DrawArc', w, 255, r, 0, 90, 30);
inventoryPM('DrawDots', w, [-20 20; 0 0], 8, 255, [80 60], 0, [], 45);
inventoryPM('DrawLines', w, [-20 20; 0 0], 2, 255, [80 60], [], [], 45);
% Screen's own arguments before the angle: a PTB program's are accepted, and change nothing.
inventoryPM('DrawDots', w, [-20 20; 0 0], 8, 255, [80 60], 1, 1);
inventoryPM('DrawLines', w, [-20 20; 0 0], 2, 255, [80 60], 1, 1);
inventoryPM('FrameOval', w, 255, r, 2, 2, 0);
inventoryPM('FrameArc', w, 255, r, 0, 90, 2, 2, 0);
inventoryPM('DrawGabor', w, 255, r, 0.2, 0.05, 0, 0, 30);
inventoryPM('DrawNoise', w, [40 40 80 80], 1, [], [], [], [], 30);
inventoryPM('FillPoly', w, 255, [40 40; 120 40; 80 90], [], 30);
inventoryPM('FramePoly', w, 255, [40 40; 120 40; 80 90], 2, 30);
inventoryPM('DrawText', w, 'turned', 40, 40, 255, 24, [], [], 30);
inventoryPM('DrawStimulus', w, stimulus, r, [], [], [], 30);
inventoryPM('DrawShader', w, shader, [.5 .25 .75 1], r, [], [], 30);
assert(isequal(inventoryPM('Transform', w), [1 0 0 1 0 0]), 'A turned draw left the transform %s.', ...
    mat2str(inventoryPM('Transform', w)));
inventoryPM('Flip', w);
end

function assertTransformMatrix(w)
assert(isequal(inventoryPM('Transform', w), [1 0 0 1 0 0]), 'A transform is set at open.');
inventoryPM('PushMatrix', w);
inventoryPM('Translate', w, 10, 20);
inventoryPM('Rotate', w, 90);
inventoryPM('Scale', w, 2, 3);
% Translate, then turn 90 clockwise, then scale: (x, y) -> (10 - 3y, 20 + 2x).
m = inventoryPM('Transform', w);
assert(max(abs(m - [0 2 -3 0 10 20])) < 1e-9, 'Translate, rotate and scale gave %s.', mat2str(m));
inventoryPM('LoadIdentity', w);
assert(isequal(inventoryPM('Transform', w), [1 0 0 1 0 0]), 'LoadIdentity left a transform.');
inventoryPM('Rotate', w, 30, 0, 0, -1);                  % about -z: the other way
m = inventoryPM('Transform', w);
assert(max(abs(m - [cosd(30) -sind(30) sind(30) cosd(30) 0 0])) < 1e-9, 'Rotate about -z gave %s.', mat2str(m));
inventoryPM('LoadIdentity', w);
inventoryPM('Translate', w, 5, 6);
inventoryPM('PopMatrix', w);
assert(isequal(inventoryPM('Transform', w), [1 0 0 1 0 0]), 'PopMatrix did not restore the transform.');
end

function assertTransformedPixels(w)
inventoryPM('PushMatrix', w);
inventoryPM('Translate', w, 100, 50);
inventoryPM('Scale', w, 2, 2);
inventoryPM('FillRect', w, [0 255 0], [10 10 30 20]);         % [120 70 160 90] on the screen
inventoryPM('PopMatrix', w);
inventoryPM('FillRect', w, [0 0 255], [200 100 240 110], [], 90);  % stood up: [215 85 225 125]
inventoryPM('Flip', w);
shot = double(inventoryPM('GetImage', w));
is = @(rows, cols, rgb) all(all(shot(rows, cols, 1) == rgb(1) & shot(rows, cols, 2) == rgb(2) & shot(rows, cols, 3) == rgb(3)));
bg = [51 102 153];
assert(is(73:88, 123:158, [0 255 0]) && is(61:68, 121:160, bg) && is(93:100, 121:160, bg) && ...
       is(88:123, 218:223, [0 0 255]) && is(102:109, 201:212, bg) && is(102:109, 229:240, bg), ...
       'The translated and scaled rect, or the turned one, is not where it should be.');
end

function assertLines(w)
[one, ascent] = inventoryPM('TextBounds', w, 'PsychMetal', 40);
two = inventoryPM('TextBounds', w, sprintf('PsychMetal\nPsychMetal'), 40);
assert(two(3) == one(3) && two(4) == one(4) + 52 && ascent > 0, 'Two lines measured %s against one line %s.', ...
    mat2str(two), mat2str(one));
wrapped = inventoryPM('TextBounds', w, 'PsychMetal PsychMetal PsychMetal', 40, [], one(3) * 2.5);
assert(wrapped(3) < 2.5 * one(3) && wrapped(4) == two(4), 'Three words wrapped at 2.5 words measured %s.', mat2str(wrapped));
where = inventoryPM('DrawText', w, sprintf('first line\n\nthird line, which is longer'), [], [], 255, 40);
assert(where(4) - where(2) > 100, 'Three lines were drawn in %s.', mat2str(where));
end

function assertQueue(w, ifi)
% Times a quarter refresh before refreshes, so each frame is due 0.25 refresh after its time and one
% that slips a refresh is 1.25 after.
t0 = inventoryPM('Flip', w) + 17.75 * ifi;
tokens = zeros(1, 6);
for k = 0:5
 inventoryPM('FillRect', w, 40 * (k + 1));
 [tokens(k + 1), pending, capacity] = inventoryPM('QueueFlip', w, t0 + k * ifi);
end
assert(inventoryPM('GetSecs') < t0 && pending == 6 && capacity >= 6, 'QueueFlip returned pending %g, capacity %g.', pending, capacity);
frames = inventoryPM('QueueResults', w);
assert(isequal(size(frames), [6 4]) && isequal(frames(:, 4)', tokens), 'QueueResults returned %s.', mat2str(size(frames)));
late = (frames(:, 2) - frames(:, 1))' * 1000;
steps = diff(frames(:, 2))' / ifi;
detail = sprintf('status %s, shown %s ms after the times asked (%.2f is on time), %s refreshes apart', mat2str(frames(:, 3)'), ...
    mat2str(round(late * 100) / 100), 0.25 * ifi * 1000, mat2str(round(steps * 100) / 100));
assert(all(frames(:, 3) == 0) && all(abs(late / 1000 - 0.25 * ifi) < 0.25 * ifi) && all(abs(steps - 1) < 0.25), '%s', detail);
fprintf('  queued frames: %s\n', detail);
end

function assertScreens()
[screens, info] = inventoryPM('Screens');
assert(~isempty(info) && isequal(screens, 0:numel(info) - 1) && sum([info.main]) == 1 && ...
       all([info.pixelWidth] > 0) && all([info.hz] >= 0), 'Screens returned %s.', mat2str(screens));
end

function assertWaitThenNext(w, ifi)
% A frame 30 refreshes ahead (Flip returns long before then), then three flipped at once, each for
% the next refresh. Until 0.11.0 the system dropped the first of the three (status 1) and the
% waiting frame stayed up a refresh too long.
vbl = inventoryPM('Flip', w);
inventoryPM('FillRect', w, 255);
inventoryPM('Flip', w, vbl + 30 * ifi);
for k = 0:2
 inventoryPM('FillRect', w, 60 * k);
 inventoryPM('Flip', w);
end
inventoryPM('WaitSecs', 0.3);
rows = inventoryPM('RecentFrames', w, 5);
steps = diff(rows(:, 3))' / ifi;
detail = sprintf('status %s, %s refreshes apart (should be 30, 1, 1, 1)', mat2str(rows(:, 2)'), mat2str(round(steps * 100) / 100));
assert(all(rows(:, 2) == 0) && all(rows(:, 3) > 0) && all(abs(steps - [30 1 1 1]) < 0.25), '%s', detail);
fprintf('  after a wait: %s\n', detail);
end

function assertCancel(w, ifi)
t0 = inventoryPM('GetSecs') + 1.0;
for k = 0:2, inventoryPM('QueueFlip', w, t0 + k * ifi); end
n = inventoryPM('QueueCancel', w);
frames = inventoryPM('QueueResults', w);
assert(n == 3 && isequal(size(frames), [3 4]) && all(frames(:, 3) == 5) && inventoryPM('GetSecs') < t0, ...
    'Cancelled %g; status %s.', n, mat2str(frames(:, 3)'));
end

function assertTouchEvents(w)
[events, dropped] = inventoryPM('TouchEvents', w);
assert(size(events, 2) == 5 && dropped >= 0, 'TouchEvents returned %s.', mat2str(size(events)));
end

function assertMouseEvents(w)
first = inventoryPM('MouseEvents', w);
[events, dropped] = inventoryPM('MouseEvents', w);
assert(isequal(size(first), [0 5]) && size(events, 2) == 5 && dropped >= 0, 'MouseEvents returned %s, then %s.', ...
    mat2str(size(first)), mat2str(size(events)));
end

function assertKeyTimes()
inventoryPM('KbQueueCreate');
inventoryPM('KbQueueStart');
status = inventoryPM('KbQueueStatus');
inventoryPM('KbQueueRelease');
assert(all(isfield(status, {'eventTimestamps', 'eventStamped', 'pollStamped', 'maxEventDelayMs'})));
if status.eventTimestamps, fprintf('  key times: those the key events carry\n');
else, fprintf('  key times: those of the polling scans (no key events: is this application allowed Input Monitoring?)\n'); end
end

function assertFlipInfo(info)
names = {'confirmed','dropped','slipped','queueMs','flipMs','flips','droppedFrames','slipFlips'};
assert(isstruct(info) && isempty(setxor(fieldnames(info), names)) && info.flips >= 1 && ...
    info.droppedFrames >= 0 && islogical(info.dropped));
end

function assertSetMouse(w, rect)
% Move the cursor, read it back, and put it back where it was (held inside the window).
[x0, y0] = inventoryPM('GetMouse', w);
inventoryPM('SetMouse', w, 200, 100);
[x, y] = inventoryPM('GetMouse', w);
inventoryPM('SetMouse', w, min(max(x0, 0), rect(3)), min(max(y0, 0), rect(4)));
assert(abs(x - 200) <= 2 && abs(y - 100) <= 2, 'GetMouse returned (%g, %g) after SetMouse to (200, 100).', x, y);
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

function ok = soundStarted()
events = inventoryPM('AudioResults', 1);
ok = ~isempty(events) && any(strcmp({events.kind}, 'sound start'));
end
