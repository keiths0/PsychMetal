function varargout = PsychMetal(command, varargin)
% PsychMetal  Native Metal stimulus presentation on macOS. No OpenGL.
% Version 0.4.3. SPDX-License-Identifier: MIT.
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
  refreshHz=[];
  if numel(varargin)==1 && isstruct(varargin{1}) && isscalar(varargin{1})
   options=varargin{1}; allowed={'screen','backgroundColor','drawableCount','waitForConfirm','displaySync','captureDisplay','refreshHz'};
   assert(all(ismember(fieldnames(options),allowed)), 'Unknown OpenWindow option.');
   varargin=cell(1,6);
   for j=1:6, if isfield(options,allowed{j}), varargin{j}=options.(allowed{j}); end; end
   if isfield(options,'refreshHz'), refreshHz=options.refreshHz; end
  end
  if ~isempty(refreshHz)
   assert(isnumeric(refreshHz) && isreal(refreshHz) && isscalar(refreshHz) && isfinite(refreshHz) && refreshHz>=20 && refreshHz<=1000, 'refreshHz must be 20..1000.');
  end
  assert(numel(varargin) <= 6, ...
      ['OpenWindow accepts screen number, background colour, drawable count, ' ...
       'wait-for-confirmation, displaySync and captureDisplay.']);
  screen = -1;
  if ~isempty(varargin) && ~isempty(varargin{1})
   assert(isnumeric(varargin{1}) && isreal(varargin{1}) && isscalar(varargin{1}), ...
       'Screen number must be a real numeric scalar.');
   screen = double(varargin{1});
   assert(isfinite(screen) && screen == fix(screen) && screen >= 0, ...
       'Screen number must be a non-negative integer.');
  end
  colorRange = 255;
  bgColor = [0 0 0 1];
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   bgColor = colorToRGBA(varargin{2}, 'Background colour', colorRange);
  end
  drawableCount = 3;
  if numel(varargin) >= 3 && ~isempty(varargin{3})
   assert(isnumeric(varargin{3}) && isreal(varargin{3}) && isscalar(varargin{3}), ...
       'Maximum drawable count must be 2 or 3.');
   drawableCount = double(varargin{3});
   assert(isfinite(drawableCount) && any(drawableCount == [2 3]), ...
       'Maximum drawable count must be 2 or 3.');
  end
  prefetch = (drawableCount >= 3);
  waitForConfirm = false;
  if numel(varargin) >= 4 && ~isempty(varargin{4})
   assert(isscalar(varargin{4}) && (islogical(varargin{4}) || isnumeric(varargin{4})), ...
       'Wait-for-confirmation must be a logical scalar.');
   waitForConfirm = logicalFlag(varargin{4},'waitForConfirm');
  end
  vsync = true;
  if numel(varargin) >= 5 && ~isempty(varargin{5})
   assert(isscalar(varargin{5}) && (islogical(varargin{5}) || isnumeric(varargin{5})), ...
       'displaySync must be a logical scalar.');
   vsync = logicalFlag(varargin{5},'vsync');
  end
  captureDisplay = true;
  if numel(varargin) >= 6 && ~isempty(varargin{6})
   assert(isscalar(varargin{6}) && (islogical(varargin{6}) || isnumeric(varargin{6})), ...
       'captureDisplay must be a logical scalar.');
   captureDisplay = logicalFlag(varargin{6},'captureDisplay');
  end
  try
   abi=PsychMetalCore('Version');
   assert(strcmp(abi,'0.4.3'), 'PsychMetal wrapper/core version mismatch: expected 0.4.3, found %s.',abi);
   PsychMetalCore('PrepareApp');
   openArgs={screen,drawableCount,double(waitForConfirm),double(vsync),double(captureDisplay)};
   if ~isempty(refreshHz), openArgs{end+1}=refreshHz; end
   [width,height,ifi,pointW,pointH,nativeWindowToken]=PsychMetalCore('Open',openArgs{:});
   displayRect = [0 0 width height];
   physicalRect = displayRect;
   logicalRect = [0 0 pointW pointH];
   PsychMetalCore('SetBackgroundColor', bgColor(1), bgColor(2), bgColor(3), bgColor(4));
   startupBegan=tic;
   startup=PsychMetalCore('ConfirmStartup');
   startupSeconds=toc(startupBegan);
   fprintf('PsychMetal: %dx%d at %.3f Hz. Direct Metal presentation, no OpenGL.\n', ...
       width, height, 1/ifi);
   fprintf(['PsychMetal: colours run 0-%g, as Screen. ' ...
       'PsychMetal(''ColorRange'', w, 1) for 0-1.\n'], colorRange);
  catch e
   try, PsychMetalCore('Close'); catch, end
   rethrow(e);
  end
  buffer=nativeWindowToken;
  S = struct('buffer',buffer,'ifi',ifi, ...
      'colorRange',colorRange, 'textureSize',zeros(0,3), ...
      'logicalRect',logicalRect, ...
      'physicalRect',physicalRect, ...
      'bgColor',bgColor, 'startupHistory',startup,'startupSeconds',startupSeconds, ...
      'drawableCount',drawableCount, ...
      'waitForConfirm',waitForConfirm, ...
      'lastVblConfirmed',false, ...
      'lastQueueMs',NaN,'lastFlipMs',NaN, ...
      'flipCount',0,'slipCount',0,'lastSlipFlip',NaN,'lastSlipRefreshes',0);
 if prefetch
  PsychMetalCore('PrefetchDrawable', 1);
 end
 varargout = {buffer, displayRect, ifi};

 case 'maketexture'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''MakeTexture'') requires the window handle and an image.');
  assert(numel(varargin) == 2, 'MakeTexture takes a window and an image.');
  handle = PsychMetalCore('MakeTexture', varargin{2});
  S.textureSize(end+1,:) = [handle size(varargin{2},2) size(varargin{2},1)];
  varargout = {handle};

 case 'updatetexture'
  assert(~isempty(S) && numel(varargin)==3 && isequal(varargin{1},S.buffer), ...
      'UpdateTexture requires w, texture, image.');
  handle=varargin{2};
  assert(isnumeric(handle) && isreal(handle) && isscalar(handle) && isfinite(handle), 'Invalid texture handle.');
  row=find(S.textureSize(:,1)==handle,1);
  assert(~isempty(row), 'Unknown texture handle.');
  PsychMetalCore('UpdateTexture',handle,varargin{3});
  S.textureSize(row,2:3)=[size(varargin{3},2) size(varargin{3},1)];

 case 'drawtexture'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''DrawTexture'') requires the window handle and a texture.');
  handle = varargin{2};
  assert(isnumeric(handle) && isreal(handle) && isscalar(handle) && isfinite(handle), 'Invalid texture handle.');
  row=find(S.textureSize(:,1)==handle,1);
  assert(~isempty(row), 'Unknown texture handle.');
  tw=S.textureSize(row,2); th=S.textureSize(row,3);
  src = [0 0 tw th];
  if numel(varargin) >= 3 && ~isempty(varargin{3}), src = double(varargin{3}(:))'; end
  assert(isreal(src) && ~issparse(src) && numel(src) == 4 && all(isfinite(src)), 'srcRect must be [left top right bottom] in texture pixels.');
  dst = [];
  if numel(varargin) >= 4 && ~isempty(varargin{4}), dst = double(varargin{4}(:))'; end
  if isempty(dst)
   cx = (S.physicalRect(1) + S.physicalRect(3)) / 2;
   cy = (S.physicalRect(2) + S.physicalRect(4)) / 2;
   sw = abs(src(3) - src(1)); sh = abs(src(4) - src(2));
   dst = [cx - sw/2, cy - sh/2, cx + sw/2, cy + sh/2];
  end
  assert(isreal(dst) && ~issparse(dst) && numel(dst) == 4 && all(isfinite(dst)), 'dstRect must be [left top right bottom] in window pixels.');
  angle = 0;
  if numel(varargin) >= 5 && ~isempty(varargin{5}), angle = double(varargin{5}); end
  assert(isscalar(angle) && isfinite(angle), 'The rotation angle must be a scalar.');
  filterMode = 1;
  if numel(varargin) >= 6 && ~isempty(varargin{6})
   filterMode = double(varargin{6});
   assert(numel(filterMode) <= 2, ...
       ['Argument 6 is filterMode, and you passed %d values, which looks ' ...
        'like a colour. Before 0.4.0 the tint sat here. It is now ' ...
        'modulateColor at argument 8, following Screen exactly:\n' ...
        '    PsychMetal(''DrawTexture'', w, tex, src, dst, angle, ' ...
        'filterMode, globalAlpha, modulateColor)\n' ...
        'so a call that passed a colour at 6 becomes ..., angle, 1, [], ' ...
        'colour. Colours are on the window''s ColorRange, 255 by default.'], ...
       numel(filterMode));
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
  handle=varargin{2};
  assert(isnumeric(handle) && isreal(handle) && isscalar(handle) && isfinite(handle), 'Invalid texture handle.');
  row=find(S.textureSize(:,1)==handle,1);
  assert(~isempty(row), 'Unknown texture handle.');
  PsychMetalCore('CloseTexture',handle);
  S.textureSize(row,:)=[];

 case 'prefetchdrawable'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''PrefetchDrawable'') needs the window handle and a logical.');
  on = logicalFlag(varargin{2},'prefetch');
  if on && S.drawableCount < 3
   warning('PsychMetal:PrefetchStarvesPool', ...
       ['Prefetching with %d drawables starves the pool and halves the ' ...
        'presentation rate. Open the window with 3 drawables instead.'], ...
       S.drawableCount);
  end
  PsychMetalCore('PrefetchDrawable', double(on));

 case 'colorrange'
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
  assert(isempty(varargin), 'GetSecs takes no arguments.');
  varargout = {PsychMetalCore('Now')};

 case 'waitsecs'
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
  screenArg = -1;
  if ~isempty(varargin) && ~isempty(varargin{1})
   screenArg = double(varargin{1});
   assert(isscalar(screenArg) && isfinite(screenArg) && screenArg == fix(screenArg) ...
       && screenArg >= 0, 'Screen number must be a non-negative integer.');
  end
  m = PsychMetalCore('Modes', screenArg);
  if strcmpi(command, 'resolutions')
   assert(numel(varargin) <= 1, 'Resolutions takes only a screen number.');
   varargout = {modeStruct(m)};
  else
   assert(numel(varargin) <= 3, ...
       'Resolution takes a screen number and an optional width and height.');
   assert(numel(varargin)~=2, 'Supply both width and height.');
   if numel(varargin)==3, assert(~isempty(varargin{2}) && ~isempty(varargin{3}), 'Supply both width and height.'); end
   old = modeStruct(m(1,:));
   if numel(varargin) >= 3 && ~isempty(varargin{2}) && ~isempty(varargin{3})
    modeChanged = PsychMetalCore('SetMode', screenArg, double(varargin{2}), double(varargin{3})); %#ok<NASGU>
   end
   varargout = {old};
  end

 case 'rect'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'Rect requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'Rect takes only the window handle.');
  varargout = {S.physicalRect};

 case 'windowsize'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'WindowSize requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'WindowSize takes only the window handle.');
  varargout = {S.physicalRect(3) - S.physicalRect(1), ...
               S.physicalRect(4) - S.physicalRect(2)};

 case 'getflipinterval'
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
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'BackgroundColor requires the window handle from OpenWindow.');
  assert(numel(varargin) == 2, 'BackgroundColor needs a window and a colour.');
  bg = colorToRGBA(varargin{2}, 'Background colour', S.colorRange);
  PsychMetalCore('SetBackgroundColor', bg(1), bg(2), bg(3), bg(4));
  S.bgColor = bg;
  if nargout >= 1, varargout{1} = bg; end

 case 'getmouse'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''GetMouse'') requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'GetMouse takes only the window handle.');
  [mx, my, buttons] = PsychMetalCore('Mouse');
  varargout = {mx, my, buttons};

 case {'hidecursor','showcursor'}
  assert(isempty(varargin), '%s takes no arguments.', command);
  PsychMetalCore('Cursor', double(strcmpi(command, 'showcursor')));

 case 'kbcheck'
  assert(isempty(varargin), ['PsychMetal(''KbCheck'') takes no arguments. ' ...
      'There is no deviceNumber: macOS merges every keyboard into one ' ...
      'state before PsychMetal can see it, so all of them are always read.']);
  [keyIsDown, secs, keyCode, securePid] = PsychMetalCore('Keys');
  if securePid ~= 0
   warnSecureInput(securePid);
  end
  varargout = {keyIsDown, secs, keyCode};

 case 'kbqueuecreate'
  assert(numel(varargin)<=2, 'KbQueueCreate takes [keyMask] [, pollInterval]. No device argument.');
  mask=ones(1,256); interval=.002;
  if numel(varargin)>=1 && ~isempty(varargin{1}), mask=varargin{1}; end
  if numel(varargin)>=2 && ~isempty(varargin{2}), interval=varargin{2}; end
  assert(~issparse(mask) && (isnumeric(mask)||islogical(mask)) && isreal(mask) && numel(mask)==256 && all(isfinite(mask(:))), 'keyMask must have 256 finite real entries.');
  assert(isnumeric(interval) && isreal(interval) && isscalar(interval) && isfinite(interval) && interval>=.001 && interval<=.1, 'pollInterval must be .001 to .1 seconds.');
  PsychMetalCore('KbQueueCreate',double(mask(:)'),double(interval));

 case {'kbqueuestart','kbqueuestop','kbqueueflush','kbqueuerelease'}
  assert(isempty(varargin), 'This queue command takes no arguments.');
  names={'kbqueuestart','kbqueuestop','kbqueueflush','kbqueuerelease'};
  core={'KbQueueStart','KbQueueStop','KbQueueFlush','KbQueueRelease'};
  PsychMetalCore(core{find(strcmpi(command,names),1)});

 case 'kbqueuegetevents'
  assert(isempty(varargin), 'KbQueueGetEvents takes no arguments.');
  [events,dropped]=PsychMetalCore('KbQueueGetEvents');
  varargout={events,dropped};

 case 'kbqueuecheck'
  assert(isempty(varargin), 'KbQueueCheck takes no arguments.');
  [pressed,firstPress,firstRelease,lastPress,lastRelease]=PsychMetalCore('KbQueueCheck');
  varargout={pressed,firstPress,firstRelease,lastPress,lastRelease};

 case 'kbqueuestatus'
  assert(isempty(varargin), 'KbQueueStatus takes no arguments.');
  varargout={PsychMetalCore('KbQueueStatus')};

 case 'kbwait'
  assert(numel(varargin) <= 2, 'KbWait takes untilRelease and pollInterval.');
  untilRelease = false; pollInterval = 0.005;
  if numel(varargin) >= 1 && ~isempty(varargin{1})
   untilRelease = logicalFlag(varargin{1},'untilRelease');
  end
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   pollInterval = double(varargin{2});
   assert(isreal(pollInterval) && isscalar(pollInterval) && isfinite(pollInterval) && pollInterval > 0, ...
       'pollInterval must be a nonnegative scalar.');
  end
  while true
   [down, secs] = PsychMetal('KbCheck');
   if down ~= untilRelease, break; end
   pause(pollInterval);
  end
  if nargout >= 1, varargout{1} = secs; end

 case 'kbname'
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
  varargout = {PsychMetalCore('NoiseValues', nw, nh, nseed, ...
      double(nnormal), double(ncolour), nmean(1:3), nspread) * S.colorRange};

 case {'fillrect','framerect','filloval','frameoval','drawdots','drawlines', ...
       'drawgabor','drawnoise'}
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'A PsychMetal drawing command requires the window handle from OpenWindow.');
  [kind, param, rect, color, extra, info] = buildShapes(lower(command), varargin, S);
  if ~isempty(kind)
   PsychMetalCore('AddShapes', kind, param, rect, color, extra);
  end
  if ~isempty(info)
   varargout{1} = info.seed;
   if nargout >= 2
    varargout{2} = PsychMetalCore('NoiseValues', info.width, info.height, ...
        info.seed, double(info.normal), double(info.colour), ...
        info.mean, info.spread) * S.colorRange;
   end
  end

 case 'flip'
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
  if haveWhen, raw=PsychMetalCore('Flip',when); else, raw=PsychMetalCore('Flip'); end
  S.lastQueueMs=raw(8); S.lastFlipMs=raw(9); flipReturn=raw(10);
  vbl = raw(1);
  S.lastVblConfirmed = numel(raw) >= 5 && raw(5) == 1;
  missed = 0;
  if haveWhen
   missed = vbl - when - raw(7);
  end
  if raw(2) ~= 0, missed = NaN; end
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
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''PrepareFlip'') requires w.');
  token = PsychMetalCore('PrepareFlip');
  varargout = {token};

 case 'presentnow'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''PresentNow'') requires w.');
  out = PsychMetalCore('PresentNow');
  varargout = {out(1), out(2)};

 case 'setdisplaysync'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''SetDisplaySync'') requires w and a flag.');
  assert(isscalar(varargin{2}) && (islogical(varargin{2}) || isnumeric(varargin{2})), ...
      'The display-sync flag must be a logical scalar.');
  PsychMetalCore('SetDisplaySync', double(logicalFlag(varargin{2},'displaySync')));

 case 'gridanchor'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''GridAnchor'') requires w.');
  g = PsychMetalCore('GridAnchor');
  varargout = {[g(1), g(2), g(3)]};

 case 'nextphase'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 3 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''NextPhase'') requires w, a time and a phase.');
  assert(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2}), ...
      'The time must be a finite GetSecs timestamp.');
  assert(isnumeric(varargin{3}) && isscalar(varargin{3}) && isfinite(varargin{3}), ...
      'The phase must be a finite number.');
  varargout = {PsychMetalCore('NextPhase', double(varargin{2}), double(varargin{3}))};

 case 'nextrefresh'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''NextRefresh'') requires w and a time.');
  assert(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2}), ...
      'The time must be a finite GetSecs timestamp.');
  varargout = {PsychMetalCore('NextRefresh', double(varargin{2}))};

 case 'waittodraw'
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
  varargout = {out(1), out(2), out(3)};

 case 'diagnostic'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''Diagnostic'') requires the window handle returned by OpenWindow.');
  [h, summary] = PsychMetalCore('Diagnostic');
  summary.lastQueueMs = S.lastQueueMs;
  summary.lastFlipMs = S.lastFlipMs;
  summary.colorRange = S.colorRange;
  summary.logicalRect = S.logicalRect;
  summary.physicalRect = S.physicalRect;
  summary.waitForConfirm = S.waitForConfirm;
  summary.lastVblConfirmed = S.lastVblConfirmed;
  summary.backgroundColor = S.bgColor;
  summary.flips = S.flipCount;
  summary.slipFlips = S.slipCount;
  summary.lastSlipFlip = S.lastSlipFlip;
  summary.lastSlipRefreshes = S.lastSlipRefreshes;
  actual = h(:,3);
  actualStatus = h(:,4); % 0 confirmed, 1 missing, 2 pending, 3 GPU error, 4 no drawable.
  actual(actualStatus ~= 0) = NaN;
  projected = h(:,2);
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
      'drawableWaitMs',h(:,14), ...
      'encodeMs',h(:,15), 'prefetchWaitMs',h(:,16), ...
      'presentErrorMs',(actual-h(:,11))*1000, ...
      'gpuPassMs',gpuPassMs, ...
      'gpuStartTime',h(:,9), ...
      'gpuEndTime',h(:,10), ...
      'summary',summary);
  if size(h,2)>=17, d.pacingWaitMs=h(:,17); else, d.pacingWaitMs=nan(size(h,1),1); end
  sh=S.startupHistory;
  d.startup=struct('token',sh(:,1),'status',sh(:,2),'presentedTime',sh(:,3), ...
      'callbackTime',sh(:,4),'gpuDone',sh(:,5),'committedTime',sh(:,6),'seconds',S.startupSeconds);
  summary.startupAttempts=size(sh,1);summary.startupSeconds=S.startupSeconds;
  d.summary=summary;
  varargout={d};

 case 'close'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''Close'') requires the window handle returned by OpenWindow.');
  PsychMetalCore('Close');
  S = [];

 case 'version'
  assert(isempty(varargin), 'PsychMetal(''Version'') takes no arguments.');
  varargout = {'0.4.3'};

 otherwise
  error('PsychMetal:Command', ...
      'Unknown PsychMetal command ''%s''. Call PsychMetal for a command list.', command);
