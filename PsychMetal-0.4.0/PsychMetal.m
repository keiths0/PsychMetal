function varargout = PsychMetal(command, varargin)
% PsychMetal  Native Metal stimulus presentation on macOS. No OpenGL.
% Version 0.4.0. SPDX-License-Identifier: MIT.
%
% PsychMetal
% PsychMetal('OpenWindow?')
% PsychMetal('MakeTexture?')
% PsychMetal('Flip?')
% PsychMetal('Diagnostic?')
% PsychMetal('Close?')
% PsychMetal('Version?')
%
% Call PsychMetal without arguments for a list of supported commands.
% Append '?' to a command for detailed help, following Screen's convention.
persistent S

if nargin == 0
 printGeneralHelp;
 return;
end
if ~(ischar(command) || (isstring(command) && isscalar(command)))
 error('PsychMetal:Command', 'Command must be a character string.');
end
command = char(command);
if strcmp(command, '?')
 printGeneralHelp;
 return;
end
if ~isempty(command) && command(end) == '?'
 printCommandHelp(command(1:end-1));
 return;
end

switch lower(command)
 case 'openwindow'
  assert(isempty(S), 'PsychMetal is already open. Close the existing window first.');
  assert(numel(varargin) <= 6, ...
      ['OpenWindow accepts screen number, background colour, drawable count, ' ...
       'wait-for-confirmation, displaySync and captureDisplay.']);
  % -1 means the last active display, which is what max(Screen('Screens'))
  % resolved to. The core enumerates displays through CGGetActiveDisplayList and
  % validates the index, so nothing here needs Psychtoolbox to ask what exists.
  screen = -1;
  if ~isempty(varargin) && ~isempty(varargin{1})
   assert(isnumeric(varargin{1}) && isreal(varargin{1}) && isscalar(varargin{1}), ...
       'Screen number must be a real numeric scalar.');
   screen = double(varargin{1});
   assert(isfinite(screen) && screen == fix(screen) && screen >= 0, ...
       'Screen number must be a non-negative integer.');
  end
  % SECOND ARGUMENT IS THE BACKGROUND COLOUR, as in Screen('OpenWindow'). Each
  % frame is cleared to it before any drawing, so a grey field costs nothing per
  % frame rather than a full-screen FillRect. On this window's ColorRange, which
  % is 255 at open exactly as Screen's is, so `0` is black and `255` is white.
  % Scalar grey, RGB or RGBA all accepted; default black.
  %
  % frameLatency used to occupy this position. It was removed rather than
  % moved: it set CAMetalDisplayLink.preferredFrameLatency, which was measured
  % to do nothing at all. See docs/05_results.md section 2.
  colorRange = 255;
  bgColor = [0 0 0 1];
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   bgColor = colorToRGBA(varargin{2}, 'Background colour', colorRange);
  end
  % THREE, paired with drawable prefetch below. Three alone costs a refresh of
  % latency over two; three WITH prefetch costs nothing and drops nothing.
  %
  % Sample-to-presented, 300 frames per arm, this window:
  %
  %   2 drawables, no prefetch    1.92 refreshes   57.6 Hz, 12-30 skipped
  %   3 drawables, no prefetch    2.90             60.000, 0 skipped
  %   3 drawables + prefetch      1.96             60.000, 0 skipped
  %   2 drawables + prefetch      1.95             30.000, 299 skipped
  %
  % Two plus prefetch starves the pool: holding one of two leaves nothing to
  % pipeline against, so the rate halves. Three plus prefetch is the only
  % configuration that gets both the latency and the rate.
  %
  % Two drawables leave only about 3.2 ms of a 16.67 ms refresh outside Flip,
  % which is also why a string of unrelated things once looked like the cause of
  % missed frames: texture format, the shape instance ring, OpenGL interop and
  % GetMouse were all measured while the loop sat on the edge of the deadline,
  % where the rate is decided by noise rather than by whatever was varied.
  % Check headroom before believing such a result.
  drawableCount = 3;
  if numel(varargin) >= 3 && ~isempty(varargin{3})
   assert(isnumeric(varargin{3}) && isreal(varargin{3}) && isscalar(varargin{3}), ...
       'Maximum drawable count must be 2 or 3.');
   drawableCount = double(varargin{3});
   assert(isfinite(drawableCount) && any(drawableCount == [2 3]), ...
       'Maximum drawable count must be 2 or 3.');
  end
  % Prefetch only makes sense with a drawable to spare, so it follows the count
  % rather than being an independent default the caller can get wrong.
  prefetch = (drawableCount >= 3);
  % Waiting inside Flip for the confirmed presentedTime costs the full
  % submit-to-present lead, which exceeds one refresh, so it halves the
  % presentation rate. Off by default: Flip returns the predicted refresh
  % boundary from the measured grid and confirmations are collected
  % asynchronously for Diagnostic. Turn it on only when a measured timestamp
  % per flip matters more than sustaining one presentation per refresh.
  waitForConfirm = false;
  if numel(varargin) >= 4 && ~isempty(varargin{4})
   assert(isscalar(varargin{4}) && (islogical(varargin{4}) || isnumeric(varargin{4})), ...
       'Wait-for-confirmation must be a logical scalar.');
   waitForConfirm = logical(varargin{4});
  end
  % Diagnostic only: disabling vsync tears, but tells you whether the interval
  % between GPU completion and reported presentedTime is a wait for a refresh
  % boundary or accounting that happens regardless.
  vsync = true;
  if numel(varargin) >= 5 && ~isempty(varargin{5})
   assert(isscalar(varargin{7}) && (islogical(varargin{7}) || isnumeric(varargin{7})), ...
       'displaySync must be a logical scalar.');
   vsync = logical(varargin{5});
  end
  % Diagnostic. The window sits at CGShieldingWindowLevel either way, so this
  % isolates CGDisplayCapture itself. Leave it on for real use: capture is what
  % keeps other applications from being composited over the stimulus.
  captureDisplay = true;
  if numel(varargin) >= 6 && ~isempty(varargin{6})
   assert(isscalar(varargin{8}) && (islogical(varargin{8}) || isnumeric(varargin{8})), ...
       'captureDisplay must be a logical scalar.');
   captureDisplay = logical(varargin{6});
  end
  % NO PSYCHTOOLBOX WINDOW. Through 0.3.1 this opened a 128x96 Screen window and
  % an offscreen buffer, purely so the core could be handed an OpenGL texture to
  % attach an IOSurface to, plus the geometry and flip interval. All of it is
  % gone: the core reads the display through Core Graphics and returns the
  % geometry and refresh itself.
  %
  % That window is what printed the Psychtoolbox startup banner, the sync-test
  % results and the desktop-compositor warning on every open. The last of those
  % was actively misleading, because it described Screen('Flip') on a host
  % window that never flipped, not PsychMetal's presentation path.
  try
   % Promote a command-line host to a regular foreground application before
   % Metal creates a window, so the policy never changes mid-run.
   PsychMetalCore('PrepareApp');
   [width, height, ifi, pointW, pointH] = PsychMetalCore('Open', screen, ...
       drawableCount, double(waitForConfirm), double(vsync), double(captureDisplay));
   displayRect = [0 0 width height];
   % Pixel and point rectangles for this display. Both are needed because
   % GetMouse reports points while every drawing command takes pixels, and on a
   % scaled Retina mode the ratio is not an integer.
   physicalRect = displayRect;
   logicalRect = [0 0 pointW pointH];
   PsychMetalCore('SetBackgroundColor', bgColor(1), bgColor(2), bgColor(3), bgColor(4));
   % NOTHING HERE CALLS PSYCHTOOLBOX. Opening a window used to verify that
   % GetSecs and CACurrentMediaTime agree, which meant loading a Psychtoolbox
   % mex and printing its licence banner on every open -- to check a
   % relationship between two system clocks that cannot change from one window
   % to the next. PsychMetalInventoryTest checks it instead, which is where a
   % claim about the environment belongs.
   fprintf('PsychMetal: %dx%d at %.3f Hz. Direct Metal presentation, no OpenGL.\n', ...
       width, height, 1/ifi);
   fprintf(['PsychMetal: colours run 0-%g, as Screen. ' ...
       'PsychMetal(''ColorRange'', w, 1) for 0-1.\n'], colorRange);
  catch e
   try, PsychMetalCore('Close'); catch, end
   rethrow(e);
  end
  % The window token. It was Psychtoolbox's offscreen window handle through
  % 0.3.1, which is why demos could pass it to Screen; there is no such window
  % now, so it is an opaque integer that only PsychMetal accepts.
  buffer = 1;
  S = struct('buffer',buffer,'ifi',ifi, ...
      'colorRange',colorRange, 'textureSize',zeros(0,2), ...
      'logicalRect',logicalRect, ...
      'physicalRect',physicalRect, ...
      'bgColor',bgColor, ...
      'drawableCount',drawableCount, ...
      'waitForConfirm',waitForConfirm, ...
      'lastVblConfirmed',false, ...
      'lastQueueMs',NaN,'lastFlipMs',NaN, ...
      'flipCount',0,'slipCount',0,'lastSlipFlip',NaN,'lastSlipRefreshes',0);
 % Move the nextDrawable block from the start of Flip to the end, so it lands
 % before the caller's next input sample rather than after it. Worth a full
 % refresh of input latency and costs nothing in rate, provided there is a
 % third drawable to pipeline against.
 if prefetch
  PsychMetalCore('PrefetchDrawable', 1);
 end
 varargout = {buffer, displayRect, ifi};

 case 'maketexture'
  % texture = PsychMetal('MakeTexture', w, image)
  %
  % A native Metal texture. Previously this returned a Screen texture created
  % against the hidden PTB host, which meant drawing it went back through
  % OpenGL; now the pixels are uploaded straight to an MTLTexture.
  %
  % image is HxW (grey), HxWx3 (RGB) or HxWx4 (RGBA) on 0-1, matching the
  % PsychMetal drawing convention rather than the window's ColorRange.
  %
  % Stored as RGBA16Float: an 11-bit mantissa, well beyond the 8-bit drawable,
  % and filterable in hardware on Apple GPUs. RGBA32Float is not reliably
  % filterable and cost about 40 percent of the frame rate when sampled
  % linearly.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''MakeTexture'') requires the window handle and an image.');
  assert(numel(varargin) == 2, 'MakeTexture takes a window and an image.');
  img = double(varargin{2});
  assert(ndims(img) <= 3 && ~isempty(img), 'The image must be HxW, HxWx3 or HxWx4.');
  [ih, iw, ic] = size(img);
  switch ic
   case 1, rgba = cat(3, img, img, img, ones(ih, iw));
   case 3, rgba = cat(3, img, ones(ih, iw));
   case 4, rgba = img;
   otherwise
    error('PsychMetal:Texture', 'The image must have 1, 3 or 4 channels.');
  end
  if any(rgba(:) > 1.001)
   warning('PsychMetal:TextureRange', ...
       ['Texture values run 0 to 1, but the image reaches %g. It will be ' ...
        'clamped. Divide 0-255 images by 255.'], max(rgba(:)));
  end
  rgba = min(max(rgba, 0), 1);
  % Metal wants channel-fastest, then x, then y, with row 1 of the image first
  % so that texture v = 0 is the top row. permute puts it in exactly that
  % order for a column-major array.
  data = permute(rgba, [3 2 1]);
  handle = PsychMetalCore('MakeTexture', iw, ih, data(:));
  S.textureSize(handle + 1, 1:2) = [iw ih];
  varargout = {handle};

 case 'drawtexture'
  % PsychMetal('DrawTexture', w, texture [, srcRect] [, dstRect] [, angle] [, tint])
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''DrawTexture'') requires the window handle and a texture.');
  handle = double(varargin{2});
  assert(isscalar(handle) && handle >= 0 && handle + 1 <= size(S.textureSize,1) && ...
      all(S.textureSize(handle + 1,:) > 0), 'Unknown texture handle.');
  tw = S.textureSize(handle + 1, 1); th = S.textureSize(handle + 1, 2);
  src = [0 0 tw th];
  if numel(varargin) >= 3 && ~isempty(varargin{3}), src = double(varargin{3}(:))'; end
  assert(numel(src) == 4, 'srcRect must be [left top right bottom] in texture pixels.');
  dst = [];
  if numel(varargin) >= 4 && ~isempty(varargin{4}), dst = double(varargin{4}(:))'; end
  if isempty(dst)
   % Centred at the source size, like Screen('DrawTexture') with no dstRect.
   cx = (S.physicalRect(1) + S.physicalRect(3)) / 2;
   cy = (S.physicalRect(2) + S.physicalRect(4)) / 2;
   sw = abs(src(3) - src(1)); sh = abs(src(4) - src(2));
   dst = [cx - sw/2, cy - sh/2, cx + sw/2, cy + sh/2];
  end
  assert(numel(dst) == 4, 'dstRect must be [left top right bottom] in window pixels.');
  angle = 0;
  if numel(varargin) >= 5 && ~isempty(varargin{5}), angle = double(varargin{5}); end
  assert(isscalar(angle) && isfinite(angle), 'The rotation angle must be a scalar.');
  % ARGUMENT POSITIONS FOLLOW Screen('DrawTexture') EXACTLY: filterMode is 6,
  % globalAlpha 7, modulateColor 8. The tint used to sit at 6, which meant that
  % Screen('DrawTexture', w, t, [], dst, 0, 0) — a perfectly ordinary request
  % for nearest-neighbour filtering — was read as a black tint and drew nothing.
  % A drop-in replacement that silently draws the wrong thing is worse than one
  % that does not exist.
  filterMode = 1;
  if numel(varargin) >= 6 && ~isempty(varargin{6})
   filterMode = double(varargin{6});
   assert(isscalar(filterMode) && any(filterMode == [0 1]), ...
       ['filterMode must be 0 (nearest) or 1 (bilinear). Screen''s 2, 3 and 4 ' ...
        'select mipmap and oversampled paths that have no Metal equivalent here.']);
  end
  globalAlpha = [];
  if numel(varargin) >= 7 && ~isempty(varargin{7})
   globalAlpha = double(varargin{7});
   assert(isscalar(globalAlpha) && isfinite(globalAlpha), ...
       'globalAlpha must be a scalar.');
  end
  tint = [1 1 1 1];
  if numel(varargin) >= 8 && ~isempty(varargin{8})
   t = expandColors(varargin{8}, 1, S.colorRange);
   tint = t(:)';
  end
  % Screen applies globalAlpha on top of modulateColor, so it multiplies rather
  % than replaces. It is on the window's ColorRange like every other colour.
  if ~isempty(globalAlpha)
   ga = globalAlpha / S.colorRange;
   if ga > 1.001 || ga < -0.001
    warning('PsychMetal:ColorRange', ...
        ['globalAlpha of %g is outside this window''s ColorRange of %g and ' ...
         'will be clamped.'], globalAlpha, S.colorRange);
   end
   tint(4) = tint(4) * min(max(ga, 0), 1);
  end
  assert(numel(varargin) <= 8, ...
      ['DrawTexture takes w, texture, srcRect, dstRect, rotationAngle, ' ...
       'filterMode, globalAlpha and modulateColor.']);
  % Normalised source coordinates for the sampler.
  srcN = [src(1)/tw, src(2)/th, src(3)/tw, src(4)/th];
  PsychMetalCore('DrawTexture', handle, srcN, ...
      [min(dst(1),dst(3)), min(dst(2),dst(4)), ...
       max(dst(1),dst(3)), max(dst(2),dst(4))], ...
      angle * pi / 180, tint, filterMode);

 case 'closetexture'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''CloseTexture'') requires the window handle and a texture.');
  assert(numel(varargin) == 2, 'CloseTexture takes a window and a texture.');
  handle = double(varargin{2});
  PsychMetalCore('CloseTexture', handle);
  if handle + 1 <= size(S.textureSize,1)
   S.textureSize(handle + 1, 1:2) = [0 0];
  end

 case 'prefetchdrawable'
  % PsychMetal('PrefetchDrawable', w, tf)
  %
  % Acquire the next frame's drawable at the END of Flip instead of the start.
  %
  % nextDrawable blocks until the pool frees one, which with two drawables is a
  % full presentation away. Called at the start of Flip, that wait lands between
  % your input sample and the commit, so the sample is stale on arrival even
  % though the pipeline is optimal: 0.942 refreshes sample-to-commit against
  % 0.975 commit-to-photons. The wait cannot be removed, but it can be moved to
  % before the next sample rather than after it.
  %
  % Frame time and presentation rate are unchanged. Only staleness changes.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''PrefetchDrawable'') needs the window handle and a logical.');
  on = logical(varargin{2});
  % Two drawables cannot spare one: holding it leaves nothing to pipeline
  % against and the rate halves. Measured 30.000/s with 299 of 300 intervals
  % skipped, against 60.000 and none at three drawables.
  if on && S.drawableCount < 3
   warning('PsychMetal:PrefetchStarvesPool', ...
       ['Prefetching with %d drawables starves the pool and halves the ' ...
        'presentation rate. Open the window with 3 drawables instead.'], ...
       S.drawableCount);
  end
  PsychMetalCore('PrefetchDrawable', double(on));

 case 'colorrange'
  % oldRange = PsychMetal('ColorRange', w [, range])
  %
  % The maximum value a colour component may take, as Screen('ColorRange').
  % Opens at 255, so code written against Screen ports without touching a single
  % colour literal. Set it to 1 for the 0-1 convention that PsychDefaultSetup(2)
  % gives Screen.
  %
  % The shader always works in 0 to 1; this only says what the numbers you pass
  % mean. Changing it does not restate colours already drawn, and takes effect
  % from the next drawing command.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'ColorRange requires the window handle from OpenWindow.');
  assert(numel(varargin) <= 2, 'ColorRange takes a window and an optional range.');
  old = S.colorRange;
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   r = double(varargin{2});
   assert(isscalar(r) && isfinite(r) && r > 0, 'ColorRange must be a positive scalar.');
   S.colorRange = r;
  end
  varargout = {old};

 case 'getsecs'
  % t = PsychMetal('GetSecs')
  %
  % The clock the display is timestamped in, read directly.
  %
  % Flip's timestamps come from MTLDrawable.presentedTime, which is in
  % CACurrentMediaTime units. This returns CACurrentMediaTime with no
  % conversion, so an event timestamped with it and a presentation timestamped
  % by the system are in the same clock exactly, with nothing in between.
  %
  % HOW THIS DIFFERS FROM GetSecs. Both should be mach_absolute_time scaled by
  % the same timebase, so they should be the same number. PsychMetal measures
  % the difference at OpenWindow anyway and reports it as
  % measured, and they are: bracketing the read between two GetSecs calls, the
  % residual scales with the call cost rather than staying put, and extrapolates
  % to 0.12 us at zero cost. So this and GetSecs return the same number, and no
  % conversion happens anywhere in PsychMetal.
  %
  % Use it when you want the display's clock by name rather than by coincidence;
  % ordinary code can use either.
  assert(isempty(varargin), 'GetSecs takes no arguments.');
  varargout = {PsychMetalCore('Now')};

 case 'waitsecs'
  % t = PsychMetal('WaitSecs', seconds)
  % t = PsychMetal('WaitSecs', 'UntilTime', when)
  %
  % Wait, in the display's clock. Both forms follow WaitSecs, and both return
  % the time on return.
  %
  % 'UntilTime' is the one to use in a stimulus loop. A relative wait restarts
  % its own clock read every time, so a loop of them drifts by the cost of
  % asking; an absolute deadline does not accumulate.
  %
  % Sleeps on mach_wait_until against an absolute deadline in the same counter
  % CACurrentMediaTime reports, then spins the last 500 us. The spin is not
  % politeness about CPU: the kernel's timer slack is hundreds of microseconds
  % under load, and a stimulus deadline missed by that much is a missed frame.
  assert(~isempty(varargin), 'WaitSecs needs a duration or ''UntilTime''.');
  if ischar(varargin{1}) || isstring(varargin{1})
   assert(strcmpi(char(varargin{1}), 'untiltime'), ...
       'The only string form is PsychMetal(''WaitSecs'', ''UntilTime'', t).');
   assert(numel(varargin) == 2, '''UntilTime'' needs a time.');
   deadline = double(varargin{2});
   assert(isscalar(deadline) && isfinite(deadline), 'The deadline must be a finite scalar.');
  else
   assert(numel(varargin) == 1, 'WaitSecs takes one duration.');
   secs = double(varargin{1});
   assert(isscalar(secs) && isfinite(secs), 'The duration must be a finite scalar.');
   deadline = PsychMetalCore('Now') + secs;
  end
  varargout = {PsychMetalCore('Wait', deadline)};

 case {'resolution','resolutions'}
  % old = PsychMetal('Resolution', screenNumber [, width, height])
  % all = PsychMetal('Resolutions', screenNumber)
  %
  % Display mode management, as Screen('Resolution') and Screen('Resolutions').
  % Both return structs with width, height, pixelWidth, pixelHeight and hz.
  %
  % WIDTH AND HEIGHT ARE POINTS, as Screen's are. On a Retina panel the mode's
  % pixel size is larger, and it is the pixel size that PsychMetal draws in, so
  % both are reported: a mode 1710 x 1107 points on this machine is 3420 x 2214
  % pixels, and rect comes back as the latter.
  %
  % Setting a mode requires the window to be closed. The drawable is sized at
  % open, so changing the mode underneath a live window would leave every
  % coordinate wrong with nothing to say so.
  screenArg = -1;
  if ~isempty(varargin) && ~isempty(varargin{1})
   screenArg = double(varargin{1});
   assert(isscalar(screenArg) && isfinite(screenArg) && screenArg == fix(screenArg) ...
       && screenArg >= 0, 'Screen number must be a non-negative integer.');
  end
  m = PsychMetalCore('Modes', screenArg);
  if strcmp(cmd, 'resolutions')
   assert(numel(varargin) <= 1, 'Resolutions takes only a screen number.');
   varargout = {modeStruct(m)};
  else
   assert(numel(varargin) <= 3, ...
       'Resolution takes a screen number and an optional width and height.');
   old = modeStruct(m(1,:));
   if numel(varargin) >= 3 && ~isempty(varargin{2}) && ~isempty(varargin{3})
    PsychMetalCore('SetMode', screenArg, double(varargin{2}), double(varargin{3}));
   end
   varargout = {old};
  end

 case 'rect'
  % rect = PsychMetal('Rect', w)
  %
  % The window's pixel rectangle, as Screen('Rect'). PsychMetal windows are
  % always the full panel, so this is [0 0 width height] at native resolution.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'Rect requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'Rect takes only the window handle.');
  varargout = {S.physicalRect};

 case 'windowsize'
  % [width, height] = PsychMetal('WindowSize', w)
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'WindowSize requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'WindowSize takes only the window handle.');
  varargout = {S.physicalRect(3) - S.physicalRect(1), ...
               S.physicalRect(4) - S.physicalRect(2)};

 case 'getflipinterval'
  % ifi = PsychMetal('GetFlipInterval', w)
  %
  % As Screen('GetFlipInterval'), but this one is measured rather than
  % calibrated at open: once thirty presentations have been confirmed the
  % returned value is the least-squares fit to the refresh grid, repeatable to
  % 0.043 ppm. Before that it is the display mode's nominal rate.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'GetFlipInterval requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'GetFlipInterval takes only the window handle.');
  g = PsychMetalCore('GridAnchor');
  if numel(g) >= 3 && g(3) >= 30 && isfinite(g(2)) && g(2) > 0
   varargout = {g(2)};
  else
   varargout = {S.ifi};
  end

 case 'backgroundcolor'
  % PsychMetal('BackgroundColor', w, color)
  %
  % The colour each frame is cleared to before any drawing, as set by
  % OpenWindow's second argument. Changing it between blocks avoids reopening
  % the window, and costs nothing per frame: it is a load action on the render
  % pass, not a draw.
  %
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'BackgroundColor requires the window handle from OpenWindow.');
  assert(numel(varargin) == 2, 'BackgroundColor needs a window and a colour.');
  bg = colorToRGBA(varargin{2}, 'Background colour', S.colorRange);
  PsychMetalCore('SetBackgroundColor', bg(1), bg(2), bg(3), bg(4));
  S.bgColor = bg;
  if nargout >= 1, varargout{1} = bg; end

 case 'getmouse'
  % [x, y, buttons] = PsychMetal('GetMouse', w)
  %
  % The pointer in PIXELS on the presentation display, the same coordinates
  % every drawing command takes, so a position can be used as a rect corner
  % without conversion.
  %
  % Psychtoolbox's GetMouse is Screen('GetMouseHelper') and reports POINTS with
  % the origin at the bottom left of the main display. This reads NSEvent
  % directly and converts, which removes both the Screen call and a conversion
  % the caller could get wrong: on a display whose backing scale is not 1 a raw
  % point position tracks at the wrong speed.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''GetMouse'') requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'GetMouse takes only the window handle.');
  [mx, my, buttons] = PsychMetalCore('Mouse');
  varargout = {mx, my, buttons};

 case {'hidecursor','showcursor'}
  % PsychMetal('HideCursor'), PsychMetal('ShowCursor')
  %
  % Psychtoolbox's HideCursor is Screen('HideCursorHelper'), so calling it pulls
  % in the Screen mex and prints its startup banner for what is one Core
  % Graphics call. These do it directly, which is what keeps a PsychMetal-only
  % session free of Psychtoolbox output.
  %
  % No window handle: the cursor belongs to the display, not to a window, and a
  % script that errors before OpenWindow still has to be able to give it back.
  assert(isempty(varargin), '%s takes no arguments.', command);
  PsychMetalCore('Cursor', double(strcmpi(command, 'showcursor')));

 case 'kbcheck'
  % [keyIsDown, secs, keyCode] = PsychMetal('KbCheck')
  %
  % The state of every keyboard attached to the machine, right now, at the
  % moment of the call. keyCode is 1x256 logical indexed by HID usage code,
  % which is what Psychtoolbox's KbCheck returns and what KbName's numbers
  % mean, so keyCode(41) is Escape here exactly as it is there.
  %
  % There is no deviceNumber argument and there cannot be one. macOS merges
  % every keyboard into a single system-wide state before any of this is
  % visible: built-in, USB and Bluetooth arrive identical and unlabelled.
  % That merge is why this needs no device enumeration and no per-device
  % quirk handling, and it is also the limit. If you need to know WHICH
  % keyboard, or to read a response box that does not present as a keyboard,
  % that is PsychHID and this is not a substitute for it.
  %
  % Neither is it a substitute for PsychHID's TIMING. secs is when the poll
  % happened, not when the key went down, so the resolution of a reaction
  % time measured this way is your polling interval — one refresh, if you
  % poll once a frame. Bluetooth adds its own tens of milliseconds of
  % latency and jitter on top, invisibly. Use it to advance a trial, not to
  % measure one.
  assert(isempty(varargin), ['PsychMetal(''KbCheck'') takes no arguments. ' ...
      'There is no deviceNumber: macOS merges every keyboard into one ' ...
      'state before PsychMetal can see it, so all of them are always read.']);
  [keyIsDown, secs, keyCode, securePid] = PsychMetalCore('Keys');
  if securePid > 0
   warnSecureInput(securePid);
  end
  varargout = {keyIsDown, secs, keyCode};

 case 'kbwait'
  % secs = PsychMetal('KbWait' [, untilRelease] [, pollInterval])
  %
  % Block until a key is down, or until every key is up if untilRelease is
  % true. Polls at pollInterval seconds, 5 ms by default, because a tight
  % spin would burn a core for the whole intertrial interval to gain
  % resolution the poll cannot deliver anyway.
  assert(numel(varargin) <= 2, 'KbWait takes untilRelease and pollInterval.');
  untilRelease = false; pollInterval = 0.005;
  if numel(varargin) >= 1 && ~isempty(varargin{1})
   untilRelease = logical(varargin{1});
  end
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   pollInterval = double(varargin{2});
   assert(isscalar(pollInterval) && pollInterval >= 0, ...
       'pollInterval must be a nonnegative scalar.');
  end
  while true
   [down, secs] = PsychMetal('KbCheck');
   if down ~= untilRelease, break; end
   PsychMetal('WaitSecs', pollInterval);
  end
  if nargout >= 1, varargout{1} = secs; end

 case 'kbname'
  % index = PsychMetal('KbName', name)
  % name  = PsychMetal('KbName', index)
  % names = PsychMetal('KbName', keyCode)     % every key currently down
  %
  % The numbers are HID usage codes, so they are Psychtoolbox's numbers
  % under KbName('UnifyKeyNames') and a ported script's constants survive.
  % The NAMES are this file's own table, below, and a few punctuation
  % spellings may differ from Psychtoolbox's. The table is short and it is
  % right there, so check it rather than assuming.
  assert(numel(varargin) == 1, 'KbName takes one argument.');
  arg = varargin{1};
  tbl = keyNameTable();
  if ischar(arg)
   hit = find(strcmp(tbl(:,2), arg));
   if isempty(hit)
    hit = find(strcmpi(tbl(:,2), arg));   % case-insensitive second chance
   end
   assert(~isempty(hit), 'Unknown key name ''%s''.', arg);
   varargout{1} = tbl{hit(1), 1};
  elseif isscalar(arg)
   hit = find([tbl{:,1}] == arg);
   assert(~isempty(hit), 'No key has usage code %g.', arg);
   varargout{1} = tbl{hit(1), 2};
  else
   % A keyCode vector from KbCheck: report what is down.
   idx = find(arg);
   names = {};
   for k = 1:numel(idx)
    hit = find([tbl{:,1}] == idx(k));
    if isempty(hit)
     names{end+1} = sprintf('usage%d', idx(k)); %#ok<AGROW>
    else
     names{end+1} = tbl{hit(1), 2}; %#ok<AGROW>
    end
   end
   varargout{1} = names;
  end

 case 'noisevalues'
  % values = PsychMetal('NoiseValues', w, rect, seed [, dist] [, chroma] ...
  %                     [, mean] [, spread])
  %
  % Recompute on the CPU exactly what DrawNoise draws, from the seed alone.
  % Store one integer per trial instead of a 21 MB array and reconstruct the
  % stimulus afterwards for reverse correlation.
  %
  % Returns [h x w] for mono or [h x w x 3] for colour, on the window's
  % ColorRange, clamped the same way the shader clamps. Row 1 is the top.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'NoiseValues requires the window handle from OpenWindow.');
  assert(numel(varargin) >= 2, 'NoiseValues needs a window and a rect.');
  assert(numel(varargin) <= 7, ...
      'NoiseValues takes w, rect, seed, distribution, chroma, mean and spread.');
  [nrect, nseed, nnormal, ncolour, nmean, nspread] = ...
      noiseArgs(varargin(2:end), S, 'NoiseValues');
  nw = round(nrect(3) - nrect(1));
  nh = round(nrect(4) - nrect(2));
  % Returned on the window's ColorRange, because these are the values that were
  % shown and the caller is working in those units.
  varargout = {PsychMetalCore('NoiseValues', nw, nh, nseed, ...
      double(nnormal), double(ncolour), nmean(1:3), nspread) * S.colorRange};

 case {'fillrect','framerect','filloval','frameoval','drawdots','drawlines', ...
       'drawgabor','drawnoise'}
  % Native Metal drawing primitives. All eight share one instanced-quad pipeline:
  % the fragment shader computes coverage from a shape kind, which is why the
  % curved ones antialias without tessellation.
  %
  % ORDERING is call order, shapes and textures alike: a texture drawn after a
  % rectangle appears on top of it.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'A PsychMetal drawing command requires the window handle from OpenWindow.');
  [kind, param, rect, color, extra, info] = buildShapes(lower(command), varargin, S);
  if ~isempty(kind)
   PsychMetalCore('AddShapes', kind, param, rect, color, extra);
  end
  if ~isempty(info)
   % DrawNoise returns the seed it used, so a caller that let one be drawn can
   % record it and reconstruct the frame later. The values matrix is returned
   % only if a second output is requested, which is the point: recomputing a
   % full frame is the expensive path this command exists to avoid, and it
   % should never happen because someone forgot a flag.
   varargout{1} = info.seed;
   if nargout >= 2
    varargout{2} = PsychMetalCore('NoiseValues', info.width, info.height, ...
        info.seed, double(info.normal), double(info.colour), ...
        info.mean, info.spread) * S.colorRange;
   end
  end

 case 'flip'
  % Encode the frame, commit it, and return the boundary it will reach.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''Flip'') requires the window handle returned by OpenWindow.');
  assert(numel(varargin) <= 2, ...
      'PsychMetal(''Flip'') supports PsychMetal(''Flip'', w [, when]).');
  haveWhen = numel(varargin) == 2 && ~isempty(varargin{2});
  if haveWhen
   assert(isnumeric(varargin{2}) && isreal(varargin{2}) && isscalar(varargin{2}), ...
       '''when'' must be a finite real scalar in GetSecs time.');
   when = double(varargin{2});
   assert(isfinite(when), '''when'' must be a finite real scalar in GetSecs time.');
   assert(when >= 0, '''when'' must be zero or a positive GetSecs timestamp.');
   haveWhen = when > 0;
  end
  tf = PsychMetalCore('Now');
  if haveWhen
   token = PsychMetalCore('Queue', when);
  else
   token = PsychMetalCore('Queue');
  end
  S.lastQueueMs = (PsychMetalCore('Now') - tf) * 1000;
  % raw(1) is the predicted presentation boundary, or the confirmed
  % presentedTime if the window was opened with waitForConfirm. Confirmations
  % otherwise arrive asynchronously and are kept for Diagnostic.
  if haveWhen
   raw = PsychMetalCore('WaitScheduled', token, when);
  else
   raw = PsychMetalCore('WaitScheduled', token);
  end
  flipReturn = PsychMetalCore('Now');
  S.lastFlipMs = (flipReturn - tf) * 1000;
  % Match Screen('Flip') output order for the supported basic mode:
  % [VBLTimestamp, StimulusOnsetTime, FlipTimestamp, Missed, Beampos].
  % VBL/onset are Apple's projected target. Beam position is unavailable.
  vbl = raw(1);
  % raw(5) is 1 when vbl is a confirmed presentedTime rather than a prediction.
  S.lastVblConfirmed = numel(raw) >= 5 && raw(5) == 1;
  missed = 0;
  if haveWhen
   % First-refresh-at-or-after semantics define the acceptable window as
   % [when, when + ifi). Negative is on time; positive is at least one
   % refresh late. raw(4) remains available as submissionMissed.
   missed = vbl - when - S.ifi;
  end
  if raw(2) ~= 0, missed = NaN; end
  % raw(6) is how many refreshes the PREVIOUS confirmed presentation missed its
  % prediction by. It is known here because presentedTime for the previous frame
  % arrives about half a millisecond after that frame was shown, well before
  % this call. Reporting it online is the point: a dropped frame is something an
  % experiment must be able to notice while it is running, not afterwards.
  %
  % Beampos is unavailable on this hardware and Screen returns -1 for it, so the
  % fifth output carries the slip instead of a constant. Zero means the previous
  % frame landed where it was predicted to.
  slipped = 0;
  if numel(raw) >= 6 && isfinite(raw(6)), slipped = raw(6); end
  S.lastSlipRefreshes = slipped;
  if slipped ~= 0
   S.slipCount = S.slipCount + 1;
   S.lastSlipFlip = S.flipCount;
  end
  S.flipCount = S.flipCount + 1;
  screenCompatible = [vbl, vbl, flipReturn, missed, slipped];
  varargout = num2cell(screenCompatible);

 case 'prepareflip'
  % Phase one of a two-phase flip: fence, acquire the drawable, encode, commit
  % and wait until scheduled. Everything of variable duration happens here, so
  % PresentNow has only the swap left to do. Direct mode only.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''PrepareFlip'') requires w.');
  token = PsychMetalCore('PrepareFlip');
  varargout = {token};

 case 'presentnow'
  % Phase two: issue the swap and nothing else. Returns the time the present
  % call was made and how long the call itself took, in milliseconds.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''PresentNow'') requires w.');
  out = PsychMetalCore('PresentNow');
  varargout = {out(1), out(2)};

 case 'setdisplaysync'
  % Runtime vsync toggle. Turning it off removes Apple's one-refresh latch
  % deadline and freezes the refresh grid at its last measured value, so the
  % caller can time swaps against the grid itself.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''SetDisplaySync'') requires w and a flag.');
  assert(isscalar(varargin{2}) && (islogical(varargin{2}) || isnumeric(varargin{2})), ...
      'The display-sync flag must be a logical scalar.');
  PsychMetalCore('SetDisplaySync', double(logical(varargin{2})));

 case 'gridanchor'
  % [anchorTime, period, sampleCount] for the learned refresh grid.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''GridAnchor'') requires w.');
  g = PsychMetalCore('GridAnchor');
  varargout = {[g(1), g(2), g(3)]};

 case 'nextphase'
  % Next time at a given fractional phase within the refresh cycle. Phase 0 is a
  % refresh boundary. Used to place the present call at a chosen phase, which
  % determines which boundary the frame reaches.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 3 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''NextPhase'') requires w, a time and a phase.');
  assert(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2}), ...
      'The time must be a finite GetSecs timestamp.');
  assert(isnumeric(varargin{3}) && isscalar(varargin{3}) && isfinite(varargin{3}), ...
      'The phase must be a finite number.');
  varargout = {PsychMetalCore('NextPhase', double(varargin{2}), double(varargin{3}))};

 case 'nextrefresh'
  % Next predicted refresh boundary at or after a given GetSecs time, from the
  % grid learned from confirmed presentations. Recompute each frame rather than
  % chaining off the previous target: chaining cannot resynchronise after a
  % frame lands late, so one miss cascades indefinitely.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''NextRefresh'') requires w and a time.');
  assert(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2}), ...
      'The time must be a finite GetSecs timestamp.');
  varargout = {PsychMetalCore('NextRefresh', double(varargin{2}))};

 case 'waittodraw'
  % Sleep until the latest moment at which drawing can start and still make
  % the requested refresh boundary. Sample input AFTER this returns, so it is
  % as fresh as possible when the frame reaches the display.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2 && numel(varargin) <= 3 && ...
      isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''WaitToDraw'') requires w and a target presentation time.');
  assert(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2}), ...
      'The target presentation time must be a finite GetSecs timestamp.');
  target = double(varargin{2});
  drawBudget = 0.004;
  if numel(varargin) == 3 && ~isempty(varargin{3})
   assert(isnumeric(varargin{3}) && isscalar(varargin{3}) && isfinite(varargin{3}) && ...
       varargin{3} >= 0, 'The drawing budget must be a nonnegative number of seconds.');
   drawBudget = double(varargin{3});
  end
  out = PsychMetalCore('WaitToDraw', target, drawBudget);
  % [time drawing may start, latency estimate used, computed deadline]
  varargout = {out(1), out(2), out(3)};

 case 'diagnostic'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''Diagnostic'') requires the window handle returned by OpenWindow.');
  % Diagnostics are outside the presentation loop, so wait for all delayed
  % presented handlers before returning the projected/actual comparison.
  [h, summary] = PsychMetalCore('Diagnostic');
  summary.lastQueueMs = S.lastQueueMs;
  summary.lastFlipMs = S.lastFlipMs;
  % Captured at OpenWindow. Reported here so diagnostics never have to ask
  % Screen after the window is closed, or at all.
  summary.colorRange = S.colorRange;
  summary.ptbLogicalRect = S.logicalRect;
  summary.ptbPhysicalRect = S.physicalRect;
  summary.ptbWaitForConfirm = S.waitForConfirm;
  summary.lastVblConfirmed = S.lastVblConfirmed;
  summary.backgroundColor = S.bgColor;
  % The running slip tally. Flip counts these on every call and deadline 0.3.1
  % they were tracked and then discarded, which is a waste of the one number an
  % experiment most wants at the end of a run: how many frames it dropped.
  % slipFlips counts flips whose PREVIOUS presentation missed its prediction;
  % lastSlipFlip is which flip that last happened on, so a run can tell a slip
  % during setup from one in the middle of a trial.
  summary.flips = S.flipCount;
  summary.slipFlips = S.slipCount;
  summary.lastSlipFlip = S.lastSlipFlip;
  summary.lastSlipRefreshes = S.lastSlipRefreshes;
  % No timebase conversion. GetSecs and CACurrentMediaTime are both
  % mach_absolute_time on the same divisor, measured to agree within 0.12 us
  % extrapolated to zero call cost, so every timestamp is already in the
  % caller's clock. Converting by a measured "skew" applied that measurement's
  % own call cost as a systematic bias. PsychMetalInventoryTest verifies that
  % the two clocks agree; nothing here calls Psychtoolbox to find out.
  actual = h(:,3);
  actualStatus = h(:,4); % 0 confirmed, 1 missing, 2 pending, 3 GPU error, 4 no drawable.
  actual(actualStatus ~= 0) = NaN;
  projected = h(:,2);
  % calibratedTargetLagFrames and observedTargetOffsetFrames were derived from
  % CAMetalDisplayLink's targetPresentationTimestamp and are gone with it. They
  % had already been reduced to reporting NaN in direct mode after a spell of
  % reporting 1.4e+07 frames of lag, which is what dividing an absolute clock by
  % a refresh interval looks like.
  targetLead = (projected - h(:,5)) / S.ifi;
  finiteLead = targetLead(isfinite(targetLead));
  if isempty(finiteLead), summary.projectionLeadRefreshes = NaN;
  else, summary.projectionLeadRefreshes = median(finiteLead); end
  fitRows = false(size(actual));
  candidate = find(actualStatus == 0 & isfinite(actual));
  if ~isempty(candidate)
   newRun = [true; diff(candidate) ~= 1 | diff(actual(candidate)) < 0.5*S.ifi | ...
       diff(actual(candidate)) > 1.5*S.ifi];
   runNumber = cumsum(newRun);
   runLength = accumarray(runNumber, 1);
   [~, longestRun] = max(runLength);
   fitRows(candidate(runNumber == longestRun)) = true;
  end
  fitTick = h(fitRows,1);
  fitTime = actual(fitRows);
  if numel(fitTick) >= 2 && max(fitTick) > min(fitTick)
   centeredTick = fitTick - mean(fitTick);
   centeredTime = fitTime - mean(fitTime);
   measuredIFI = sum(centeredTick .* centeredTime) / sum(centeredTick .^ 2);
   fitResidual = centeredTime - measuredIFI * centeredTick;
   summary.measuredRefreshIFI = measuredIFI;
   summary.measuredRefreshHz = 1 / measuredIFI;
   summary.measuredRefreshSamples = numel(fitTick);
   summary.refreshFitRmsUs = sqrt(mean(fitResidual .^ 2)) * 1e6;
   summary.refreshFitMaxAbsUs = max(abs(fitResidual)) * 1e6;
  else
   summary.measuredRefreshIFI = NaN;
   summary.measuredRefreshHz = NaN;
   summary.measuredRefreshSamples = numel(fitTick);
   summary.refreshFitRmsUs = NaN;
   summary.refreshFitMaxAbsUs = NaN;
  end
  if isempty(projected), frameID = zeros(0,1); else, frameID = round((projected-projected(1))/S.ifi); end
  gpuPassMs = nan(size(h,1), 1);
  validGpuTimes = h(:,9) > 0 & h(:,10) >= h(:,9);
  gpuPassMs(validGpuTimes) = (h(validGpuTimes,10)-h(validGpuTimes,9))*1000;
  % Columns, after the display-link fields were removed in 0.4.0:
  %   1 token  2 projected  3 presented  4 status  5 scheduledAt  6 callback
  %   7 commandStatus  8 requestedTime  9 gpuStart  10 gpuEnd
  %   11 presentRequest  12 presentCallMs  13 committedAt
  d = struct('flipNumber',h(:,1), ...
      'frameID',frameID, ...
      'projectedTimestamp',projected, ...
      'actualTimestamp',actual, ...
      'actualStatus',actualStatus, ...
      'targetErrorMs',(actual-projected)*1000, ...
      'scheduledAt',h(:,5), ...
      'projectionLeadMs',(projected-h(:,5))*1000, ...
      'confirmationCallbackTime',h(:,6), ...
      'confirmationDelayMs',(h(:,6)-actual)*1000, ...
      'commandStatus',h(:,7), ...
      'requestedTime',h(:,8), ...
      'scheduledAfterWhenMs',(projected-h(:,8))*1000, ...
      'presentRequestedTime',h(:,11), ...
      'presentCallMs',h(:,12), ...
      ... % measuredLeadMs is stamped when Flip STARTS, before nextDrawable, so
      ... % it includes drawable-pool backpressure. pipelineLeadMs is stamped at
      ... % commit, after that wait, and is the real submit-to-present figure.
      ... % drawableWaitMs is the difference: time spent waiting for a free
      ... % drawable, which is queueing, not pipeline.
      'measuredLeadMs',(actual-h(:,5))*1000, ...
      'committedTime',h(:,13), ...
      'pipelineLeadMs',(actual-h(:,13))*1000, ...
      'drawableWaitMs',(h(:,13)-h(:,5))*1000, ...
      'presentErrorMs',(actual-h(:,11))*1000, ...
      'gpuPassMs',gpuPassMs, ...
      'gpuStartTime',h(:,9), ...
      'gpuEndTime',h(:,10), ...
      'summary',summary);
  varargout={d};

 case 'close'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''Close'') requires the window handle returned by OpenWindow.');
  % Nothing else to tear down. Through 0.3.1 this also restored the caller's
  % SkipSyncTests preference and closed a Psychtoolbox host window and offscreen
  % buffer; there are none now, so Close releases the display, the Metal window
  % and the drawable pool and stops.
  try, PsychMetalCore('Close'); catch, end
  S = [];

 case 'version'
  assert(isempty(varargin), 'PsychMetal(''Version'') takes no arguments.');
  varargout = {'0.4.0'};

 otherwise
  error('PsychMetal:Command', ...
      'Unknown PsychMetal command ''%s''. Call PsychMetal for a command list.', command);
