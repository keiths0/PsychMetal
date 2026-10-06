function varargout = PsychMetal(command, varargin)
% PsychMetal  Native Metal stimulus presentation on macOS. No OpenGL.
% Version 0.6.0. SPDX-License-Identifier: MIT.
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
  refreshHz=[]; readback=false; bitDepth=8;
  if numel(varargin)==1 && isstruct(varargin{1}) && isscalar(varargin{1})
   options=varargin{1}; allowed={'screen','backgroundColor','drawableCount','waitForConfirm','displaySync','captureDisplay','refreshHz','readback','bitDepth'};
   assert(all(ismember(fieldnames(options),allowed)), 'Unknown OpenWindow option.');
   varargin=cell(1,6);
   for j=1:6, if isfield(options,allowed{j}), varargin{j}=options.(allowed{j}); end; end
   if isfield(options,'refreshHz'), refreshHz=options.refreshHz; end
   if isfield(options,'readback') && ~isempty(options.readback)
    assert(isscalar(options.readback) && (islogical(options.readback) || isnumeric(options.readback)), ...
        'readback must be a logical scalar.');
    readback=logicalFlag(options.readback,'readback');
   end
   if isfield(options,'bitDepth') && ~isempty(options.bitDepth)
    bitDepth=options.bitDepth;
    assert(isnumeric(bitDepth) && isreal(bitDepth) && isscalar(bitDepth) && any(bitDepth==[8 10]), ...
        'bitDepth must be 8 or 10.');
    bitDepth=double(bitDepth);
   end
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
   assert(strcmp(abi,'0.6.0'), 'PsychMetal wrapper/core version mismatch: expected 0.6.0, found %s.',abi);
   PsychMetalCore('PrepareApp');
   openArgs={screen,drawableCount,double(waitForConfirm),double(vsync),double(captureDisplay)};
   % Trailing arguments are sent only as far as the last one that is not its
   % default. The core takes [] for "no refresh override".
   deep=bitDepth~=8;
   if ~isempty(refreshHz) || readback || deep, openArgs{end+1}=refreshHz; end
   if readback || deep, openArgs{end+1}=double(readback); end
   if deep, openArgs{end+1}=bitDepth; end
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
   if deep
    fprintf('PsychMetal: 10 bits per channel requested. Whether the panel shows them is not checked.\n');
   end
   if readback
    fprintf(['PsychMetal: readback is on. Every frame is copied for GetImage; ' ...
        'do not take timing from this session.\n']);
   end
   link=PsychMetalCore('LinkInfo');
   if link(5)==1
    fprintf(['PsychMetal: this picture needs %.1f Gbit/s and the display link carries %.1f, so the link is\n' ...
        'PsychMetal: compressed (DSC). Fine detail that changes can alter static detail near it. See README.\n'], ...
        link(4), link(3));
   end
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
      'waitForConfirm',waitForConfirm, 'readback',readback, 'bitDepth',bitDepth, ...
      'blend','alpha', 'linearize',[], 'offscreen',zeros(0,3), 'target',0, 'clip',[], ...
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
  assert(~isempty(S) && any(numel(varargin)==[3 4]) && isequal(varargin{1},S.buffer), ...
      'UpdateTexture requires w, texture, image and an optional rect.');
  handle=varargin{2};
  assert(isnumeric(handle) && isreal(handle) && isscalar(handle) && isfinite(handle), 'Invalid texture handle.');
  row=find(S.textureSize(:,1)==handle,1);
  assert(~isempty(row), 'Unknown texture handle.');
  if numel(varargin)==4 && ~isempty(varargin{4})
   % Part of the texture, in place: its size and handle stay as they are.
   part=varargin{4};
   message='The UpdateTexture rect must be [left top right bottom] in whole texture pixels, the size of the image.';
   assert(isnumeric(part) && isreal(part) && ~issparse(part) && numel(part)==4 && all(isfinite(part(:))), message);
   part=double(part(:)');
   assert(all(part==fix(part)) && part(3)-part(1)==size(varargin{3},2) && part(4)-part(2)==size(varargin{3},1), message);
   PsychMetalCore('UpdateTexture',handle,varargin{3},part(1),part(2));
  else
   PsychMetalCore('UpdateTexture',handle,varargin{3});
   S.textureSize(row,2:3)=[size(varargin{3},2) size(varargin{3},1)];
  end

 case 'blendfunction'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isWindow(S, varargin{1}), ...
      'BlendFunction requires the window handle from OpenWindow.');
  assert(numel(varargin) <= 2, 'BlendFunction takes a window and an optional mode.');
  old = S.blend;
  if numel(varargin) == 2 && ~isempty(varargin{2})
   mode = varargin{2};
   modes = {'alpha','add','copy'};
   assert(ischar(mode) || (isstring(mode) && isscalar(mode)), 'The blend mode must be ''alpha'', ''add'' or ''copy''.');
   mode = lower(char(mode));
   assert(any(strcmp(mode, modes)), 'The blend mode must be ''alpha'', ''add'' or ''copy''.');
   PsychMetalCore('BlendMode', find(strcmp(mode, modes)) - 1);
   S.blend = mode;
  end
  varargout = {old};

 case 'linearize'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'Linearize requires the window handle from OpenWindow.');
  assert(numel(varargin) <= 2, 'Linearize takes a window and an optional gamma or table.');
  old = S.linearize;
  if numel(varargin) == 2
   spec = varargin{2};
   message = ['Linearize takes the display''s gamma (one value or [r g b], each 0.05 to 20), ' ...
       'an Nx3 table of display values 0..1 with N from 2 to 4096, or [] to turn it off.'];
   assert(isempty(spec) || (isnumeric(spec) && isreal(spec) && ~issparse(spec) && ndims(spec) == 2 && ...
       all(isfinite(spec(:)))), message);
   spec = double(spec);
   if isempty(spec)
    PsychMetalCore('Gamma', 1, 1, 1);
   elseif isvector(spec) && any(numel(spec) == [1 3])
    g = spec(:)' .* ones(1, 3);
    assert(all(g >= 0.05 & g <= 20), message);
    % The display raises its input to gamma, so the frame is raised to 1/gamma.
    PsychMetalCore('Gamma', 1/g(1), 1/g(2), 1/g(3));
   else
    assert(size(spec, 2) == 3 && size(spec, 1) >= 2 && size(spec, 1) <= 4096 && ...
        all(spec(:) >= 0 & spec(:) <= 1), message);
    PsychMetalCore('GammaTable', spec);
   end
   S.linearize = spec;
  end
  varargout = {old};

 case {'drawtext','textbounds'}
  % DrawText: w, text, x, y, colour, size, font, wrapWidth. TextBounds: w, text, size, font, wrapWidth.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2, 'PsychMetal(''%s'') requires the window handle and the text.', command);
  drawing = strcmpi(command, 'drawtext');
  if drawing
   [S, targetRect] = useTarget(S, varargin{1}, command);
   assert(numel(varargin) <= 8, 'DrawText takes w, text, x, y, colour, size, font and wrapWidth.');
   a = [varargin(3:end), cell(1, 8 - numel(varargin))];
  else
   assert(isWindow(S, varargin{1}), 'PsychMetal(''TextBounds'') requires the window handle and the text.');
   assert(numel(varargin) <= 5, 'TextBounds takes w, text, size, font and wrapWidth.');
   a = [{[], [], []}, varargin(3:end), cell(1, 5 - numel(varargin))];
  end
  txt = varargin{2};
  assert(ischar(txt) || (isstring(txt) && isscalar(txt)), 'The text must be a character string.');
  txt = char(txt);
  assert(size(txt, 1) <= 1, 'The text must be one row of characters; separate lines with newline characters.');
  txt = reshape(txt, 1, []);
  textSize = floor((S.physicalRect(4) - S.physicalRect(2)) / 30 + 0.5);
  if ~isempty(a{4})
   textSize = a{4};
   assert(isnumeric(textSize) && isreal(textSize) && isscalar(textSize) && isfinite(textSize) && textSize > 0, ...
       'The text size must be a positive number of pixels.');
   textSize = double(textSize);
  end
  font = '';
  if ~isempty(a{5})
   font = a{5};
   assert(ischar(font) || (isstring(font) && isscalar(font)), 'The font must be a name.');
   font = reshape(char(font), 1, []);
  end
  wrapWidth = Inf;
  if ~isempty(a{6})
   wrapWidth = a{6};
   assert(isnumeric(wrapWidth) && isreal(wrapWidth) && isscalar(wrapWidth) && wrapWidth > 0, ...
       'The wrap width must be a positive number of pixels.');
   wrapWidth = double(wrapWidth);
  end
  % Lines, the size of each, and the distance from one line's top to the next.
  [lines, sizes, ascent] = layoutText(txt, font, textSize, wrapWidth);
  pitch = floor(1.3 * textSize + 0.5);
  block = [max(sizes(:,1)), (numel(lines) - 1) * pitch + max(sizes(:,2))];
  if ~drawing
   varargout = {[0 0 block], ascent};
  else
   pos = [NaN NaN];
   for k = 1:2
    if ~isempty(a{k})
     assert(isnumeric(a{k}) && isreal(a{k}) && isscalar(a{k}) && isfinite(a{k}), ...
         'The text position must be finite, in window pixels; [] centres it.');
     pos(k) = double(a{k});
    end
   end
   middle = [targetRect(1) + targetRect(3), targetRect(2) + targetRect(4)] / 2;
   top = pos(2);
   if isnan(top), top = floor(middle(2) - block(2) / 2 + 0.5); end
   rgba = colorToRGBA(a{3}, 'Text colour', S.colorRange);
   drawn = zeros(0, 4);
   for k = 1:numel(lines)
    if isempty(lines{k}), continue; end
    left = pos(1);
    if isnan(left), left = floor(middle(1) - sizes(k,1) / 2 + 0.5); end   % each line centred
    y = top + (k - 1) * pitch;
    b = PsychMetalCore('DrawText', lines{k}, font, textSize, left, y, rgba); %#ok<NASGU>
    l = floor(left + 0.5); t = floor(y + 0.5);
    drawn(end+1,:) = [l, t, l + sizes(k,1), t + sizes(k,2)]; %#ok<AGROW>
   end
   if isempty(drawn), where = [0 0 0 0];
   else, where = [min(drawn(:,1)), min(drawn(:,2)), max(drawn(:,3)), max(drawn(:,4))]; end
   varargout = {where, ascent};
  end

 case {'fillpoly','framepoly'}
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 3, 'PsychMetal(''%s'') requires the window handle, a colour and the points.', command);
  [S, ~] = useTarget(S, varargin{1}, command);
  framed = strcmpi(command, 'framepoly');
  assert(numel(varargin) <= 3 + framed, '%s takes w, colour and points%s.', command, repmat(', and a pen width', 1, framed));
  points = varargin{3};
  message = 'The points must be Nx2, one [x y] per row, with at least three.';
  assert(isnumeric(points) && isreal(points) && ~issparse(points) && ndims(points) == 2 && all(isfinite(points(:))), message);
  points = double(points);
  if size(points, 2) ~= 2 && size(points, 1) == 2, points = points'; end      % 2xN, as DrawDots takes
  assert(size(points, 2) == 2 && size(points, 1) >= 3, message);
  pen = 0;
  if framed
   pen = 1;
   if numel(varargin) == 4 && ~isempty(varargin{4})
    pen = varargin{4};
    assert(isnumeric(pen) && isreal(pen) && isscalar(pen) && isfinite(pen) && pen > 0, 'Pen width must be positive.');
    pen = double(pen);
   end
  end
  PsychMetalCore('DrawPolygon', points', colorToRGBA(varargin{2}, 'Polygon colour', S.colorRange), pen);

 case 'clip'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isWindow(S, varargin{1}), 'Clip requires the window handle from OpenWindow.');
  assert(numel(varargin) <= 2, 'Clip takes a window and an optional rect.');
  old = S.clip;
  if numel(varargin) == 2
   r = varargin{2};
   if isempty(r)
    PsychMetalCore('Clip');
    S.clip = [];
   else
    assert(isnumeric(r) && isreal(r) && ~issparse(r) && numel(r) == 4, ...
        'The clip rect must be [left top right bottom] in whole pixels.');
    r = double(r(:)');
    PsychMetalCore('Clip', r);
    S.clip = r;
   end
  end
  varargout = {old};

 case 'openoffscreenwindow'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'OpenOffscreenWindow requires the window handle from OpenWindow.');
  assert(numel(varargin) <= 3, 'OpenOffscreenWindow takes w, a colour and a rect.');
  colour = S.bgColor;
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   colour = colorToRGBA(varargin{2}, 'Offscreen window colour', S.colorRange);
  end
  r = S.physicalRect;
  if numel(varargin) >= 3 && ~isempty(varargin{3})
   r = varargin{3};
   assert(isnumeric(r) && isreal(r) && ~issparse(r) && numel(r) == 4 && all(isfinite(r(:))), ...
       'The offscreen window rect must be [left top right bottom] in whole pixels.');
   r = double(r(:)');
  end
  handle = PsychMetalCore('OpenOffscreen', r(3) - r(1), r(4) - r(2), colour);
  S.offscreen(end+1,:) = [handle, r(3) - r(1), r(4) - r(2)];
  S.textureSize(end+1,:) = [handle, r(3) - r(1), r(4) - r(2)];
  varargout = {handle, [0 0 r(3) - r(1), r(4) - r(2)]};

 case 'queueflip'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''QueueFlip'') requires w and a presentation time.');
  assert(isnumeric(varargin{2}) && isreal(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2}) && ...
      varargin{2} > 0, 'The presentation time must be a positive GetSecs timestamp.');
  out = PsychMetalCore('QueueFlip', double(varargin{2}));
  varargout = {out(1), out(2), out(3)};

 case 'queueresults'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && numel(varargin) <= 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''QueueResults'') requires w and an optional wait flag.');
  wait = true;
  if numel(varargin) == 2 && ~isempty(varargin{2}), wait = logicalFlag(varargin{2}, 'wait'); end
  varargout = {PsychMetalCore('QueueResults', double(wait))};

 case 'queuecancel'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''QueueCancel'') requires w.');
  varargout = {PsychMetalCore('QueueCancel')};

 case 'mouseevents'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''MouseEvents'') requires w.');
  [events, dropped] = PsychMetalCore('MouseEvents');
  varargout = {events, dropped};

 case 'linkinfo'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''LinkInfo'') requires w.');
  k = PsychMetalCore('LinkInfo');
  varargout = {struct('lanes',k(1), 'laneGbps',k(2), 'payloadGbps',k(3), 'pixelGbps',k(4), 'compressed',k(5))};

 case {'drawtexture','drawtextures'}
  % DrawTexture is DrawTextures with one texture; both are Screen's. Every
  % argument is one value for all draws or one per draw: rectangles 4xN,
  % colours 3xN/4xN. One native call draws them all, in order.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2, 'PsychMetal(''%s'') requires the window handle and a texture.', command);
  [S, targetRect] = useTarget(S, varargin{1}, command);
  assert(numel(varargin) <= 8, ['%s takes w, texture(s), srcRect(s), dstRect(s), angle(s), ' ...
      'filterMode(s), globalAlpha(s) and modulateColor(s).'], command);
  a = [varargin(2:end), cell(1, 8 - numel(varargin))];
  handles = a{1};
  assert(isnumeric(handles) && isreal(handles) && ~issparse(handles) && ~isempty(handles) && ...
      isvector(handles) && all(isfinite(handles(:))), 'Invalid texture handle.');
  handles = double(handles(:))';
  [known, rows] = ismember(handles, S.textureSize(:,1));
  assert(all(known), 'Unknown texture handle.');
  src = rectColumns(a{2}, 'srcRect must be [left top right bottom] in texture pixels, or 4xN.');
  dst = rectColumns(a{3}, 'dstRect must be [left top right bottom] in window pixels, or 4xN.');
  filterMessage = ['filterMode must be 0 (nearest) or 1 (bilinear), one or one per texture; ' ...
      'Screen''s mipmap and oversampled modes 2-4 have no Metal equivalent.'];
  angles = perDraw(a{4}, 'The rotation angle must be finite: one, or one per texture.');
  filters = perDraw(a{5}, filterMessage);
  assert(all(filters == 0 | filters == 1), filterMessage);
  alphas = perDraw(a{6}, 'globalAlpha must be finite: one, or one per texture.');
  colours = a{7};
  nColours = double(~isempty(colours));
  if ~isempty(colours) && ~isvector(colours), nColours = size(colours, 2); end
  counts = [numel(handles), size(src,2), size(dst,2), numel(angles), numel(filters), numel(alphas), nColours];
  n = max(counts);
  assert(all(counts <= 1 | counts == n), ...
      '%s: give each argument one value, or one per texture (%d).', command, n);
  if numel(rows) == 1, rows = repmat(rows, 1, n); end
  tw = S.textureSize(rows,2)'; th = S.textureSize(rows,3)';
  if isempty(src), src = [zeros(2,n); tw; th]; elseif size(src,2) == 1, src = repmat(src, 1, n); end
  if isempty(dst)
   % Native size, centred in what is drawn into.
   c = [targetRect(1) + targetRect(3); targetRect(2) + targetRect(4)] / 2;
   half = abs(src(3:4,:) - src(1:2,:)) / 2;
   dst = [c - half; c + half];
  elseif size(dst,2) == 1
   dst = repmat(dst, 1, n);
  end
  if isempty(angles), angles = 0; end
  if isempty(filters), filters = 1; end
  tint = expandColors(colours, n, S.colorRange);
  if ~isempty(alphas)
   ga = alphas / S.colorRange;
   out = find(ga > 1.001 | ga < -0.001, 1);
   if ~isempty(out)
    warning('PsychMetal:ColorRange', ['globalAlpha of %g is outside this window''s ColorRange ' ...
        'of %g and will be clamped.'], alphas(out), S.colorRange);
   end
   tint(4,:) = tint(4,:) .* min(max(ga, 0), 1);
  end
  PsychMetalCore('DrawTextures', repmat(handles, 1, n / numel(handles)), src ./ [tw; th; tw; th], ...
      [min(dst(1:2,:), dst(3:4,:)); max(dst(1:2,:), dst(3:4,:))], ...
      repmat(angles, 1, n / numel(angles)) * pi / 180, tint, repmat(filters, 1, n / numel(filters)));

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
  S.offscreen(S.offscreen(:,1)==handle,:)=[];
  if S.target==handle, S.target=0; end

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
    PsychMetalCore('SetMode', screenArg, double(varargin{2}), double(varargin{3}));
   end
   varargout = {old};
  end

 case 'rect'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isWindow(S, varargin{1}), 'Rect requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'Rect takes only the window handle.');
  varargout = {windowRect(S, varargin{1})};

 case 'windowsize'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isWindow(S, varargin{1}), 'WindowSize requires the window handle from OpenWindow.');
  assert(numel(varargin) == 1, 'WindowSize takes only the window handle.');
  r = windowRect(S, varargin{1});
  varargout = {r(3) - r(1), r(4) - r(2)};

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

 case 'setmouse'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''SetMouse'') requires the window handle from OpenWindow.');
  assert(numel(varargin) == 3, 'SetMouse takes the window handle, x and y.');
  for k = 2:3
   assert(isnumeric(varargin{k}) && isreal(varargin{k}) && isscalar(varargin{k}) && isfinite(varargin{k}), ...
       'SetMouse x and y must be finite real scalars, in window pixels.');
  end
  PsychMetalCore('SetMouse', double(varargin{2}), double(varargin{3}));

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

 case 'getimage'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer, ...
      'PsychMetal(''GetImage'') requires the window handle returned by OpenWindow.');
  assert(numel(varargin) <= 2, 'PsychMetal(''GetImage'') supports PsychMetal(''GetImage'', w [, rect]).');
  assert(S.readback, 'GetImage requires a window opened with readback.');
  if numel(varargin) == 2 && ~isempty(varargin{2})
   imageRect = varargin{2};
   assert(isnumeric(imageRect) && isreal(imageRect) && numel(imageRect) == 4, ...
       'GetImage rect must be [left top right bottom] in whole pixels inside the window.');
   varargout = {PsychMetalCore('GetImage', double(imageRect(:)'))};
  else
   varargout = {PsychMetalCore('GetImage')};
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
  assert(~isempty(varargin), 'A PsychMetal drawing command requires the window handle from OpenWindow.');
  [S, targetRect] = useTarget(S, varargin{1}, command);
  T = S; T.physicalRect = targetRect;        % defaults are those of what is drawn into
  [kind, param, rect, color, extra, info] = buildShapes(lower(command), varargin, T);
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
  % raw: time, confirmed, slip in refreshes, grid period, queue ms, call ms, return time, token
  S.lastQueueMs=raw(5); S.lastFlipMs=raw(6); flipReturn=raw(7);
  vbl = raw(1);
  S.lastVblConfirmed = raw(2) == 1;
  missed = 0;
  if haveWhen
   missed = vbl - when - raw(4);
  end
  slipped = 0;
  if isfinite(raw(3)), slipped = raw(3); end
  S.lastSlipRefreshes = slipped;
  if slipped ~= 0
   S.slipCount = S.slipCount + 1;
   S.lastSlipFlip = S.flipCount;
  end
  S.flipCount = S.flipCount + 1;
  screenCompatible = [vbl, vbl, flipReturn, missed, slipped];
  varargout = num2cell(screenCompatible);

 case 'flipinfo'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer, 'PsychMetal(''FlipInfo'') requires w.');
  % The display reports on a frame after Flip has returned, unless the session
  % waits for confirmation: what became of it is asked for now, not remembered.
  status = PsychMetalCore('FlipStatus');
  varargout = {struct('confirmed',status(1) == 1, 'dropped',status(2) == 1, ...
      'slipped',S.lastSlipRefreshes, 'queueMs',S.lastQueueMs, 'flipMs',S.lastFlipMs, ...
      'flips',S.flipCount, 'droppedFrames',status(3), 'slipFlips',S.slipCount)};

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
  summary.droppedFrames = summary.missingPresentedTimes;
  summary.bitDepth = S.bitDepth;
  summary.blendFunction = S.blend;
  summary.lastSlipFlip = S.lastSlipFlip;
  summary.lastSlipRefreshes = S.lastSlipRefreshes;
  actual = h(:,3);
  actualStatus = h(:,4); % 0 confirmed, 1 missing, 2 pending, 3 GPU error, 4 no drawable, 5 cancelled.
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
  sh=S.startupHistory;
  d.startup=struct('token',sh(:,1),'status',sh(:,2),'presentedTime',sh(:,3), ...
      'callbackTime',sh(:,4),'gpuDone',sh(:,5),'committedTime',sh(:,6),'seconds',S.startupSeconds);
  summary.startupAttempts=size(sh,1);summary.startupSeconds=S.startupSeconds;
  d.summary=summary;
  varargout={d};

 case 'close'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && isWindow(S, varargin{1}), ...
      'PsychMetal(''Close'') requires the window handle returned by OpenWindow.');
  if varargin{1} ~= S.buffer
   % An offscreen window: it is a texture, and closes as one.
   PsychMetal('CloseTexture', S.buffer, varargin{1});
   return;
  end
  PsychMetalCore('Close');
  S = [];

 case 'version'
  assert(isempty(varargin), 'PsychMetal(''Version'') takes no arguments.');
  varargout = {'0.6.0'};

 otherwise
  error('PsychMetal:Command', ...
      'Unknown PsychMetal command ''%s''. Call PsychMetal for a command list.', command);
end
end

function [S, rect] = useTarget(S, id, command)
% The window or offscreen window a drawing command names: draws go into it from
% now on, and rect is its own.
assert(isWindow(S, id), ['PsychMetal(''%s'') requires the window handle from OpenWindow, ' ...
    'or one from OpenOffscreenWindow.'], command);
rect = windowRect(S, id);
want = 0;
if id ~= S.buffer, want = id; end
if want ~= S.target
 PsychMetalCore('SetTarget', want);
 S.target = want;
end
end

function yes = isWindow(S, id)
yes = isnumeric(id) && isreal(id) && isscalar(id) && (id == S.buffer || any(S.offscreen(:,1) == id));
end

function rect = windowRect(S, id)
if id == S.buffer, rect = S.physicalRect;
else, rect = [0 0 S.offscreen(find(S.offscreen(:,1) == id, 1), 2:3)]; end
end

function [lines, sizes, ascent] = layoutText(txt, font, textSize, wrapWidth)
% Split text at newlines and, with a wrap width, between words; measure each
% line. sizes is [width height] per line; an empty line has width 0. The last
% sixteen layouts are kept, since a program draws the same text every frame.
persistent kept
key = [font char(10) sprintf('%.3f %g', textSize, wrapWidth) char(10) txt];
for k = 1:numel(kept)
 if strcmp(kept(k).key, key)
  lines = kept(k).lines; sizes = kept(k).sizes; ascent = kept(k).ascent;
  return;
 end
end
txt = strrep(strrep(txt, char([13 10]), char(10)), char(13), char(10));
paragraphs = regexp(txt, char(10), 'split');
lines = {};
if isfinite(wrapWidth)
 gap = PsychMetalCore('TextBounds', 'x x', font, textSize) - 2 * PsychMetalCore('TextBounds', 'x', font, textSize);
 space = gap(1) + 2;              % a space, without the two margins of each measured piece
 for p = 1:numel(paragraphs)
  words = regexp(strtrim(paragraphs{p}), ' +', 'split');
  line = ''; width = 0;
  for k = 1:numel(words)
   if isempty(words{k}), continue; end
   b = PsychMetalCore('TextBounds', words{k}, font, textSize);
   if ~isempty(line) && width + space + b(1) - 2 > wrapWidth - 2
    lines{end+1} = line; line = ''; width = 0; %#ok<AGROW>
   end
   if isempty(line), line = words{k}; width = b(1) - 2;
   else, line = [line ' ' words{k}]; width = width + space + b(1) - 2; end %#ok<AGROW>
  end
  lines{end+1} = line; %#ok<AGROW>
 end
else
 lines = paragraphs;
end
sizes = zeros(numel(lines), 2);
ascent = NaN;
for k = 1:numel(lines)
 if isempty(lines{k}), continue; end
 b = PsychMetalCore('TextBounds', lines{k}, font, textSize);
 sizes(k,:) = b(1:2);
 if isnan(ascent), ascent = b(3); end
end
assert(~isnan(ascent), 'The text must not be empty.');
entry = struct('key', key, 'lines', {lines}, 'sizes', sizes, 'ascent', ascent);
if isempty(kept), kept = entry; else, kept = [entry, kept(1:min(end, 15))]; end
end

function printGeneralHelp
names=commandNames();
fprintf('PsychMetal 0.6.0: native Metal on Apple Silicon.\n');
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
   'Or pass a scalar options struct with those fields (screen, backgroundColor) and optional refreshHz, readback, bitDepth.\n' ...
   'Colors default to 0..255. Use a fixed display refresh mode for timing.\n' ...
   'readback=true makes frames readable by GetImage. It is a diagnostic mode: take no timing from it.\n' ...
   'bitDepth=10 asks for ten bits per channel in the frame handed to the display; the default is 8.\n']);
 case 'getimage'
  fprintf(['image=PsychMetal(''GetImage'',w[,rect]) returns the last flipped frame as uint8 HxWx3 RGB,\n' ...
   'or as uint16 running 0..1023 from a window opened with bitDepth 10.\n' ...
   'The pixels are copied from the frame''s own drawable after rendering and before presentation.\n' ...
   'rect is [left top right bottom] in whole pixels; omit it for the whole frame.\n' ...
   'Requires PsychMetal(''OpenWindow'',struct(''readback'',true)). It shows what the GPU rendered,\n' ...
   'not what the display emitted. A full frame is width*height*3 bytes; pass a rect to keep many frames.\n']);
 case {'maketexture','updatetexture','drawtexture','drawtextures','closetexture'}
  fprintf(['tex=PsychMetal(''MakeTexture'',w,image); PsychMetal(''UpdateTexture'',w,tex,image);\n' ...
   'Dense HxW, HxWx3 or HxWx4: uint8 uses 0..255; single/double/logical use 0..1. Finite values clamp.\n' ...
   'PsychMetal(''DrawTexture'',w,tex[,srcRect,dstRect,angle,filterMode,globalAlpha,modulateColor]);\n' ...
   'Rectangles use pixels; angle uses degrees; filter 0 nearest or 1 linear. Alpha/color use ColorRange.\n' ...
   'PsychMetal(''DrawTextures'',w,texs[,srcRects,dstRects,angles,filterModes,globalAlphas,modulateColors]);\n' ...
   'draws many in one call, as Screen: each argument is one value or one per draw; rects 4xN, colors 3xN/4xN.\n' ...
   'PsychMetal(''CloseTexture'',w,tex); handles expire permanently on close. Queued draws retain their image.\n' ...
   'Four storage versions per texture bound queued/in-flight updates; Flip before exhausting the pool.\n' ...
   'PsychMetal(''UpdateTexture'',w,tex,image,rect) replaces only rect, [left top right bottom] in texture\n' ...
   'pixels and the size of the image, in place: use it to change a small part of a large texture.\n']);
 case 'blendfunction'
  fprintf(['old=PsychMetal(''BlendFunction'',w[,''alpha''|''add''|''copy'']) sets how what is drawn from now on\n' ...
   'combines with what is already there. ''alpha'' (the default) covers it in proportion to alpha; ''add''\n' ...
   'adds colour times alpha to it, so overlapping draws sum; ''copy'' replaces it, alpha included, which\n' ...
   'is how to clear an offscreen window to transparent. The mode is kept across Flip.\n']);
 case {'fillpoly','framepoly'}
  fprintf(['PsychMetal(''FillPoly'',w,color,points) fills a polygon: points is Nx2, one [x y] per row, closed\n' ...
   'automatically, concave or self-crossing as you like (even-odd rule). PsychMetal(''FramePoly'',w,color,\n' ...
   'points[,penWidth]) strokes its outline. Both are antialiased. A polygon is drawn on the CPU and kept\n' ...
   'by its shape, so one that only moves by whole pixels costs nothing more; very large ones are slow.\n']);
 case 'clip'
  fprintf(['old=PsychMetal(''Clip'',w,rect) confines everything drawn from now on to rect, [left top right\n' ...
   'bottom] in whole pixels of what is drawn into. PsychMetal(''Clip'',w,[]) ends it.\n']);
 case 'openoffscreenwindow'
  fprintf(['[woff,rect]=PsychMetal(''OpenOffscreenWindow'',w[,color,rect]) makes a window that is not shown.\n' ...
   'Draw into it with any drawing command by giving woff in place of w; what is drawn stays until it\n' ...
   'is drawn over. Then PsychMetal(''DrawTexture'',w,woff,...) draws it, as a texture, as often as you\n' ...
   'like. color is what it holds at first (default the window''s background); an alpha of 0 makes it\n' ...
   'transparent. rect gives its size (default the window''s). It holds half-float values, so nothing\n' ...
   'drawn into it is rounded. Where it is partly transparent, drawing it gives what the draws made into\n' ...
   'it would have given if made there directly, soft edges included, and a global alpha applies to all\n' ...
   'of it. PsychMetal(''Close'',woff) or CloseTexture frees it.\n']);
 case {'queueflip','queueresults','queuecancel'}
  fprintf(['[token,pending,capacity]=PsychMetal(''QueueFlip'',w,when) renders what is drawn now and returns at\n' ...
   'once; the frame is shown at the refresh at or after when, by a thread of its own. Queue frames in\n' ...
   'order of time, as far ahead as capacity allows (as many as fit in a gigabyte): the program can then\n' ...
   'be late by that many frames without one being missed. With every store in use QueueFlip waits.\n' ...
   'frames=PsychMetal(''QueueResults'',w[,wait]) waits (unless wait is false) and returns one row per frame:\n' ...
   '[requestedTime presentedTime status token]; status 0 shown, 1 dropped, 2 pending, 3 GPU error,\n' ...
   '4 no drawable, 5 cancelled. Each frame is reported once, with its outcome; one still pending when the\n' ...
   'wait ends (two seconds after the last frame''s time) is reported as pending, and again by the next call,\n' ...
   'until ten seconds after its own time.\n' ...
   'n=PsychMetal(''QueueCancel'',w) abandons frames not yet handed over.\n' ...
   'No frame is skipped: a late one is shown at the next refresh. Timing is not yet validated.\n']);
 case 'mouseevents'
  fprintf(['[events,dropped]=PsychMetal(''MouseEvents'',w) returns mouse-button presses and releases since the\n' ...
   'last call, one row each: [time button pressed x y], button 1 left, 2 right, 3 centre, x y in window\n' ...
   'pixels. The time is the one the event carries, not when it was read. The first call starts\n' ...
   'listening and returns nothing, so call it once before the trial.\n']);
 case 'linearize'
  fprintf(['PsychMetal(''Linearize'',w,gamma) makes every colour and texture value linear light for a display\n' ...
   'whose light is its input raised to gamma (one value, or [r g b]). Drawing and blending then happen\n' ...
   'in a 16-bit float frame and a last pass writes display values. PsychMetal(''Linearize'',w,table)\n' ...
   'takes an Nx3 table instead: the display value 0..1 for each of N evenly spaced linear values.\n' ...
   'PsychMetal(''Linearize'',w,[]) turns it off. It costs one more full-screen pass per frame.\n' ...
   'The table or gamma must come from a photometer; PsychMetal does not measure the display.\n']);
 case {'drawtext','textbounds'}
  fprintf(['[rect,ascent]=PsychMetal(''DrawText'',w,text[,x,y,color,size,font,wrapWidth]) draws text with its\n' ...
   'top left at x,y in pixels; [] for x centres each line and [] for y centres the block. Newlines\n' ...
   'separate lines, and wrapWidth (pixels) breaks lines between words. size is in pixels (default a\n' ...
   'thirtieth of the window height); font is a name (default Helvetica). rect is where it was drawn.\n' ...
   '[rect,ascent]=PsychMetal(''TextBounds'',w,text[,size,font,wrapWidth]) measures without drawing.\n' ...
   'Text is drawn in order with everything else. Each new line, font or size is rendered once and kept.\n']);
 case 'linkinfo'
  fprintf(['info=PsychMetal(''LinkInfo'',w) reports the DisplayPort link to the display: lanes, laneGbps,\n' ...
   'payloadGbps (what it can carry), pixelGbps (what this window needs) and compressed, which is 1 when\n' ...
   'the picture cannot fit and the link must be using Display Stream Compression. Fields are NaN when\n' ...
   'the link cannot be identified. Under compression, changing fine detail alters static detail near it.\n']);
 case {'flip','flipinfo','diagnostic','getflipinterval','latency'}
  fprintf(['[predictedOrConfirmed,onset,returned,missed,slipped]=PsychMetal(''Flip'',w[,when]);\n' ...
   'Default timestamps are predictions; waitForConfirm requests measured presentedTime at reduced throughput.\n' ...
   'A GPU failure, no drawable or a confirmation timeout raises an error. A frame that was submitted but\n' ...
   'never shown does not: Flip returns its projected time, and info=PsychMetal(''FlipInfo'',w) reports\n' ...
   'dropped for the last Flip and droppedFrames for the session, with confirmed, slipped, queueMs, flipMs.\n' ...
   'The display reports on a frame about a refresh after Flip returns (unless waitForConfirm); until then\n' ...
   'confirmed and dropped are both false, and the next Flip makes them about the next frame. In a loop\n' ...
   'that flips every refresh, read droppedFrames when the trial is over: it counts every frame reported\n' ...
   'never shown, queued ones included, whenever its report came.\n' ...
   'Predictions are not measured light onset. Variable refresh is not validated.\n' ...
   'PsychMetal(''Diagnostic'',w) drains pending work and returns confirmed history and stage timings.\n' ...
   'GetFlipInterval returns a period estimated from confirmed frame indices, or the initial nominal period.\n']);
 case {'kbqueuecreate','kbqueuestart','kbqueuestop','kbqueueflush','kbqueuerelease','kbqueuecheck','kbqueuegetevents','kbqueuestatus'}
  fprintf(['PsychMetal(''KbQueueCreate''[,denseMask256,pollSeconds]); PsychMetal(''KbQueueStart'');\n' ...
   '[events,dropped]=PsychMetal(''KbQueueGetEvents''); events are [detectionTime,HIDcode,pressed].\n' ...
   '[pressed,firstPress,firstRelease,lastPress,lastRelease]=PsychMetal(''KbQueueCheck'');\n' ...
   'KbQueueStop preserves events. Flush clears events/summaries and discards scans overlapping flush.\n' ...
   'KbQueueRelease frees the queue. KbQueueStatus reports polling intervals, overflow and secureInputPID.\n' ...
   'Where the application is allowed Input Monitoring, times are those the key events carry, and\n' ...
   'KbQueueStatus.eventTimestamps is 1; otherwise they are the times of the polling scans. See KEYBOARD-QUEUE.md.\n']);
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
names={'OpenWindow','MakeTexture','UpdateTexture','DrawTexture','DrawTextures','CloseTexture','PrefetchDrawable', ...
'BlendFunction','Linearize','DrawText','TextBounds','LinkInfo','FillPoly','FramePoly','Clip', ...
'OpenOffscreenWindow','QueueFlip','QueueResults','QueueCancel','MouseEvents', ...
'ColorRange','GetSecs','WaitSecs','Resolution','Resolutions','Rect','WindowSize','GetFlipInterval', ...
'BackgroundColor','GetMouse','SetMouse','HideCursor','ShowCursor','KbCheck','KbQueueCreate','KbQueueStart', ...
'KbQueueStop','KbQueueFlush','KbQueueRelease','KbQueueGetEvents','KbQueueCheck','KbQueueStatus', ...
'KbWait','KbName','GetImage','NoiseValues','FillRect','FrameRect','FillOval','FrameOval','DrawDots','DrawLines', ...
'DrawGabor','DrawNoise','Flip','FlipInfo','PrepareFlip','PresentNow','SetDisplaySync','GridAnchor','NextPhase', ...
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

function r = rectColumns(spec, message)
% DrawTextures rectangles: empty, one [l t r b] in any orientation, or 4xN.
if isempty(spec), r = zeros(4, 0); return; end
assert(isnumeric(spec) && isreal(spec) && ~issparse(spec) && ndims(spec) == 2, message);
r = double(spec);
if isvector(r) && numel(r) == 4, r = r(:); end
assert(size(r,1) == 4 && all(isfinite(r(:))), message);
end

function v = perDraw(spec, message)
% DrawTextures per-draw values: empty, one, or a vector with one per draw.
if isempty(spec), v = zeros(1, 0); return; end
assert((isnumeric(spec) || islogical(spec)) && isreal(spec) && ~issparse(spec) && ...
    isvector(spec) && all(isfinite(double(spec(:)))), message);
v = double(spec(:))';
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