end
end

function printGeneralHelp
names=commandNames();
fprintf('PsychMetal 0.4.3: native Metal on Apple Silicon.\n');
fprintf('Use PsychMetal(''Command?'') for help. See README.md for supported contracts.\n');
for k=1:numel(names), fprintf('  %s\n',names{k}); end
end

function printCommandHelp(name)
name=lower(strtrim(name));
if ~any(strcmpi(name,commandNames())) && ~strcmp(name,'latency')
 error('PsychMetal:Help','Unknown help topic %s.',name);
end
switch name
 case 'openwindow'
  fprintf(['[w,rect,ifi]=PsychMetal(''OpenWindow'' [,screen,background,drawableCount,waitForConfirm,displaySync,captureDisplay])\n' ...
   'Or pass a scalar options struct with those fields (screen, backgroundColor) and optional refreshHz.\n' ...
   'Colors default to 0..255. Use a fixed display refresh mode for timing.\n']);
 case {'maketexture','updatetexture','drawtexture','closetexture'}
  fprintf(['tex=PsychMetal(''MakeTexture'',w,image); PsychMetal(''UpdateTexture'',w,tex,image);\n' ...
   'Dense HxW, HxWx3 or HxWx4: uint8 uses 0..255; single/double/logical use 0..1. Finite values clamp.\n' ...
   'PsychMetal(''DrawTexture'',w,tex[,srcRect,dstRect,angle,filterMode,globalAlpha,modulateColor]);\n' ...
   'Rectangles use pixels; angle uses degrees; filter 0 nearest or 1 linear. Alpha/color use ColorRange.\n' ...
   'PsychMetal(''CloseTexture'',w,tex); handles expire permanently on close. Queued draws retain their image.\n' ...
   'Four storage versions per texture bound queued/in-flight updates; Flip before exhausting the pool.\n']);
 case {'flip','diagnostic','getflipinterval','latency'}
  fprintf(['[predictedOrConfirmed,onset,returned,missed,slipped]=PsychMetal(''Flip'',w[,when]);\n' ...
   'Default timestamps are predictions; waitForConfirm requests measured presentedTime at reduced throughput.\n' ...
   'Failures raise errors. Predictions are not measured light onset. Variable refresh is not validated.\n' ...
   'PsychMetal(''Diagnostic'',w) drains pending work and returns confirmed history and stage timings.\n' ...
   'GetFlipInterval returns a period estimated from confirmed frame indices, or the initial nominal period.\n']);
 case {'kbqueuecreate','kbqueuestart','kbqueuestop','kbqueueflush','kbqueuerelease','kbqueuecheck','kbqueuegetevents','kbqueuestatus'}
  fprintf(['PsychMetal(''KbQueueCreate''[,denseMask256,pollSeconds]); PsychMetal(''KbQueueStart'');\n' ...
   '[events,dropped]=PsychMetal(''KbQueueGetEvents''); events are [detectionTime,HIDcode,pressed].\n' ...
   '[pressed,firstPress,firstRelease,lastPress,lastRelease]=PsychMetal(''KbQueueCheck'');\n' ...
   'KbQueueStop preserves events. Flush clears events/summaries and discards scans overlapping flush.\n' ...
   'KbQueueRelease frees the queue. KbQueueStatus reports polling intervals, overflow and secureInputPID.\n' ...
   'Timestamps are polled detection times, not hardware event times. See KEYBOARD-QUEUE.md.\n']);
 case 'waitsecs'
  fprintf(['PsychMetal(''WaitSecs'',seconds) or (''UntilTime'',deadline) uses an adaptive 4..20 ms spin margin.\n' ...
   'For relaxed waits use pause(seconds). KbWait uses relaxed polling.\n']);
 case {'prepareflip','presentnow'}
  fprintf(['PsychMetal(''PrepareFlip'',w) encodes a frame; PsychMetal(''PresentNow'',w) presents it.\n' ...
   'These are diagnostic instruments. Close cancels prepared work; Flip cannot bypass a prepared frame.\n']);
 case {'resolution','resolutions'}
  fprintf(['PsychMetal(''Resolution'',screen[,width,height]) queries or sets point dimensions with no window open.\n' ...
   'Supply both width and height. PsychMetal(''Resolutions'',screen) lists modes; fields include pixels and Hz.\n']);
 case 'prefetchdrawable'
  fprintf('PsychMetal(''PrefetchDrawable'',w,true|false) acquires the next drawable after submission; use three drawables.\n');
 case 'close'
  fprintf('PsychMetal(''Close'',w) releases the session and input queue. Restart MATLAB/Octave to switch native versions.\n');
 otherwise
  fprintf('PsychMetal(''%s'', ...) — see README.md for arguments and examples.\n',name);