end
end

function printGeneralHelp
fprintf('\nPsychMetal - native Metal stimulus presentation on macOS, no OpenGL\n\n');
fprintf('Ordinary use:\n\n');
fprintf('  [w, rect, ifi] = PsychMetal(''OpenWindow'' [, screenNumber] ...\n');
fprintf('      [, backgroundColor] [, drawableCount] [, waitForConfirm] ...\n');
fprintf('      [, displaySync] [, captureDisplay]);\n');
fprintf('  PsychMetal(''BackgroundColor'', w, color);\n');
fprintf('  old   = PsychMetal(''ColorRange'', w [, range]);\n');
fprintf('  rect  = PsychMetal(''Rect'', w);\n');
fprintf('  [w,h] = PsychMetal(''WindowSize'', w);\n');
fprintf('  ifi   = PsychMetal(''GetFlipInterval'', w);\n');
fprintf('  t     = PsychMetal(''GetSecs'');\n');
fprintf('  t     = PsychMetal(''WaitSecs'', secs | ''UntilTime'', t);\n');
fprintf('  old   = PsychMetal(''Resolution'', screen [, width, height]);\n');
fprintf('  all   = PsychMetal(''Resolutions'', screen);\n');
fprintf('  texture = PsychMetal(''MakeTexture'', w, image);\n');
fprintf('  PsychMetal(''DrawTexture'', w, texture [, srcRect] [, dstRect] ...\n');
fprintf('      [, angle] [, tint]);\n');
fprintf('  PsychMetal(''CloseTexture'', w, texture);\n');
fprintf('  [vbl, onset, flipTime, missed, slipped] = PsychMetal(''Flip'', w [, when]);\n');
fprintf('  history = PsychMetal(''Diagnostic'', w);\n');
fprintf('  PsychMetal(''Close'', w);\n');
fprintf('  version = PsychMetal(''Version'');\n\n');
fprintf('Low-latency and diagnostic commands:\n\n');
fprintf('  t     = PsychMetal(''NextRefresh'', w, afterTime);\n');
fprintf('\nMeasurement instruments, not the stimulus path:\n\n');
fprintf('  t     = PsychMetal(''NextPhase'', w, afterTime, phase);\n');
fprintf('  [t,l] = PsychMetal(''WaitToDraw'', w, targetVbl [, drawBudget]);\n');
fprintf('  token = PsychMetal(''PrepareFlip'', w);\n');
fprintf('  [t,ms]= PsychMetal(''PresentNow'', w);\n');
fprintf('  g     = PsychMetal(''GridAnchor'', w);\n');
fprintf('  PsychMetal(''SetDisplaySync'', w, tf);\n');
fprintf('  PsychMetal(''PrefetchDrawable'', w, tf);\n\n');
fprintf('Experimental native Metal drawing (no OpenGL):\n\n');
fprintf('  PsychMetal(''FillRect'',   w [, color] [, rect]);\n');
fprintf('  PsychMetal(''FrameRect'',  w [, color] [, rect] [, penWidth]);\n');
fprintf('  PsychMetal(''FillOval'',   w [, color] [, rect]);\n');
fprintf('  PsychMetal(''FrameOval'',  w [, color] [, rect] [, penWidth]);\n');
fprintf('  PsychMetal(''DrawDots'',   w, xy [, size] [, color] [, center]);\n');
fprintf('  PsychMetal(''DrawLines'',  w, xy [, width] [, color] [, center]);\n');
fprintf(['  PsychMetal(''DrawGabor'',  w [, color] [, rect] [, sigma] [, freq]\n' ...
    '                              [, angle] [, phase]);\n']);
fprintf(['  seed = PsychMetal(''DrawNoise'', w, rect [, seed] [, dist] [, chroma]\n' ...
    '                              [, mean] [, spread]);\n']);
fprintf('  values = PsychMetal(''NoiseValues'', w, rect, seed, ...);\n\n');
fprintf('Input and cursor, in this window''s pixel coordinates:\n\n');
fprintf('  [x, y, buttons] = PsychMetal(''GetMouse'', w);\n');
fprintf('  PsychMetal(''HideCursor'');\n');
fprintf('  PsychMetal(''ShowCursor'');\n');
fprintf('  [down, secs, keyCode] = PsychMetal(''KbCheck'');\n');
fprintf('  secs  = PsychMetal(''KbWait'' [, untilRelease] [, pollInterval]);\n');
fprintf('  n     = PsychMetal(''KbName'', name | index | keyCode);\n\n');
fprintf('For detailed help append a question mark, e.g. PsychMetal(''Flip?'').\n');
fprintf('Start with PsychMetal(''Latency?'') for what this can and cannot do.\n\n');
end

function printCommandHelp(name)
switch lower(strtrim(name))
 case 'openwindow'
  fprintf('\nUsage:\n\n');
  fprintf(['[w, rect, ifi] = PsychMetal(''OpenWindow'' [, screenNumber] ...\n' ...
      '    [, backgroundColor] [, drawableCount] [, waitForConfirm] ...\n' ...
      '    [, displaySync] [, captureDisplay]);\n\n']);
  fprintf(['backgroundColor is the colour each frame is cleared to before any\n' ...
      'drawing, exactly as Screen(''OpenWindow'')''s second argument. 0 to 1 like\n' ...
      'every PsychMetal colour: on the window''s ColorRange, 255 at open.\n' ...
      'Scalar grey, RGB or RGBA. Default\n' ...
      'black. Change it later with PsychMetal(''BackgroundColor'', w, color).\n' ...
      'It costs nothing per frame: it is the render pass load action, not a draw,\n' ...
      'so it is cheaper than drawing a full-screen rectangle every frame.\n\n']);
  fprintf(['Opens a Metal presentation window covering the whole panel.\n' ...
      'screenNumber selects a display; the default is the last active one. OpenWindow creates\n' ...
      'a display-sized borderless window, captures the display and raises the window to\n' ...
      'CGShieldingWindowLevel. The\n' ...
      'stimulus therefore covers the whole panel including the strip beside a notch. This\n' ...
      'does not by itself prove the compositor is out of the presentation path. rect is the\n' ...
      'full-resolution pixel drawing rectangle\n' ...
      '(physical Retina resolution, not scaled logical points), and ifi is the nominal refresh\n' ...
      'interval in seconds. Timestamps are in CACurrentMediaTime, which is the same\n' ...
      'mach_absolute_time GetSecs reports, so no conversion is applied anywhere.\n' ...
      'drawableCount requests CAMetalLayer maximumDrawableCount (default 3; allowed 2 or 3).\n' ...
      'Two cannot sustain 60 Hz from a Metal-only loop; see the release notes.\n' ...
      'Diagnostic reports both requested values and their property readbacks; observed latency\n' ...
      'is measured separately from confirmed presentation timestamps.\n' ...
      'Before window creation, a non-Regular host activation policy is temporarily promoted\n' ...
      'to Regular and restored at Close. AppKit settles after fullscreen before display-link start.\n' ...
      'Only 8-bit monoscopic drawing and\n' ...
      'the basic presentation path are supported.\n\n']);
  fprintf('See also: Flip Diagnostic Close\n\n');

 case {'maketexture','drawtexture','closetexture'}
  fprintf('\nUsage:\n\n');
  fprintf('  texture = PsychMetal(''MakeTexture'', w, image);\n');
  fprintf('  PsychMetal(''DrawTexture'', w, texture [, srcRect] [, dstRect] ...\n');
  fprintf('      [, angle] [, tint]);\n');
  fprintf('  PsychMetal(''CloseTexture'', w, texture);\n\n');
  fprintf(['Native Metal textures. No OpenGL and no Screen texture handle.\n\n' ...
      'image is HxW grey, HxWx3 RGB or HxWx4 RGBA, on 0 to 1. Stored as\n' ...
      'RGBA16Float, which has an 11-bit mantissa - well beyond the 8-bit\n' ...
      'drawable - and is filterable in hardware. RGBA32Float is not reliably\n' ...
      'filterable on Apple GPUs and is markedly slower to sample.\n\n' ...
      'srcRect is in texture pixels and defaults to the whole texture. dstRect\n' ...
      'is in window pixels and defaults to the source size centred in the\n' ...
      'window. angle is in DEGREES about the destination centre, matching\n' ...
      'Screen. tint multiplies the sampled colour, so [1 1 1 0.5] draws at half\n' ...
      'alpha and a colour tints a greyscale image.\n\n' ...
      'Sampling is bilinear. Textures and shapes are drawn in CALL ORDER: a\n' ...
      'texture flushes the pending shape batch, so a shape drawn afterwards\n' ...
      'appears on top of it.\n\n' ...
      'Textures are freed by Close, so CloseTexture is only needed to reclaim\n' ...
      'a slot during a long session. There are 256 slots.\n\n' ...
      'NOT YET: mipmaps, wrap modes other than clamp, nearest-neighbour\n' ...
      'sampling, and Screen(''DrawTextures'') batching.\n\n']);
  fprintf('See also: OpenWindow FillRect Flip\n\n');

 case 'prefetchdrawable'
  % PsychMetal('PrefetchDrawable', w, tf)
  %
  % Acquire the next frame's drawable at the END of Flip instead of the start.
  %
  % nextDrawable blocks until the pool frees one, which with two drawables is a
  % full presentation away. Called at the start of Flip, that wait lands between
  % your input sample and the commit, so the sample is stale on arrival even
  % though the pipeline is optimal: 0.942 refreshes sample-to-commit against
  % 0.975 commit-to-photons. The wait cannot be removed, but it can be moved to
  % before the next sample rather than after it.
  %
  % Frame time and presentation rate are unchanged. Only staleness changes.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''PrefetchDrawable'') needs the window handle and a logical.');
  on = logical(varargin{2});
  % Two drawables cannot spare one: holding it leaves nothing to pipeline
  % against and the rate halves. Measured 30.000/s with 299 of 300 intervals
  % skipped, against 60.000 and none at three drawables.
  if on && S.drawableCount < 3
   warning('PsychMetal:PrefetchStarvesPool', ...
       ['Prefetching with %d drawables starves the pool and halves the ' ...
        'presentation rate. Open the window with 3 drawables instead.'], ...
       S.drawableCount);
  end
  PsychMetalCore('PrefetchDrawable', double(on));

 case {'colorrange','rect','windowsize','getflipinterval','getsecs','waitsecs', ...
       'resolution','resolutions'}
  fprintf('\nUsage:\n\n');
  fprintf('  oldRange = PsychMetal(''ColorRange'', w [, range]);\n');
  fprintf('  rect     = PsychMetal(''Rect'', w);\n');
  fprintf('  [w, h]   = PsychMetal(''WindowSize'', w);\n');
  fprintf('  ifi      = PsychMetal(''GetFlipInterval'', w);\n');
  fprintf('  t        = PsychMetal(''GetSecs'');\n');
  fprintf('  t        = PsychMetal(''WaitSecs'', secs | ''UntilTime'', t);\n');
  fprintf('  old      = PsychMetal(''Resolution'', screen [, width, height]);\n');
  fprintf('  all      = PsychMetal(''Resolutions'', screen);\n\n');
  fprintf(['The Screen queries that ported code calls without thinking, with the\n' ...
      'same names, arguments and return values.\n\n' ...
      'ColorRange is the maximum a colour component may take. It OPENS AT 255,\n' ...
      'exactly as Screen does, so a find-and-replace of Screen( for PsychMetal(\n' ...
      'renders the same stimulus rather than one at 1/255 brightness. Set it to 1\n' ...
      'for the convention PsychDefaultSetup(2) gives Screen. The shader always\n' ...
      'works in 0 to 1; this only says what the numbers you pass mean. Returns the\n' ...
      'previous range, so it can be set and restored around a block.\n\n' ...
      'Rect and WindowSize describe the window in PIXELS at native resolution. A\n' ...
      'PsychMetal window is always the whole panel, so Rect is [0 0 width height]\n' ...
      'and there is no windowed case to account for.\n\n' ...
      'GetFlipInterval differs from Screen''s in one way worth knowing: it is\n' ...
      'MEASURED rather than calibrated at open. Once thirty presentations have\n' ...
      'been confirmed it returns the least-squares fit to the refresh grid,\n' ...
      'repeatable to 0.043 ppm; before that, the display mode''s nominal rate.\n' ...
      'It therefore improves during a run rather than being fixed at startup.\n\n' ...
      'GetSecs returns CACurrentMediaTime, the clock MTLDrawable.presentedTime is\n' ...
      'in, with no conversion. Both it and Psychtoolbox''s GetSecs should be\n' ...
      'mach_absolute_time scaled by the same timebase, so they should be the same\n' ...
      'number, and measurement says they are: the residual scales with the call\n' ...
      'cost rather than staying put, extrapolating to 0.12 us at zero cost. No\n' ...
      'conversion is applied anywhere. PsychMetalInventoryTest verifies the two\n' ...
      'agree; opening a window does not, because doing so would load a\n' ...
      'Psychtoolbox mex and print its banner to check something that cannot\n' ...
      'change between one window and the next.\n\n' ...
      'Resolution and Resolutions manage the display mode, as Screen''s do, and\n' ...
      'return structs with width, height, pixelWidth, pixelHeight and hz. WIDTH\n' ...
      'AND HEIGHT ARE POINTS, as Screen''s are; on a Retina panel the pixel size\n' ...
      'is larger and it is the pixel size PsychMetal draws in, so both are given.\n' ...
      'Setting a mode requires the window closed: the drawable is sized at open,\n' ...
      'so changing the mode underneath a live window leaves every coordinate\n' ...
      'wrong with nothing on screen to say so.\n\n' ...
      'WaitSecs takes a duration or ''UntilTime'' and an absolute deadline, and\n' ...
      'returns the time on return. Use the absolute form in a stimulus loop: a\n' ...
      'relative wait restarts its own clock read each time, so a sequence of them\n' ...
      'drifts by the cost of asking. It sleeps on mach_wait_until then spins the\n' ...
      'last 500 us, because the kernel''s timer slack is hundreds of microseconds\n' ...
      'under load and a deadline missed by that much is a missed frame.\n\n']);
  fprintf('See also: OpenWindow BackgroundColor Flip\n\n');

 case 'backgroundcolor'
  fprintf('\nUsage:\n\n');
  fprintf('  PsychMetal(''BackgroundColor'', w, color);\n\n');
  fprintf(['Sets the colour each frame is cleared to before any drawing. Same\n' ...
      'thing OpenWindow''s second argument sets, changeable at any time, so a\n' ...
      'block design can change field luminance without reopening the window.\n\n' ...
      'Colours are on the window''s ColorRange: scalar grey, RGB or RGBA. Alpha is kept\n' ...
      'but the drawable is opaque, so an alpha below 1 is not a transparent\n' ...
      'window, it just darkens the clear.\n\n' ...
      'FREE. This is the render pass load action, not a full-screen draw, so it\n' ...
      'costs nothing per frame and is preferable to a background FillRect.\n\n' ...
      'This is where PsychMetal and Screen agree deliberately: Screen(''Flip'')\n' ...
      'clears to the colour given to Screen(''OpenWindow''), and so does this.\n\n']);
  fprintf('See also: OpenWindow FillRect Flip\n\n');

 case {'getmouse','hidecursor','showcursor'}
  fprintf('\nUsage:\n\n');
  fprintf('  [x, y, buttons] = PsychMetal(''GetMouse'', w);\n');
  fprintf('  PsychMetal(''HideCursor'');\n');
  fprintf('  PsychMetal(''ShowCursor'');\n\n');
  fprintf(['All three read or set the pointer through Core Graphics and AppKit\n' ...
      'directly. Psychtoolbox''s GetMouse and HideCursor are Screen(''GetMouseHelper'')\n' ...
      'and Screen(''HideCursorHelper''), so calling them loads the Screen mex and\n' ...
      'prints its startup banner; these are what keep a PsychMetal session free of\n' ...
      'Psychtoolbox output.\n\n' ...
      'GetMouse returns PIXELS on the presentation display, the same coordinates\n' ...
      'every drawing command takes, so a position can be used as a rect corner\n' ...
      'without conversion. Psychtoolbox reports points with the origin at the\n' ...
      'bottom left of the main display; on a display whose backing scale is not 1\n' ...
      'a raw point position tracks at the wrong speed.\n\n' ...
      'HideCursor and ShowCursor take no window handle: the cursor belongs to the\n' ...
      'display, and a script that fails before OpenWindow still has to give it\n' ...
      'back. They are display-scoped rather than [NSCursor hide], which applies\n' ...
      'only while the pointer is over one of this application''s own windows.\n\n']);
  fprintf('See also: OpenWindow Flip\n\n');

 case {'fillrect','framerect','filloval','frameoval','drawdots','drawlines', ...
       'drawgabor','drawnoise','noisevalues'}
  fprintf('\nUsage:\n\n');
  fprintf('  PsychMetal(''FillRect'',   w [, color] [, rect]);\n');
  fprintf('  PsychMetal(''FrameRect'',  w [, color] [, rect] [, penWidth]);\n');
  fprintf('  PsychMetal(''FillOval'',   w [, color] [, rect]);\n');
  fprintf('  PsychMetal(''FrameOval'',  w [, color] [, rect] [, penWidth]);\n');
  fprintf('  PsychMetal(''DrawDots'',   w, xy [, size] [, color] [, center]);\n');
  fprintf('  PsychMetal(''DrawLines'',  w, xy [, width] [, color] [, center]);\n');