end
end

function names=commandNames()
names={'OpenWindow','MakeTexture','UpdateTexture','DrawTexture','CloseTexture','PrefetchDrawable', ...
'ColorRange','GetSecs','WaitSecs','Resolution','Resolutions','Rect','WindowSize','GetFlipInterval', ...
'BackgroundColor','GetMouse','HideCursor','ShowCursor','KbCheck','KbQueueCreate','KbQueueStart', ...
'KbQueueStop','KbQueueFlush','KbQueueRelease','KbQueueGetEvents','KbQueueCheck','KbQueueStatus', ...
'KbWait','KbName','NoiseValues','FillRect','FrameRect','FillOval','FrameOval','DrawDots','DrawLines', ...
'DrawGabor','DrawNoise','Flip','PrepareFlip','PresentNow','SetDisplaySync','GridAnchor','NextPhase', ...
'NextRefresh','WaitToDraw','Diagnostic','Close','Version'};
end

function [kind, param, rect, color, extra, info] = buildShapes(cmd, args, S)
kind = []; param = []; rect = zeros(4,0); color = zeros(4,0); extra = zeros(4,0);
info = [];
switch cmd
 case 'drawnoise'
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
  info = struct('seed', seed, 'normal', normalFlag, 'colour', colourFlag, ...
      'mean', meanRGBA(1:3), 'spread', spread, ...
      'width', round(r(3) - r(1)), 'height', round(r(4) - r(2)));

 case 'drawgabor'
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
  assert(isreal(r) && ~issparse(r) && size(r,1) == 4 && all(isfinite(r(:))), ...
      'The rectangle must be [left top right bottom], or 4xN for several.');
  n = size(r,2);
  kind = repmat(6, 1, n);
  param = repmat(sigma, 1, n);
  rect = [min(r(1,:),r(3,:)); min(r(2,:),r(4,:)); ...
          max(r(1,:),r(3,:)); max(r(2,:),r(4,:))];
  color = expandColors(spec, n, S.colorRange);
  extra = repmat([freq; angle * pi / 180; phase * pi / 180; 0], 1, n);

 case {'fillrect','framerect','filloval','frameoval'}
  spec = []; if numel(args) >= 2, spec = args{2}; end
  r = S.physicalRect;
  if numel(args) >= 3 && ~isempty(args{3}), r = double(args{3}); end
  pen = 1;
  if numel(args) >= 4 && ~isempty(args{4})
   pen = double(args{4});
   assert(isscalar(pen) && isfinite(pen) && pen > 0, 'Pen width must be positive.');
  end
  assert(numel(args) <= 4, '%s takes w, colour, rect and pen width.', cmd);
  if isvector(r), r = r(:); end
  assert(isreal(r) && ~issparse(r) && size(r,1) == 4 && all(isfinite(r(:))), ...
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
  assert(numel(args)<=6, 'DrawDots takes at most six arguments after command.');
  assert(numel(args) >= 2, 'DrawDots needs a 2xN position matrix.');
  xy = double(args{2});
  if isvector(xy), xy = xy(:); end
  assert(isreal(xy) && ~issparse(xy) && all(isfinite(xy(:))) && size(xy,1) == 2, 'Dot positions must be 2xN.');
  n = size(xy,2);
  sz = 10;
  if numel(args) >= 3 && ~isempty(args{3}), sz = double(args{3}(:))'; end
  assert(isreal(sz) && all(isfinite(sz)) && all(sz>0) && (isscalar(sz) || numel(sz) == n), 'Dot size must be scalar or 1xN.');
  if isscalar(sz), sz = repmat(sz, 1, n); end
  spec = []; if numel(args) >= 4, spec = args{4}; end
  ctr = [0 0];
  if numel(args) >= 5 && ~isempty(args{5}), ctr = double(args{5}(:))'; end
  assert(isreal(ctr) && all(isfinite(ctr)) && numel(ctr) == 2, 'The centre offset must be [x y].');
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
  assert(numel(args)<=5, 'DrawLines takes at most five arguments after command.');
  assert(numel(args) >= 2, 'DrawLines needs a 2xN endpoint matrix.');
  xy = double(args{2});
  assert(isreal(xy) && ~issparse(xy) && all(isfinite(xy(:))) && size(xy,1) == 2 && mod(size(xy,2), 2) == 0, ...
      'Line endpoints must be 2xN with N even: pairs of points.');
  n = size(xy,2) / 2;
  wdt = 1;
  if numel(args) >= 3 && ~isempty(args{3}), wdt = double(args{3}(:))'; end
  assert(isreal(wdt) && all(isfinite(wdt)) && all(wdt>0) && (isscalar(wdt) || numel(wdt) == n), 'Line width must be scalar or 1xN.');
  if isscalar(wdt), wdt = repmat(wdt, 1, n); end
  spec = []; if numel(args) >= 4, spec = args{4}; end
  ctr = [0 0];
  if numel(args) >= 5 && ~isempty(args{5}), ctr = double(args{5}(:))'; end
  assert(isreal(ctr) && numel(ctr)==2 && all(isfinite(ctr)), 'Center must be finite [x y].');
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
r = double(a{1});
assert(isreal(r) && ~issparse(r) && numel(r) == 4 && all(isfinite(r(:))) && all(r(:)==fix(r(:))), ...
    '%s needs a rect [left top right bottom].', what);
r = [min(r(1),r(3)); min(r(2),r(4)); max(r(1),r(3)); max(r(2),r(4))];
assert(r(3) - r(1) >= 1 && r(4) - r(2) >= 1, ...
    '%s needs a rect at least one pixel across.', what);

if numel(a) >= 2 && ~isempty(a{2})
 seed = double(a{2});
else
 seed = randi([0 16777215]);
end
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

if numel(a) >= 5 && ~isempty(a{5})
 meanRGBA = colorToRGBA(a{5}, 'Noise mean', S.colorRange);
else
 meanRGBA = [0.5 0.5 0.5 1];
end

spread = 0.5;
if numel(a) >= 6 && ~isempty(a{6})
 spread = double(a{6});
 assert(isscalar(spread) && isfinite(spread) && spread >= 0, ...
     'Spread must be zero or positive.');
 spread = spread / S.colorRange;
end
end

function s = modeStruct(m)
s = struct('width', num2cell(m(:,1)), 'height', num2cell(m(:,2)), ...
           'pixelWidth', num2cell(m(:,3)), 'pixelHeight', num2cell(m(:,4)), ...
           'hz', num2cell(m(:,5)));
end

function c = colorToRGBA(spec, what, cRange)
c = expandColors(spec, 1, cRange)';
assert(numel(c) == 4, '%s must be scalar grey, RGB or RGBA.', what);
end

function warnSecureInput(pid)
persistent warned
if isempty(warned), warned = false; end
if warned, return; end
warned = true;
if pid>0, owner=sprintf(' (pid %d)',pid); else, owner=''; end
warning('PsychMetal:SecureInput', ...
 ['Secure event input is active%s; keyboard state may be suppressed. ' ...
  'Exit the password field or application holding it. ' ...
  'KbQueueStatus provides an on-demand owner-PID lookup. Warned once per session.'],owner);
end

function t = keyNameTable()
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
if nargin < 3 || isempty(cRange), cRange = 255; end
if isempty(spec)
 c = repmat([1;1;1;1], 1, n);
 return;
end
assert((isnumeric(spec)||islogical(spec)) && isreal(spec) && ~issparse(spec), 'Colors must be dense real numeric values.');
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

function value=logicalFlag(input,name)
assert((islogical(input)||isnumeric(input)) && isreal(input) && ~issparse(input) && ...
    isscalar(input) && isfinite(input) && (input==0 || input==1), '%s must be true or false.',name);
value=logical(input);
end