fprintf(['  PsychMetal(''DrawGabor'',  w [, color] [, rect] [, sigma] [, freq]\n' ...
    '                              [, angle] [, phase]);\n']);
fprintf(['  seed = PsychMetal(''DrawNoise'', w, rect [, seed] [, dist] [, chroma]\n' ...
    '                              [, mean] [, spread]);\n']);
fprintf('  values = PsychMetal(''NoiseValues'', w, rect, seed, ...);\n\n');
fprintf('Input, in this window''s pixel coordinates:\n\n');
fprintf('  [x, y, buttons] = PsychMetal(''GetMouse'', w);\n\n');
  fprintf(['Drawing primitives implemented directly in Metal, with no OpenGL.\n' ...
      'Argument order follows the matching Screen commands.\n\n' ...
      'Colours are on the window''s ColorRange, which opens at 255 exactly as\n' ...
      'Screen''s does. PsychMetal(''ColorRange'', w, 1) switches to 0-1. A value\n' ...
      'above the range warns and clamps.\n\n' ...
      'Give one colour for everything, or one per shape as a 3xN or 4xN matrix.\n' ...
      'rect may be 4xN to draw several at once. Dots take a 2xN position matrix;\n' ...
      'lines take 2xN endpoints in consecutive pairs.\n\n' ...
      'DrawGabor is a sinusoidal carrier under a Gaussian envelope, both computed\n' ...
      'in the shader. sigma is a fraction of the half-size (default 0.35); freq is\n' ...
      'in cycles per pixel as Screen(''CreateProceduralGabor'') uses; angle and\n' ...
      'phase are degrees. AT FREQUENCY 0 IT IS EXACTLY A GAUSSIAN: the carrier\n' ...
      'term is identically 1, not an approximation of one.\n\n' ...
      'DrawNoise is full-field white noise, one independent value per pixel,\n' ...
      'computed in the shader. NOTHING IS UPLOADED: a pixel''s value is a hash of\n' ...
      'its position and the seed. That is not an optimisation but what makes it\n' ...
      'possible: generating a full screen on the CPU measures 7.6 ms mono uniform,\n' ...
      '15.9 ms colour and 50.3 ms normal, plus 21.5 MB of upload per frame.\n\n' ...
      'THE SEED IS NORMALLY AN OUTPUT. Leave it out and one is drawn and returned;\n' ...
      'record it and the frame can be rebuilt exactly from four bytes. Ask for a\n' ...
      'second output and the values come back too, which recomputes the frame on\n' ...
      'the CPU and is therefore never done by accident.\n\n' ...
      '  seed    integer 0 to 16777215, or [] to draw one.\n' ...
      '  dist    ''uniform'' (default) or ''normal''.\n' ...
      '  chroma  ''mono'' (default) or ''colour'' for an independent value per\n' ...
      '          channel from the same distribution.\n' ...
      '  mean    centre, default mid-range.\n' ...
      '  spread  uniform spans mean +/- spread; normal uses it as the SD. On\n' ...
      '          the window''s ColorRange, like the mean: at 255, mean 128 with\n' ...
      '          spread 128 is black to white. Default is half the range.\n\n' ...
      'The defaults are uniform, monochrome, full spread: every pixel independently\n' ...
      'and uniformly between black and white.\n\n' ...
      'NoiseValues recomputes the same numbers from a seed without drawing, as\n' ...
      '[h x w] or [h x w x 3] on the window''s ColorRange.\n\n' ...
      'All eight share one instanced-quad pipeline and are submitted as a single\n' ...
      'batch per frame, so thousands of dots cost one draw call. The curved shapes\n' ...
      'antialias analytically in the fragment shader rather than by tessellation.\n\n' ...
      'ORDERING is call order: a texture drawn after a rectangle appears on top.\n\n' ...
      'NOT YET IMPLEMENTED: arcs, polygons, text, line stipple, the matrix stack,\n' ...
      'and Screen(''BlendFunction''). Blending is fixed at source\n' ...
      'alpha over destination. See docs/07_opengl_inventory.md.\n\n']);
  fprintf('See also: OpenWindow Flip\n\n');


 case 'flip'
  fprintf('\nUsage:\n\n');
  fprintf('[VBLTimestamp StimulusOnsetTime FlipTimestamp Missed Slipped] = ...\n');
  fprintf('    PsychMetal(''Flip'', w [, when]);\n\n');
  fprintf(['Presents the frame drawn since the last Flip.\n\n' ...
      'WITHOUT when the frame is presented as soon as the pipeline allows, about\n' ...
      'two refresh boundaries after it is committed.\n\n' ...
      'WITH when the frame is handed to Apple with a target time and the system\n' ...
      'places it on the first boundary at or after that time. PsychMetal does no\n' ...
      'scheduling of its own: the frame is committed immediately and\n' ...
      'presentDrawable:atTime: decides. Measured 0 to 1%% of frames late across\n' ...
      'requested cadences of 1 to 12 refreshes.\n\n' ...
      'Earlier versions computed the commit moment from a fitted refresh grid\n' ...
      'instead. That put a request exactly four refreshes ahead a full refresh\n' ...
      'late on 99%% of frames; docs/05_results.md section 9e is the post-mortem.\n' ...
      'The standard Psychtoolbox idiom works unchanged:\n\n' ...
      '  vbl = PsychMetal(''Flip'', w, vbl + (waitframes - 0.5) * ifi);\n\n' ...
      'RETURNS\n\n' ...
      '  VBLTimestamp, StimulusOnsetTime  predicted presentation time, from a\n' ...
      '      refresh grid fitted to confirmed presentations. Exact to about 16 ns\n' ...
      '      in a continuously running loop. The first flip after an idle period\n' ...
      '      is probably a refresh late; see Known issues in README.md.\n' ...
      '  FlipTimestamp                    when Flip returned.\n' ...
      '  Missed                           with when, VBLTimestamp - when - ifi.\n' ...
      '      Negative means the frame landed in the first refresh after when,\n' ...
      '      positive means at least a refresh late, NaN means scheduling\n' ...
      '      failed. Screen''s sign convention, not its calculation. Without\n' ...
      '      when it is zero.\n' ...
      '  Slipped                          NOT Screen''s Beampos. Scanline queries\n' ...
      '      are unavailable on this hardware and Screen returns a constant -1\n' ...
      '      there, so the slot reports how many refreshes the PREVIOUS confirmed\n' ...
      '      presentation missed its prediction by. Zero means it landed where\n' ...
      '      predicted. presentedTime for a frame arrives about half a\n' ...
      '      millisecond after it is shown, so this is known in time to act on:\n\n' ...
      '        [vbl, ~, ~, missed, slipped] = PsychMetal(''Flip'', w);\n' ...
      '        if slipped, warning(''dropped %%d refreshes'', slipped); end\n\n' ...
      'CLEARING. Each frame begins cleared to the window''s background colour,\n' ...
      'as Screen(''Flip'') does. Set it at OpenWindow or with BackgroundColor.\n\n' ...
      'dontclear, dontsync, multiflip, stereo, HDR and DataPixx modes are not\n' ...
      'implemented. Use Diagnostic afterwards to compare every prediction with\n' ...
      'the confirmed presentedTime that followed it.\n\n']);
  fprintf('See also: OpenWindow Diagnostic Latency Close\n\n');

 case 'diagnostic'
  fprintf('\nUsage:\n\n');
  fprintf('history = PsychMetal(''Diagnostic'', w);\n\n');
  fprintf(['Waits outside the animation loop for outstanding Metal presented handlers, then returns\n' ...
      'one row per Flip. Main fields are:\n\n' ...
      '  projectedTimestamp       Target time returned by Flip.\n' ...
      '  actualTimestamp          Later confirmed presentedTime, or NaN.\n' ...
      '  actualStatus             0=confirmed, 1=zero time, 2=pending, 3=GPU error, 4=no drawable.\n' ...
      '  targetErrorMs            actual minus projected time in milliseconds.\n' ...
      '  requestedTime            Optional when value, or NaN.\n' ...
      '  scheduledAfterWhenMs     Projected onset after the when threshold.\n' ...
      '  projectionLeadMs         projected time minus scheduling time.\n' ...
      '  scheduledAt              Time Flip started, before nextDrawable.\n' ...
      '  committedTime            Time the command buffer was committed.\n' ...
      '  pipelineLeadMs           presented minus committed: the real submit-to-present.\n' ...
      '  drawableWaitMs           committed minus scheduledAt: queueing, not pipeline.\n' ...
      '  confirmationCallbackTime Time the presented handler ran.\n' ...
      '  confirmationDelayMs      callback time minus actual presentedTime.\n' ...
      '  gpuPassMs                GPU duration of the frame''s render pass.\n' ...
      '  frameID, flipNumber, commandStatus, summary.\n' ...
      '  summary.projectionLeadRefreshes is the projected time minus the time Flip\n' ...
      '    started, in refresh intervals.\n' ...
      '  summary.measuredRefreshHz/IFI regress the longest uninterrupted confirmed frame run.\n' ...
      '  summary.refreshFitRmsUs and refreshFitMaxAbsUs describe that linear fit.\n' ...
      '  summary.activationPolicyBefore/After test regular foreground-app promotion (0=Regular).\n' ...
      '  summary.macOSVersion, processName, and mach timebase fields identify the host.\n' ...
      '  summary.displayCaptured reports whether CGDisplayCapture succeeded.\n' ...
      '  summary.windowFrame, viewBounds, layerFrame, screenFrame, screenVisibleFrame,\n' ...
      '    screenSafeAreaInsets and cgDisplayBounds give the whole geometry chain.\n' ...
      '  summary.modePixelWidth below nativePixelWidth means a scaled display mode.\n' ...
      '  summary.flips and slipFlips are the run tally: how many flips were made and\n' ...
      '  how many reported the previous presentation missing its prediction. lastSlipFlip\n' ...
      '  and lastSlipRefreshes locate and size the most recent one, which separates a\n' ...
      '  slip during startup from one in the middle of a trial.\n' ...
      '  summary.backgroundColor is the frame clear colour, as RGBA on 0 to 1.\n\n' ...
      'The notes above cover the fields worth explaining, not all of them: the\n' ...
      'summary carries about 85, most named for exactly what they hold (renderWidth,\n' ...
      'drawableHeight, machTimebaseHz). List them with fieldnames(d.summary), and\n' ...
      'save the whole struct with a run: it records the window geometry, display\n' ...
      'mode, timebase and configuration that produced the data.\n\n' ...
      'Diagnostic may pause for about the outstanding compositor pipeline depth. It should be\n' ...
      'called after timing-critical presentation, before Close.\n\n']);
  fprintf('See also: OpenWindow Flip Close\n\n');

 case 'close'
  fprintf('\nUsage:\n\n');
  fprintf('PsychMetal(''Close'', w);\n\n');
  fprintf(['Releases the captured display, closes the Metal window and frees the drawable\n' ...
      'pool. Call Diagnostic first if projected-versus-confirmed history is required:\n' ...
      'the history is owned by the window and goes with it.\n\n']);
  fprintf('See also: OpenWindow Flip Diagnostic\n\n');

 case 'waittodraw'
  fprintf('\nUsage:\n\n');
  fprintf('[t, lead] = PsychMetal(''WaitToDraw'', w, targetVbl [, drawBudget]);\n\n');
  fprintf(['Sleeps until the latest moment at which drawing can begin and still reach\n' ...
      'targetVbl, using a running estimate of submit-to-present latency measured from\n' ...
      'confirmed presentations. Sample the mouse, keyboard or eye tracker AFTER this\n' ...
      'returns so the reading is as fresh as possible when the frame is displayed:\n\n' ...
      '  vbl = PsychMetal(''Flip'', w);\n' ...
      '  target = vbl + ifi;\n' ...
      '  PsychMetal(''WaitToDraw'', w, target, 0.002);\n' ...
      '  [x, y] = GetMouse;\n' ...
      '  Screen(''FillOval'', w, 255, CenterRectOnPoint([0 0 40 40], x, y));\n' ...
      '  vbl = PsychMetal(''Flip'', w, target);\n\n' ...
      'drawBudget is how long your drawing takes, in seconds; it defaults to 0.002.\n' ...
      'Too small and the frame misses its boundary; too large and input is sampled\n' ...
      'earlier than necessary. t is when drawing may start and lead is the latency\n' ...
      'estimate used, both useful for tuning. Reported as summary.leadEstimateMs.\n\n']);
  fprintf('See also: Flip Diagnostic\n\n');

 case 'latency'
  fprintf(['\nMEASURED TIMING ON macOS 27.0 beta, Apple silicon, 60 Hz display\n\n' ...
      'Presentation is frame-accurate. One presentation per refresh, no skipped\n' ...
      'refreshes, confirmed intervals stable to about 84 ns, and the timestamp Flip\n' ...
      'returns is accurate to roughly 25 microseconds.\n\n' ...
      'Latency from submission to presentation is a separate matter and trades\n' ...
      'against frame rate:\n\n' ...
      '  continuous 60 Hz, ordinary loop        2.7 refreshes  (45 ms)\n' ...
      '  continuous 60 Hz, phase-targeted       2.4 refreshes  (40 ms)\n' ...
      '  one frame in flight (waitForConfirm)   1.7 refreshes  (28 ms), 30 Hz\n' ...
      '  drained queue, present at phase 0.625  1.0 refreshes  (17 ms)\n\n' ...
      'OPEN LOOP - pre-planned stimulus sequences.\n' ...
      'Use the defaults. Latency does not matter because presentation time is known\n' ...
      'in advance; place frames with when and read the returned timestamps. This is\n' ...
      'the supported path.\n\n' ...
      'CLOSED LOOP - response-contingent displays.\n' ...
      'Latency is the cost function, so pick a point on the table above. The usual\n' ...
      'best design is neither extreme: run at 60 Hz normally, and when the\n' ...
      'triggering event arrives let the queue drain and present the responding\n' ...
      'frame at phase 0.625 with PrepareFlip and PresentNow. Smooth motion\n' ...
      'throughout, about one refresh on the frame that matters.\n\n' ...
      'Every figure above derives from MTLDrawable.presentedTime. The offset\n' ...
      'between that timestamp and light emission is unmeasured and needs a\n' ...
      'photodiode. See docs/05_results.md.\n\n']);
  fprintf('See also: Flip PrepareFlip PresentNow NextPhase Diagnostic\n\n');

 case 'nextrefresh'
  fprintf('\nUsage:\n\nt = PsychMetal(''NextRefresh'', w, afterTime);\n\n');
  fprintf(['Next predicted refresh boundary at or after afterTime, in GetSecs time,\n' ...
      'from the grid learned from confirmed presentations. Recompute it every frame\n' ...
      'rather than chaining off the previous target: chaining cannot resynchronise\n' ...
      'after a late frame, so a single miss cascades.\n\n']);
  fprintf('See also: NextPhase GridAnchor Flip\n\n');

 case 'nextphase'
  fprintf('\nUsage:\n\nt = PsychMetal(''NextPhase'', w, afterTime, phase);\n\n');
  fprintf(['Next time at a given fractional phase within the refresh cycle, where\n' ...
      'phase 0 is a refresh boundary.\n\n' ...
      'A present call issued during refresh cycle N is displayed at the boundary\n' ...
      'starting cycle N+2, at every phase. The floor is 1.035 refresh intervals,\n' ...
      'so the boundary immediately after the call is never reachable, and buffer\n' ...
      'count does not change this. Phase therefore does not choose the boundary;\n' ...
      'it only controls how much of the wait is spent before the call rather than\n' ...
      'after it.\n\n' ...
      'MEASUREMENT INSTRUMENT, not a stimulus path. The 0.625 figure comes from\n' ...
      'an isolated measurement with an EMPTY queue. A loop running continuously\n' ...
      'at 60 Hz keeps about 2.4 frames outstanding and a new present goes behind\n' ...
      'them, so phase is then worth roughly 4 ms rather than the 27 ms the\n' ...
      'isolated number suggests. No closed-loop paradigm has been measured end\n' ...
      'to end. See docs/05_results.md section 7 and pick from the table there.\n' ...
      'PsychMetalLatchTest and PsychMetalDrawableCompare measure this directly.\n\n']);
  fprintf('See also: PrepareFlip PresentNow Latency\n\n');

 case 'prepareflip'
  fprintf('\nUsage:\n\ntoken = PsychMetal(''PrepareFlip'', w);\n\n');
  fprintf(['Phase one of a two-phase flip: drawable acquisition, encoding, commit\n' ...
      'and waitUntilScheduled. Everything of variable duration happens here,\n' ...
      'leaving PresentNow with only the swap to issue. Direct mode only.\n\n' ...
      'MEASUREMENT INSTRUMENT. Use Flip for stimulus presentation; this pair\n' ...
      'exists to time the two halves separately.\n\n' ...
      '  PsychMetal(''PrepareFlip'', w);\n' ...
      '  PsychMetal(''WaitSecs'', ''UntilTime'', ...\n' ...
      '      PsychMetal(''NextPhase'', w, PsychMetal(''GetSecs''), 0.625));\n' ...
      '  vbl = PsychMetal(''PresentNow'', w);\n\n']);
  fprintf('See also: PresentNow NextPhase Latency\n\n');

 case 'presentnow'
  fprintf('\nUsage:\n\n[t, ms] = PsychMetal(''PresentNow'', w);\n\n');
  fprintf(['Phase two: issues the swap and nothing else. Returns the time the call\n' ...
      'was made and how long the call took, in milliseconds. The call is punctual,\n' ...
      'about 40 microseconds median and 125 microseconds worst case, so the moment\n' ...
      'you make it determines which refresh boundary the frame reaches.\n\n' ...
      'MEASUREMENT INSTRUMENT, paired with PrepareFlip. Use Flip normally.\n\n']);
  fprintf('See also: PrepareFlip NextPhase Latency\n\n');

 case 'gridanchor'
  fprintf('\nUsage:\n\ng = PsychMetal(''GridAnchor'', w);\n\n');
  fprintf(['Returns [anchorTime, period, sampleCount] for the refresh grid learned\n' ...
      'from confirmed presentations. anchorTime is the most recent confirmed\n' ...
      'presentation in GetSecs time. Measured intervals are stable to a couple of\n' ...
      'mach timebase ticks, so one anchor plus the period predicts later boundaries\n' ...
      'to well under a microsecond. summary.measuredRefreshHz reports 1/period.\n\n']);
  fprintf('See also: NextRefresh NextPhase\n\n');

 case 'setdisplaysync'
  fprintf('\nUsage:\n\nPsychMetal(''SetDisplaySync'', w, tf);\n\n');
  fprintf(['DIAGNOSTIC ONLY. Turns vsync off or on at runtime. With it off the frame\n' ...
      'reaches the display about 2.6 ms after GPU completion instead of 27.6 ms,\n' ...
      'but swaps land mid-scan and tear. Turning it off also freezes the refresh\n' ...
      'grid, because presentedTime then marks the swap rather than a boundary.\n\n' ...
      'Software vsync built on this does not hold: the present call is punctual to\n' ...
      '125 microseconds, but the swap lands within a 1.5 to 2.5 ms window, far\n' ...
      'wider than the vertical blank. Not usable for stimulus presentation.\n\n']);
  fprintf('See also: Latency Diagnostic\n\n');

 case 'version'
  fprintf('\nUsage:\n\nversion = PsychMetal(''Version'');\n\n');
  fprintf('Returns the PsychMetal release version as a character vector.\n\n');

 case {'kbcheck','kbwait','kbname'}
  fprintf('\nUsage:\n\n');
  fprintf('[keyIsDown, secs, keyCode] = PsychMetal(''KbCheck'');\n');
  fprintf('secs  = PsychMetal(''KbWait'' [, untilRelease] [, pollInterval]);\n');
  fprintf('index = PsychMetal(''KbName'', name);\n');
  fprintf('name  = PsychMetal(''KbName'', index);\n');
  fprintf('names = PsychMetal(''KbName'', keyCode);\n\n');
  fprintf(['Which keys are down at the moment of the call. keyCode is 1x256\n' ...
      'logical indexed by HID usage code, which is what Psychtoolbox''s\n' ...
      'KbCheck returns and what KbName''s numbers mean, so keyCode(41) is\n' ...
      'Escape here exactly as it is there.\n\n']);
  fprintf('WHAT THIS IS, AND WHAT IT IS NOT:\n\n');
  fprintf(['macOS merges every attached keyboard into one system-wide state\n' ...
      'before PsychMetal can see it. Built-in, USB and Bluetooth arrive\n' ...
      'identical and unlabelled, which is why this needs no device\n' ...
      'enumeration and no per-device quirk handling. It is also the limit:\n' ...
      'there is no deviceNumber argument, nothing here can say WHICH\n' ...
      'keyboard a press came from, and a response box that does not present\n' ...
      'itself as a keyboard is invisible to it. Those are PsychHID''s job.\n\n']);
  fprintf('TIMING. This is not a reaction time instrument.\n\n');
  fprintf(['secs is when the POLL happened, not when the key went down, so\n' ...
      'the resolution of an RT measured this way is your polling interval:\n' ...
      'one refresh, if you poll once a frame. A Bluetooth keyboard adds tens\n' ...
      'of milliseconds of its own latency and jitter, invisibly. Use this to\n' ...
      'advance a trial. Use PsychHID, or hardware with a known latency, to\n' ...
      'measure one.\n\n']);
  fprintf(['SECURE INPUT. While any process holds secure event input - a\n' ...
      'password field, a password manager - every key reads UP and no error\n' ...
      'is raised. PsychMetal detects it and warns once per session, because\n' ...
      'the alternative is an experiment that quietly records no responses.\n\n']);
  fprintf(['If every key reads up and NO secure-input warning appears, check\n' ...
      'Input Monitoring in System Settings > Privacy & Security for whatever\n' ...
      'is hosting this session (Octave, MATLAB, Terminal). Whether macOS\n' ...
      'gates this read behind that permission has not been established here;\n' ...
      'if it turns out to, it fails the same silent way and that is where to\n' ...
      'look.\n\n']);

 otherwise
  fprintf('\nNo PsychMetal help topic named ''%s'' exists.\n', name);
  % EVERY command name is a topic, so listing them here would be a second copy
  % of the command list that goes stale silently — as it had, advertising 15
  % topics while 41 existed. Point at the list that cannot drift instead.
  fprintf(['Every command name is a help topic, plus ''Latency?'' for what this\n' ...
      'can and cannot do. Call PsychMetal with no arguments for the command\n' ...
      'list.\n\n']);
end
end

function [kind, param, rect, color, extra, info] = buildShapes(cmd, args, S)
% Turn one Screen-style drawing call into instance arrays for AddShapes.
% kind and param are 1xN, rect, color and extra are 4xN. Shape kinds must match
% the enum in PsychMetalCore.mm: 0 fill rect, 1 frame rect, 2 fill oval,
% 3 frame oval, 4 dot, 5 line, 6 Gabor, 7 noise.
%
% extra carries the three per-shape parameters that do not fit in param: the
% Gabor's carrier frequency, orientation and phase, or the noise seed and its
% two distribution flags. It is all zeros for every other shape, which is also
% what makes a zero-frequency Gabor a plain Gaussian.
kind = []; param = []; rect = zeros(4,0); color = zeros(4,0); extra = zeros(4,0);
% Only DrawNoise fills this: it is the one drawing command with something to
% report back, namely which seed was used.
info = [];
switch cmd
 case 'drawnoise'
  % seed = PsychMetal('DrawNoise', w, rect [, seed] [, dist] [, chroma] ...
  %                   [, mean] [, spread])
  % [seed, values] = PsychMetal('DrawNoise', ...)
  %
  % Full-field white noise, one independent value per pixel, computed in the
  % fragment shader. NOTHING IS UPLOADED: the value at a pixel is a hash of its
  % position and the seed, so there is no image to build and no bandwidth cost.
  %
  % That is not an optimisation, it is what makes it possible at all. Generating
  % a full screen on the CPU measures 7.6 ms for mono uniform, 15.9 ms for
  % colour and 50.3 ms for normal via Box-Muller, plus 21.5 MB of upload per
  % frame. Normal-distributed full-frame noise does not fit in a refresh from
  % the CPU at any plausible speed.
  %
  % THE SEED IS NORMALLY AN OUTPUT. Leave it out and one is drawn from the
  % caller's RNG and returned; record that integer and the frame can be
  % reconstructed exactly, later, from four bytes rather than a 21 MB array.
  % Pass a seed to redraw a frame you already have.
  %
  % THE VALUES ARE RETURNED ONLY IF ASKED FOR. Requesting a second output
  % recomputes the frame on the CPU, which is the expensive path this command
  % exists to avoid, so it is deliberately something you have to ask for and
  % cannot do by accident.
  %
  %   seed     integer 0 to 16777215, or [] to draw one. Same seed, same
  %            pixels, every time and on every machine. Advance it per frame
  %            for dynamic noise.
  %   dist     'uniform' (default) or 'normal'.
  %   chroma   'mono' (default), one value per pixel, or 'colour' for an
  %            independent value per channel from the same distribution.
  %   mean     centre of the distribution, default mid-range.
  %   spread   uniform spans mean +/- spread; normal uses it as the standard
  %            deviation. ON THE WINDOW'S ColorRange, like the mean: at 255,
  %            mean 128 with spread 128 runs black to white. Default is half
  %            the range. The two are added in the shader, so a spread in
  %            different units from its mean is silently the wrong contrast.
  %
  % The defaults are therefore uniform, monochrome, full spread: every pixel
  % independently and uniformly between black and white.
  %
  % Values are clamped to the range after scaling, so a wide normal spread
  % clips rather than wrapping. PsychMetal('NoiseValues', ...) recomputes the
  % same numbers from a seed without drawing.
  assert(numel(args) >= 2, 'DrawNoise needs a window and a rect.');
  assert(numel(args) <= 7, ...
      'DrawNoise takes w, rect, seed, distribution, chroma, mean and spread.');
  [r, seed, normalFlag, colourFlag, meanRGBA, spread] = ...
      noiseArgs(args(2:end), S, 'DrawNoise');
  kind = 7;
  param = spread;
  rect = r(:);
  color = meanRGBA(:);
  extra = [seed; double(normalFlag); double(colourFlag); 0];
  % Handed back so the dispatch can return the seed, and recompute the values
  % if the caller asked for them.
  info = struct('seed', seed, 'normal', normalFlag, 'colour', colourFlag, ...
      'mean', meanRGBA(1:3), 'spread', spread, ...
      'width', round(r(3) - r(1)), 'height', round(r(4) - r(2)));

 case 'drawgabor'
  % PsychMetal('DrawGabor', w [, color] [, rect] [, sigma] [, freq] [, angle] [, phase])
  %
  % A sinusoidal carrier under a Gaussian envelope, both evaluated in the
  % fragment shader rather than uploaded as a texture.
  %
  %   sigma   envelope width as a fraction of the half-size, default 0.35, so
  %           the rect should be about six sigma across for the tails to fade
  %           out. Resolution independent: scale the rect and the envelope
  %           scales with it.
  %   freq    carrier spatial frequency in CYCLES PER PIXEL, default 0. This
  %           follows Screen('CreateProceduralGabor') rather than sigma's
  %           normalised convention, so frequencies port across unchanged. A
  %           200-pixel patch at 0.02 shows four cycles.
  %   angle   carrier orientation in degrees, default 0. Zero is a vertical
  %           grating; positive rotates counterclockwise on screen.
  %   phase   carrier phase in degrees, default 0. Advance it per frame for a
  %           drifting grating, or drive it 0/180 for counterphase.
  %
  % FREQUENCY 0 GIVES EXACTLY A GAUSSIAN. The carrier term is identically 1, so
  % omitting the frequency is not an approximation of a Gaussian envelope, it is
  % the same shape and the same code path.
  %
  % The envelope sets ALPHA and the carrier scales RGB, so a full-contrast Gabor
  % runs from the colour given down to black and fades into the background at
  % its edges. Amplitude and sign come from the colour: white for a bright
  % patch, black for a dark one.
  spec = []; if numel(args) >= 2, spec = args{2}; end
  r = S.physicalRect;
  if numel(args) >= 3 && ~isempty(args{3}), r = double(args{3}); end
  sigma = 0.35;
  if numel(args) >= 4 && ~isempty(args{4})
   sigma = double(args{4});
   assert(isscalar(sigma) && isfinite(sigma) && sigma > 0, 'sigma must be positive.');
  end
  freq = 0;
  if numel(args) >= 5 && ~isempty(args{5})
   freq = double(args{5});
   assert(isscalar(freq) && isfinite(freq) && freq >= 0, ...
       'Spatial frequency must be zero or positive, in cycles per pixel.');
  end
  angle = 0;
  if numel(args) >= 6 && ~isempty(args{6})
   angle = double(args{6});
   assert(isscalar(angle) && isfinite(angle), 'Orientation must be a scalar in degrees.');
  end
  phase = 0;
  if numel(args) >= 7 && ~isempty(args{7})
   phase = double(args{7});
   assert(isscalar(phase) && isfinite(phase), 'Phase must be a scalar in degrees.');
  end
  assert(numel(args) <= 7, ...
      'DrawGabor takes w, colour, rect, sigma, frequency, orientation and phase.');
  if isvector(r), r = r(:); end
  assert(size(r,1) == 4 && all(isfinite(r(:))), ...
      'The rectangle must be [left top right bottom], or 4xN for several.');
  n = size(r,2);
  kind = repmat(6, 1, n);
  param = repmat(sigma, 1, n);
  rect = [min(r(1,:),r(3,:)); min(r(2,:),r(4,:)); ...
          max(r(1,:),r(3,:)); max(r(2,:),r(4,:))];
  color = expandColors(spec, n, S.colorRange);
  % Degrees at the interface, radians in the shader. Converting here keeps the
  % trigonometry out of the per-fragment path and off the GPU entirely.
  extra = repmat([freq; angle * pi / 180; phase * pi / 180; 0], 1, n);

 case {'fillrect','framerect','filloval','frameoval'}
  % PsychMetal(cmd, w [, color] [, rect] [, penWidth])
  spec = []; if numel(args) >= 2, spec = args{2}; end
  r = S.physicalRect;
  if numel(args) >= 3 && ~isempty(args{3}), r = double(args{3}); end
  pen = 1;
  if numel(args) >= 4 && ~isempty(args{4})
   pen = double(args{4});
   assert(isscalar(pen) && isfinite(pen) && pen > 0, 'Pen width must be positive.');
  end
  assert(numel(args) <= 4, '%s takes w, colour, rect and pen width.', cmd);
  % Screen accepts a 4xN rect matrix for multiple rectangles; so do we.
  if isvector(r), r = r(:); end
  assert(size(r,1) == 4 && all(isfinite(r(:))), ...
      'The rectangle must be [left top right bottom], or 4xN for several.');
  n = size(r,2);
  switch cmd
   case 'fillrect',   k = 0;
   case 'framerect',  k = 1;
   case 'filloval',   k = 2;
   otherwise,         k = 3;
  end
  kind = repmat(k, 1, n);
  param = repmat(pen, 1, n);
  rect = [min(r(1,:),r(3,:)); min(r(2,:),r(4,:)); ...
          max(r(1,:),r(3,:)); max(r(2,:),r(4,:))];
  color = expandColors(spec, n, S.colorRange);
  extra = zeros(4, n);

 case 'drawdots'
  % PsychMetal('DrawDots', w, xy [, size] [, color] [, center])
  assert(numel(args) >= 2, 'DrawDots needs a 2xN position matrix.');
  xy = double(args{2});
  if isvector(xy), xy = xy(:); end
  assert(size(xy,1) == 2, 'Dot positions must be 2xN.');
  n = size(xy,2);
  if n == 0, return; end
  sz = 10;
  if numel(args) >= 3 && ~isempty(args{3}), sz = double(args{3}(:))'; end
  assert(isscalar(sz) || numel(sz) == n, 'Dot size must be scalar or 1xN.');
  if isscalar(sz), sz = repmat(sz, 1, n); end
  spec = []; if numel(args) >= 4, spec = args{4}; end
  ctr = [0 0];
  if numel(args) >= 5 && ~isempty(args{5}), ctr = double(args{5}(:))'; end
  assert(numel(ctr) == 2, 'The centre offset must be [x y].');
  % dot_type, Screen's sixth argument. 0 is square; 1, 2 and 3 are all round
  % here. Screen distinguishes them by which OpenGL smoothing path it takes,
  % which is meaningless in Metal: the round dots compute coverage analytically
  % in the fragment shader, so they are already as smooth as 4 would be.
  dotType = 1;
  if numel(args) >= 6 && ~isempty(args{6})
   dotType = double(args{6});
   assert(isscalar(dotType) && any(dotType == [0 1 2 3 4]), ...
       'dot_type must be 0 (square) or 1 to 4 (round).');
  end
  cx = xy(1,:) + ctr(1); cy = xy(2,:) + ctr(2);
  h = sz / 2;
  kind = repmat((dotType == 0) * 0 + (dotType ~= 0) * 4, 1, n);
  param = zeros(1, n);
  rect = [cx - h; cy - h; cx + h; cy + h];
  color = expandColors(spec, n, S.colorRange);
  extra = zeros(4, n);

 case 'drawlines'
  % PsychMetal('DrawLines', w, xy [, width] [, color] [, center])
  assert(numel(args) >= 2, 'DrawLines needs a 2xN endpoint matrix.');
  xy = double(args{2});
  assert(size(xy,1) == 2 && mod(size(xy,2), 2) == 0, ...
      'Line endpoints must be 2xN with N even: pairs of points.');
  n = size(xy,2) / 2;
  if n == 0, return; end
  wdt = 1;
  if numel(args) >= 3 && ~isempty(args{3}), wdt = double(args{3}(:))'; end
  assert(isscalar(wdt) || numel(wdt) == n, 'Line width must be scalar or 1xN.');
  if isscalar(wdt), wdt = repmat(wdt, 1, n); end
  spec = []; if numel(args) >= 4, spec = args{4}; end
  ctr = [0 0];
  if numel(args) >= 5 && ~isempty(args{5}), ctr = double(args{5}(:))'; end
  p0 = xy(:, 1:2:end); p1 = xy(:, 2:2:end);
  kind = repmat(5, 1, n);
  param = wdt;
  rect = [p0(1,:) + ctr(1); p0(2,:) + ctr(2); ...
          p1(1,:) + ctr(1); p1(2,:) + ctr(2)];
  color = expandColors(spec, n, S.colorRange);
  extra = zeros(4, n);

 otherwise
  error('PsychMetal:Command', 'Unhandled drawing command %s.', cmd);
end
end

function [r, seed, normalFlag, colourFlag, meanRGBA, spread] = noiseArgs(a, S, what)
% Parse the arguments DrawNoise and NoiseValues share, so the drawn noise and
% the recomputed values cannot disagree about what was asked for. `a` is the
% argument list after the window handle: {rect [, seed] [, dist] [, chroma]
% [, mean] [, spread]}.
r = double(a{1});
assert(numel(r) == 4 && all(isfinite(r)), ...
    '%s needs a rect [left top right bottom].', what);
r = [min(r(1),r(3)); min(r(2),r(4)); max(r(1),r(3)); max(r(2),r(4))];
assert(r(3) - r(1) >= 1 && r(4) - r(2) >= 1, ...
    '%s needs a rect at least one pixel across.', what);

% SEED IS AN OUTPUT FIRST AND AN INPUT SECOND. Omit it, or pass [], and one is
% drawn here and returned; the caller records that integer and can reconstruct
% the exact frame from it later. Pass a seed to redraw a frame you already have.
%
% Drawn with randi, so it follows the caller's own RNG state: rng(0) or
% rand('seed', 0) before a session makes the whole sequence of seeds repeatable,
% which is what a replayable experiment needs.
if numel(a) >= 2 && ~isempty(a{2})
 seed = double(a{2});
else
 seed = randi([0 16777215]);
end
% 2^24, because the seed travels to the shader inside a float32 and integers
% above that are not exactly representable. Rejecting is better than silently
% drawing the noise for a different seed than the one recorded.
assert(isscalar(seed) && isfinite(seed) && seed == fix(seed) && ...
    seed >= 0 && seed <= 16777215, ...
    'Seed must be an integer from 0 to 16777215.');

normalFlag = false;
if numel(a) >= 3 && ~isempty(a{3})
 d = lower(char(a{3}));
 assert(any(strcmp(d, {'uniform','normal'})), ...
     'Distribution must be ''uniform'' or ''normal''.');
 normalFlag = strcmp(d, 'normal');
end

colourFlag = false;
if numel(a) >= 4 && ~isempty(a{4})
 c = lower(char(a{4}));
 assert(any(strcmp(c, {'mono','colour','color'})), ...
     'Chroma must be ''mono'' or ''colour''.');
 colourFlag = ~strcmp(c, 'mono');
end

% MEAN 0.5 AND SPREAD 0.5, so the default is uniform between black and white.
%
% Defaulting the mean to the window background was the obvious choice and is
% wrong: the background defaults to black, so the default noise would have run
% 0 to 0.5 — half contrast, and quietly. A default should be the thing people
% mean when they say "white noise", and any other centre is one argument away.
if numel(a) >= 5 && ~isempty(a{5})
 meanRGBA = colorToRGBA(a{5}, 'Noise mean', S.colorRange);
else
 meanRGBA = [0.5 0.5 0.5 1];
end

% ON THE WINDOW'S ColorRange, like the mean. These two are added together in
% the shader, so a spread in different units from its mean is a stimulus with
% the wrong contrast and nothing to say so: at range 255, mean 128 with spread
% 128 must span black to white, not blow out by 255x.
% The default is half the range either way.
spread = 0.5;
if numel(a) >= 6 && ~isempty(a{6})
 spread = double(a{6});
 assert(isscalar(spread) && isfinite(spread) && spread >= 0, ...
     'Spread must be zero or positive.');
 spread = spread / S.colorRange;
end
end

function s = modeStruct(m)
% One row per display mode, as a struct array shaped like Screen('Resolutions').
s = struct('width', num2cell(m(:,1)), 'height', num2cell(m(:,2)), ...
           'pixelWidth', num2cell(m(:,3)), 'pixelHeight', num2cell(m(:,4)), ...
           'hz', num2cell(m(:,5)));
end

function c = colorToRGBA(spec, what, cRange)
% One colour as a 1x4 RGBA row, on the same 0-1 convention and with the same
% clamp-and-warn behaviour as every drawing colour. Built on expandColors so
% there is one definition of what a PsychMetal colour is, rather than two that
% can drift apart.
c = expandColors(spec, 1, cRange)';
assert(numel(c) == 4, '%s must be scalar grey, RGB or RGBA.', what);
end

function warnSecureInput(pid)
% Secure input fails SILENTLY, which is the only reason this exists.
%
% While any process holds secure event input — a password field, a password
% manager, a locked screen saver that did not fully release — every key reads
% up. A subject can hold a key down for the whole trial and KbCheck returns
% false with no error, so an experiment collects a screen of missing responses
% and no evidence of why. Warned once per session rather than per poll, since
% the poll is usually in a frame loop.
persistent warned
if isempty(warned), warned = false; end
if warned, return; end
warned = true;
warning('PsychMetal:SecureInput', ...
    ['Secure event input is active (pid %d), so EVERY key will read as up ' ...
     'and no error will be raised. Quit whatever is holding it — a password ' ...
     'field, a password manager, a screen saver — and check again. Warned ' ...
     'once per session.'], pid);
end

function t = keyNameTable()
% HID usage code -> name. Usage codes because they are what KbCheck returns
% and what Psychtoolbox's KbName numbers already mean; a ported script's
% KbName('ESCAPE') is 41 in both. Only the keys a keyboard actually has, so
% an unknown code is reported as usage<n> rather than silently named.
persistent tbl
if ~isempty(tbl), t = tbl; return; end
letters = num2cell('a':'z');
rows = cell(0, 2);
for k = 1:26, rows(end+1,:) = {3+k, letters{k}}; end %#ok<AGROW>
digits = {'1!','2@','3#','4$','5%','6^','7&','8*','9(','0)'};
for k = 1:10, rows(end+1,:) = {29+k, digits{k}}; end %#ok<AGROW>
rows = [rows; {
 40, 'Return'; 41, 'ESCAPE'; 42, 'DELETE'; 43, 'tab'; 44, 'space'
 45, '-_'; 46, '=+'; 47, '[{'; 48, ']}'; 49, '\|'; 51, ';:'; 52, '''"'
 53, '`~'; 54, ',<'; 55, '.>'; 56, '/?'; 57, 'CapsLock'}];
for k = 1:12, rows(end+1,:) = {57+k, sprintf('F%d', k)}; end %#ok<AGROW>
rows = [rows; {
 70, 'PrintScreen'; 71, 'ScrollLock'; 72, 'Pause'; 73, 'Insert'
 74, 'Home'; 75, 'PageUp'; 76, 'Delete'; 77, 'End'; 78, 'PageDown'
 79, 'RightArrow'; 80, 'LeftArrow'; 81, 'DownArrow'; 82, 'UpArrow'
 83, 'NumLockClear'; 84, 'Divide'; 85, 'Multiply'; 86, 'Subtract'
 87, 'Add'; 88, 'ENTER'}];
for k = 1:9, rows(end+1,:) = {88+k, sprintf('Keypad%d', k)}; end %#ok<AGROW>
rows = [rows; {
 98, 'Keypad0'; 99, 'KeypadDecimal'; 100, 'NonUSBackslash'
 101, 'Application'; 103, 'KeypadEqual'}];
for k = 13:24, rows(end+1,:) = {91+k, sprintf('F%d', k)}; end %#ok<AGROW>
rows = [rows; {
 117, 'Help'; 133, 'KeypadComma'; 135, 'International1'
 137, 'International3'; 144, 'Lang1'; 145, 'Lang2'
 224, 'LeftControl'; 225, 'LeftShift'; 226, 'LeftAlt'; 227, 'LeftGUI'
 228, 'RightControl'; 229, 'RightShift'; 230, 'RightAlt'; 231, 'RightGUI'}];
tbl = rows;
t = tbl;
end

function c = expandColors(spec, n, cRange)
% One colour for every instance, as 4xN on 0 to 1 for the shader.
%
% COLOURS ARE ON THE WINDOW'S ColorRange, 255 by default, exactly as Screen.
% PsychMetal is meant to be a drop-in replacement, and colour is where that
% matters most: a find-and-replace of Screen( for PsychMetal( in existing code
% would otherwise render every stimulus at 1/255 of its intended brightness,
% silently, because 255 would clamp to 1 and 128 to 1 as well.
%
% The shader works in 0 to 1 regardless; the division happens here, in the one
% place every drawing command's colour passes through.
%
% Accepts [] (white), a scalar grey, an RGB or RGBA column, or a 3xN or 4xN
% matrix for one colour per shape.
if nargin < 3 || isempty(cRange), cRange = 255; end
if isempty(spec)
 c = repmat([1;1;1;1], 1, n);
 return;
end
spec = double(spec) / cRange;
if isvector(spec), spec = spec(:); end
switch size(spec,1)
 case 1, spec = [repmat(spec, 3, 1); ones(1, size(spec,2))];
 case 3, spec = [spec; ones(1, size(spec,2))];
 case 4, % already RGBA
 otherwise
  error('PsychMetal:Color', ...
      'Colour must be scalar grey, RGB or RGBA, optionally one per shape.');
end
if size(spec,2) == 1
 spec = repmat(spec, 1, n);
end
assert(size(spec,2) == n, ...
    'Supply one colour, or one colour per shape (%d).', n);
assert(all(isfinite(spec(:))), 'Colour components must be finite.');
if any(spec(:) > 1.001)
 warning('PsychMetal:ColorRange', ...
     ['A colour component of %g exceeds this window''s ColorRange of %g and ' ...
      'will be clamped. Set the range with PsychMetal(''ColorRange'', w, r).'], ...
     max(spec(:)) * cRange, cRange);
end
c = min(max(spec, 0), 1);
end
