function varargout = PsychMetal(command, varargin)
% PsychMetal  Native Metal stimulus presentation on macOS. No OpenGL.
% Version 0.8.0. SPDX-License-Identifier: MIT.
%
% Checks are written "if ~(cond), error(...); end", and copies "x(:, ones(1, n))"
% or "x + zeros(1, n)": in Octave assert and repmat are interpreted functions
% that cost tens of microseconds on every call, which a frame loop pays.
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
 case 'makestimulus'
  if ~(numel(varargin)>=1 && numel(varargin)<=2), error('MakeStimulus takes kind and optional options struct.'); end;
  kind=varargin{1}; if ~(ischar(kind) && any(strcmp(kind,{'grating','noise'}))), error('kind must be grating or noise.'); end;
  options=struct(); if numel(varargin)==2,options=varargin{2};end
  p=[strcmp(kind,'noise') .5 .5 .5 1 .02 0 0 1 1 0 0 1 0 .35];
  varargout={struct('psychmetalStimulus',1,'parameters',stimulusParameters(p,options))};

 case 'makemask'
  if ~(numel(varargin)>=1 && numel(varargin)<=2), error('MakeMask takes kind and optional options struct.'); end;
  options=struct();if numel(varargin)==2,options=varargin{2};end
  varargout={struct('psychmetalMask',1,'parameters',makeMaskParameters(varargin{1},options))};

 case 'createshader'
  if ~(~isempty(S) && numel(varargin)==2 && isWindow(S,varargin{1})), error('CreateShader takes w and Metal source.'); end;
  shader=PsychMetalCore('CreateShader',varargin{2});S.shaders(end+1)=shader;varargout={shader};
 case 'closeshader'
  if ~(~isempty(S) && numel(varargin)==2 && isWindow(S,varargin{1})), error('CloseShader takes w and shader.'); end;
  PsychMetalCore('CloseShader',varargin{2});S.shaders(S.shaders==varargin{2})=[];
 case 'drawshader'
  if ~(~isempty(S) && numel(varargin)>=2 && numel(varargin)<=6 && isWindow(S,varargin{1})), error('DrawShader takes w, shader, parameters, dst, mask, coverage.'); end;
  a=varargin;a(end+1:6)={[]};
  if ~(isnumeric(a{2}) && isreal(a{2}) && isscalar(a{2}) && any(S.shaders==a{2})), error('Invalid shader handle.'); end;
  values=a{3};if ~(isnumeric(values) && isreal(values) && ~issparse(values) && numel(values)<=16 && all(isfinite(values(:))) && all(abs(values(:))<=1e6)), error('At most sixteen finite shader parameters, bounded to +/-1000000.'); end;
  p=zeros(1,16);p(1:numel(values))=double(values(:)');
  dst=windowRect(S,a{1});if ~isempty(a{4}),dst=a{4};end
  if ~(isnumeric(dst) && isreal(dst) && ~issparse(dst) && numel(dst)==4 && all(isfinite(dst(:))) && all(abs(dst(:))<=1e6)), error('Invalid shader destination.'); end;
  dst=double(dst(:)');if ~(dst(3)>dst(1) && dst(4)>dst(2)), error('Shader destination must have positive size.'); end;
  mask=a{5};if isempty(mask),mask=0;end
  coverage=a{6};if isstruct(mask),if ~(isempty(coverage)), error('Supply an analytic mask only once.'); end;coverage=mask;mask=0;end
  if ~isempty(coverage),coverage=maskParameters(coverage);end
  [S,~]=useTarget(S,a{1},'DrawShader');
  if isempty(coverage),PsychMetalCore('DrawShader',a{2},p,dst,mask);
  else,PsychMetalCore('DrawShader',a{2},p,dst,mask,coverage);end

 case 'drawmaskedtexture'
  if ~(~isempty(S) && numel(varargin)>=2 && numel(varargin)<=10), error('DrawMaskedTexture takes w, texture, mask, src, dst, angle, filter, alpha, tint, coverage.'); end;
  a=varargin;a(end+1:10)={[]};
  if ~(isWindow(S,a{1})), error('DrawMaskedTexture requires a window.'); end;
  if ~(isnumeric(a{2}) && isreal(a{2}) && isscalar(a{2})), error('Invalid texture handle.'); end;
  hit=find(S.textureSize(:,1)==a{2},1);if ~(~isempty(hit)), error('Unknown texture handle.'); end;
  wh=S.textureSize(hit,2:3);sz=[wh wh];src=[0 0 wh];
  if ~isempty(a{4}),src=a{4};end
  if ~(isnumeric(src) && isreal(src) && ~issparse(src) && numel(src)==4 && all(isfinite(src(:)))), error('Invalid source crop.'); end;
  src=double(src(:)');if ~(all(src>=0) && all(src<=sz) && src(3)>src(1) && src(4)>src(2)), error('Crop must have positive size and lie inside the image.'); end;
  target=windowRect(S,a{1});centre=(target(1:2)+target(3:4))/2;half=(src(3:4)-src(1:2))/2;dst=[centre-half centre+half];
  if ~isempty(a{5}),dst=a{5};end
  if ~(isnumeric(dst) && isreal(dst) && ~issparse(dst) && numel(dst)==4 && all(isfinite(dst(:))) && all(abs(dst(:))<=1e6)), error('Invalid destination.'); end;
  dst=double(dst(:)');if ~(dst(3)>dst(1) && dst(4)>dst(2)), error('Destination must have positive size.'); end;
  angle=0;if ~isempty(a{6}),angle=a{6};end
  if ~(isnumeric(angle) && isreal(angle) && isscalar(angle) && isfinite(angle) && abs(angle)<=1e6), error('Invalid angle.'); end;
  filter=1;if ~isempty(a{7}),filter=a{7};end
  if ~(isnumeric(filter) && isreal(filter) && isscalar(filter) && any(filter==[0 1])), error('Filter must be 0 or 1.'); end;
  tint=colorToRGBA(a{9},'Image tint',S.colorRange);
  if ~isempty(a{8})
   alpha=a{8};if ~(isnumeric(alpha) && isreal(alpha) && isscalar(alpha) && isfinite(alpha) && alpha>=0 && alpha<=S.colorRange), error('Alpha must be inside ColorRange.'); end;
   tint(4)=tint(4)*double(alpha)/S.colorRange;
  end
  mask=a{3};coverage=a{10};if isempty(mask),mask=0;end
  if isstruct(mask),if ~(isempty(coverage)), error('Supply an analytic mask only once.'); end;coverage=mask;mask=0;end
  if ~isempty(coverage),coverage=maskParameters(coverage);end
  [S,~]=useTarget(S,a{1},'DrawMaskedTexture');
  p=[src./sz dst tint double(angle)*pi/180 double(filter)];
  if isempty(coverage),PsychMetalCore('DrawMaskedTexture',a{2},p,mask);
  else,PsychMetalCore('DrawMaskedTexture',a{2},p,mask,coverage);end

 case 'drawstimulus' 
  if ~(numel(varargin)>=2 && numel(varargin)<=6), error('DrawStimulus takes w, recipe, optional rect, mask, overrides, coverage.'); end;
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  recipe=varargin{2};
  if ~(isstruct(recipe) && isscalar(recipe) && isfield(recipe,'psychmetalStimulus') && ...
      isequal(recipe.psychmetalStimulus,1) && isfield(recipe,'parameters')), error('Use MakeStimulus to create a recipe.'); end;
  options=struct(); if numel(varargin)>=5 && ~isempty(varargin{5}),options=varargin{5};end
  p=stimulusParameters(recipe.parameters,options);
  if ~(isWindow(S,varargin{1})), error('DrawStimulus needs a window handle.'); end;
  dst=windowRect(S,varargin{1}); if numel(varargin)>=3 && ~isempty(varargin{3}),dst=varargin{3};end
  if ~(isnumeric(dst) && isreal(dst) && ~issparse(dst) && numel(dst)==4 && all(isfinite(dst(:)))), error('Invalid stimulus rect.'); end;
  dst=double(dst(:)'); if ~(dst(3)>dst(1) && dst(4)>dst(2)), error('Stimulus rect must have positive size.'); end;
  mask=0; if numel(varargin)>=4 && ~isempty(varargin{4}),mask=varargin{4};end
  coverage=[];if numel(varargin)>=6 && ~isempty(varargin{6}),coverage=varargin{6};end
  if isstruct(mask)
   if ~(isempty(coverage)), error('Supply an analytic mask only once.'); end;coverage=mask;mask=0;
  end
  if ~isempty(coverage),coverage=maskParameters(coverage);end
  [S,~]=useTarget(S,varargin{1},'DrawStimulus');
  if isempty(coverage),PsychMetalCore('DrawStimulus',p,dst,mask);
  else,PsychMetalCore('DrawStimulus',p,dst,mask,coverage);end

 case 'playtimeline'
  if ~(numel(varargin)>=2 && numel(varargin)<=4 && ~isempty(S) && isscalar(varargin{1}) && varargin{1}==S.buffer), error(...
      'PlayTimeline requires w, frame count, optional tracks and keyframes.'); end;
  frames=varargin{2};
  if ~(isnumeric(frames) && isreal(frames) && isscalar(frames) && isfinite(frames) && frames>=1 && frames<=1000000 && frames==floor(frames)), error(...
      'Timeline frames must be integers from 1 to 1000000.'); end;
  tracks=zeros(0,6);if numel(varargin)>=3,tracks=varargin{3};end
  if ~(isnumeric(tracks) && isreal(tracks) && ~issparse(tracks) && ismatrix(tracks) && size(tracks,2)==6), error(...
      'Timeline tracks must be N x 6 real numbers.'); end;
  tracks=double(tracks);tracks(:,1)=tracks(:,1)-1; % MATLAB draw indices are one-based
  keys=zeros(0,4);if numel(varargin)==4 && ~isempty(varargin{4}),keys=varargin{4};end
  if ~(isnumeric(keys) && isreal(keys) && ~issparse(keys) && ismatrix(keys) && size(keys,2)==4), error('Keyframes must be N x 4 [draw parameter sample value].'); end;
  keys=double(keys);keys(:,1)=keys(:,1)-1;
  result=PsychMetalCore('PlayTimeline',double(frames),tracks,keys);
  if result.submitted>0
   S.lastQueueMs=result.lastQueueMs;S.lastFlipMs=result.lastFlipMs;S.lastVblConfirmed=result.lastConfirmed;
   S.flipCount=S.flipCount+result.submitted;
  end
  varargout={result};

 case 'openwindow' 
  if ~(isempty(S)), error('PsychMetal is already open. Close the existing window first.'); end;
  refreshHz=[]; readback=false; bitDepth=8; presentation='auto';
  if numel(varargin)==1 && isstruct(varargin{1}) && isscalar(varargin{1})
   options=varargin{1}; allowed={'screen','backgroundColor','drawableCount','waitForConfirm','displaySync','captureDisplay','refreshHz','readback','bitDepth','presentation'};
   if ~(all(ismember(fieldnames(options),allowed))), error('Unknown OpenWindow option.'); end;
   varargin=cell(1,6);
   for j=1:6, if isfield(options,allowed{j}), varargin{j}=options.(allowed{j}); end; end
   if isfield(options,'presentation'), presentation=options.presentation; end
   if ~(ischar(presentation) && any(strcmp(presentation,{'auto','direct','displaylink'}))), error(...
       'presentation must be auto, direct or displaylink.'); end;
   if isfield(options,'refreshHz'), refreshHz=options.refreshHz; end
   if isfield(options,'readback') && ~isempty(options.readback)
    if ~(isscalar(options.readback) && (islogical(options.readback) || isnumeric(options.readback))), error(...
        'readback must be a logical scalar.'); end;
    readback=logicalFlag(options.readback,'readback');
   end
   if isfield(options,'bitDepth') && ~isempty(options.bitDepth)
    bitDepth=options.bitDepth;
    if ~(isnumeric(bitDepth) && isreal(bitDepth) && isscalar(bitDepth) && any(bitDepth==[8 10])), error(...
        'bitDepth must be 8 or 10.'); end;
    bitDepth=double(bitDepth);
   end
  end
  if ~isempty(refreshHz)
   if ~(isnumeric(refreshHz) && isreal(refreshHz) && isscalar(refreshHz) && isfinite(refreshHz) && refreshHz>=20 && refreshHz<=1000), error('refreshHz must be 20..1000.'); end;
  end
  if ~(numel(varargin) <= 6), error(...
      ['OpenWindow accepts screen number, background colour, drawable count, ' ...
       'wait-for-confirmation, displaySync and captureDisplay.']); end;
  screen = -1;
  if ~isempty(varargin) && ~isempty(varargin{1})
   if ~(isnumeric(varargin{1}) && isreal(varargin{1}) && isscalar(varargin{1})), error(...
       'Screen number must be a real numeric scalar.'); end;
   screen = double(varargin{1});
   if ~(isfinite(screen) && screen == fix(screen) && screen >= 0), error(...
       'Screen number must be a non-negative integer.'); end;
  end
  colorRange = 255;
  bgColor = [0 0 0 1];
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   bgColor = colorToRGBA(varargin{2}, 'Background colour', colorRange);
  end
  drawableCount = 3;
  if numel(varargin) >= 3 && ~isempty(varargin{3})
   if ~(isnumeric(varargin{3}) && isreal(varargin{3}) && isscalar(varargin{3})), error(...
       'Maximum drawable count must be 2 or 3.'); end;
   drawableCount = double(varargin{3});
   if ~(isfinite(drawableCount) && any(drawableCount == [2 3])), error(...
       'Maximum drawable count must be 2 or 3.'); end;
  end
  prefetch = (drawableCount >= 3);
  waitForConfirm = false;
  if numel(varargin) >= 4 && ~isempty(varargin{4})
   if ~(isscalar(varargin{4}) && (islogical(varargin{4}) || isnumeric(varargin{4}))), error(...
       'Wait-for-confirmation must be a logical scalar.'); end;
   waitForConfirm = logicalFlag(varargin{4},'waitForConfirm');
  end
  vsync = true;
  if numel(varargin) >= 5 && ~isempty(varargin{5})
   if ~(isscalar(varargin{5}) && (islogical(varargin{5}) || isnumeric(varargin{5}))), error(...
       'displaySync must be a logical scalar.'); end;
   vsync = logicalFlag(varargin{5},'vsync');
  end
  captureDisplay = true;
  if numel(varargin) >= 6 && ~isempty(varargin{6})
   if ~(isscalar(varargin{6}) && (islogical(varargin{6}) || isnumeric(varargin{6}))), error(...
       'captureDisplay must be a logical scalar.'); end;
   captureDisplay = logicalFlag(varargin{6},'captureDisplay');
  end
  try
   abi=PsychMetalCore('Version');
   if ~(strcmp(abi,'0.8.0')), error('PsychMetal wrapper/core version mismatch: expected 0.8.0, found %s.', abi); end;
   if strcmp(presentation,'auto')
    if PsychMetalCore('DefaultPresentation'), presentation='displaylink'; else, presentation='direct'; end
   end
   linked=strcmp(presentation,'displaylink');
   if ~(~linked || vsync), error('Display-link presentation requires displaySync.'); end;
   PsychMetalCore('PrepareApp');
   openArgs={screen,drawableCount,double(waitForConfirm),double(vsync),double(captureDisplay)};
   % Trailing arguments are sent only as far as the last one that is not its
   % default. The core takes [] for "no refresh override".
   deep=bitDepth~=8;
   if ~isempty(refreshHz) || readback || deep || linked, openArgs{end+1}=refreshHz; end
   if readback || deep || linked, openArgs{end+1}=double(readback); end
   if deep || linked, openArgs{end+1}=bitDepth; end
   if linked, openArgs{end+1}=1; end
   [width,height,ifi,pointW,pointH,nativeWindowToken]=PsychMetalCore('Open',openArgs{:});
   displayRect = [0 0 width height];
   physicalRect = displayRect;
   logicalRect = [0 0 pointW pointH];
   PsychMetalCore('SetBackgroundColor', bgColor(1), bgColor(2), bgColor(3), bgColor(4));
   startupBegan=tic;
   startup=PsychMetalCore('ConfirmStartup');
   startupSeconds=toc(startupBegan);
   fprintf('PsychMetal: %dx%d at %.3f Hz. %s Metal presentation, no OpenGL.\n', ...
       width, height, 1/ifi, presentation);
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
      'colorRange',colorRange, 'shaders',[], 'textureSize',zeros(0,3), ...
      'logicalRect',logicalRect, ...
      'physicalRect',physicalRect, ...
      'bgColor',bgColor, 'startupHistory',startup,'startupSeconds',startupSeconds, ...
      'presentation',presentation, 'drawableCount',drawableCount, ...
      'waitForConfirm',waitForConfirm, 'readback',readback, 'bitDepth',bitDepth, ...
      'blend','alpha', 'linearize',[], 'offscreen',zeros(0,3), 'target',0, 'clip',[], ...
      'lastVblConfirmed',false, ...
      'lastQueueMs',NaN,'lastFlipMs',NaN, ...
      'flipCount',0,'slipCount',0,'lastSlipFlip',NaN,'lastSlipRefreshes',0);
 if prefetch && ~linked
  PsychMetalCore('PrefetchDrawable', 1);
 end
 varargout = {buffer, displayRect, ifi};

 case 'maketexture'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) >= 2 && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''MakeTexture'') requires the window handle and an image.'); end;
  if ~(numel(varargin) == 2), error('MakeTexture takes a window and an image.'); end;
  handle = PsychMetalCore('MakeTexture', varargin{2});
  S.textureSize(end+1,:) = [handle size(varargin{2},2) size(varargin{2},1)];
  varargout = {handle};

 case 'updatetexture'
  if ~(~isempty(S) && any(numel(varargin)==[3 4]) && isequal(varargin{1},S.buffer)), error(...
      'UpdateTexture requires w, texture, image and an optional rect.'); end;
  handle=varargin{2};
  if ~(isnumeric(handle) && isreal(handle) && isscalar(handle) && isfinite(handle)), error('Invalid texture handle.'); end;
  row=find(S.textureSize(:,1)==handle,1);
  if ~(~isempty(row)), error('Unknown texture handle.'); end;
  if numel(varargin)==4 && ~isempty(varargin{4})
   % Part of the texture, in place: its size and handle stay as they are.
   part=varargin{4};
   message='The UpdateTexture rect must be [left top right bottom] in whole texture pixels, the size of the image.';
   if ~(isnumeric(part) && isreal(part) && ~issparse(part) && numel(part)==4 && all(isfinite(part(:)))), error(message); end;
   part=double(part(:)');
   if ~(all(part==fix(part)) && part(3)-part(1)==size(varargin{3},2) && part(4)-part(2)==size(varargin{3},1)), error(message); end;
   PsychMetalCore('UpdateTexture',handle,varargin{3},part(1),part(2));
  else
   PsychMetalCore('UpdateTexture',handle,varargin{3});
   S.textureSize(row,2:3)=[size(varargin{3},2) size(varargin{3},1)];
  end

 case 'blendfunction'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isWindow(S, varargin{1})), error(...
      'BlendFunction requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) <= 2), error('BlendFunction takes a window and an optional mode.'); end;
  old = S.blend;
  if numel(varargin) == 2 && ~isempty(varargin{2})
   mode = varargin{2};
   modes = {'alpha','add','copy'};
   if ~(ischar(mode) || (isstring(mode) && isscalar(mode))), error('The blend mode must be ''alpha'', ''add'' or ''copy''.'); end;
   mode = lower(char(mode));
   if ~(any(strcmp(mode, modes))), error('The blend mode must be ''alpha'', ''add'' or ''copy''.'); end;
   PsychMetalCore('BlendMode', find(strcmp(mode, modes)) - 1);
   S.blend = mode;
  end
  varargout = {old};

 case 'linearize'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'Linearize requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) <= 2), error('Linearize takes a window and an optional gamma or table.'); end;
  old = S.linearize;
  if numel(varargin) == 2
   spec = varargin{2};
   message = ['Linearize takes the display''s gamma (one value or [r g b], each 0.05 to 20), ' ...
       'an Nx3 table of display values 0..1 with N from 2 to 4096, or [] to turn it off.'];
   if ~(isempty(spec) || (isnumeric(spec) && isreal(spec) && ~issparse(spec) && ndims(spec) == 2 && ...
       all(isfinite(spec(:))))), error(message); end;
   spec = double(spec);
   if isempty(spec)
    PsychMetalCore('Gamma', 1, 1, 1);
   elseif isvector(spec) && any(numel(spec) == [1 3])
    g = spec(:)' .* ones(1, 3);
    if ~(all(g >= 0.05 & g <= 20)), error(message); end;
    % The display raises its input to gamma, so the frame is raised to 1/gamma.
    PsychMetalCore('Gamma', 1/g(1), 1/g(2), 1/g(3));
   else
    if ~(size(spec, 2) == 3 && size(spec, 1) >= 2 && size(spec, 1) <= 4096 && ...
        all(spec(:) >= 0 & spec(:) <= 1)), error(message); end;
    PsychMetalCore('GammaTable', spec);
   end
   S.linearize = spec;
  end
  varargout = {old};

 case {'drawtext','textbounds'}
  % DrawText: w, text, x, y, colour, size, font, wrapWidth. TextBounds: w, text, size, font, wrapWidth.
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) >= 2), error('PsychMetal(''%s'') requires the window handle and the text.', command); end;
  drawing = strcmpi(command, 'drawtext');
  if drawing
   [S, targetRect] = useTarget(S, varargin{1}, command);
   if ~(numel(varargin) <= 8), error('DrawText takes w, text, x, y, colour, size, font and wrapWidth.'); end;
   a = [varargin(3:end), cell(1, 8 - numel(varargin))];
  else
   if ~(isWindow(S, varargin{1})), error('PsychMetal(''TextBounds'') requires the window handle and the text.'); end;
   if ~(numel(varargin) <= 5), error('TextBounds takes w, text, size, font and wrapWidth.'); end;
   a = [{[], [], []}, varargin(3:end), cell(1, 5 - numel(varargin))];
  end
  txt = varargin{2};
  if ~(ischar(txt) || (isstring(txt) && isscalar(txt))), error('The text must be a character string.'); end;
  txt = char(txt);
  if ~(size(txt, 1) <= 1), error('The text must be one row of characters; separate lines with newline characters.'); end;
  txt = reshape(txt, 1, []);
  textSize = floor((S.physicalRect(4) - S.physicalRect(2)) / 30 + 0.5);
  if ~isempty(a{4})
   textSize = a{4};
   if ~(isnumeric(textSize) && isreal(textSize) && isscalar(textSize) && isfinite(textSize) && textSize > 0), error(...
       'The text size must be a positive number of pixels.'); end;
   textSize = double(textSize);
  end
  font = '';
  if ~isempty(a{5})
   font = a{5};
   if ~(ischar(font) || (isstring(font) && isscalar(font))), error('The font must be a name.'); end;
   font = reshape(char(font), 1, []);
  end
  wrapWidth = Inf;
  if ~isempty(a{6})
   wrapWidth = a{6};
   if ~(isnumeric(wrapWidth) && isreal(wrapWidth) && isscalar(wrapWidth) && wrapWidth > 0), error(...
       'The wrap width must be a positive number of pixels.'); end;
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
     if ~(isnumeric(a{k}) && isreal(a{k}) && isscalar(a{k}) && isfinite(a{k})), error(...
         'The text position must be finite, in window pixels; [] centres it.'); end;
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
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) >= 3), error('PsychMetal(''%s'') requires the window handle, a colour and the points.', command); end;
  [S, ~] = useTarget(S, varargin{1}, command);
  framed = strcmpi(command, 'framepoly');
  if ~(numel(varargin) <= 3 + framed), error('%s takes w, colour and points%s.', command, repmat(', and a pen width', 1, framed)); end;
  points = varargin{3};
  message = 'The points must be Nx2, one [x y] per row, with at least three.';
  if ~(isnumeric(points) && isreal(points) && ~issparse(points) && ndims(points) == 2 && all(isfinite(points(:)))), error(message); end;
  points = double(points);
  if size(points, 2) ~= 2 && size(points, 1) == 2, points = points'; end      % 2xN, as DrawDots takes
  if ~(size(points, 2) == 2 && size(points, 1) >= 3), error(message); end;
  pen = 0;
  if framed
   pen = 1;
   if numel(varargin) == 4 && ~isempty(varargin{4})
    pen = varargin{4};
    if ~(isnumeric(pen) && isreal(pen) && isscalar(pen) && isfinite(pen) && pen > 0), error('Pen width must be positive.'); end;
    pen = double(pen);
   end
  end
  PsychMetalCore('DrawPolygon', points', colorToRGBA(varargin{2}, 'Polygon colour', S.colorRange), pen);

 case 'clip'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isWindow(S, varargin{1})), error('Clip requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) <= 2), error('Clip takes a window and an optional rect.'); end;
  old = S.clip;
  if numel(varargin) == 2
   r = varargin{2};
   if isempty(r)
    PsychMetalCore('Clip');
    S.clip = [];
   else
    if ~(isnumeric(r) && isreal(r) && ~issparse(r) && numel(r) == 4), error(...
        'The clip rect must be [left top right bottom] in whole pixels.'); end;
    r = double(r(:)');
    PsychMetalCore('Clip', r);
    S.clip = r;
   end
  end
  varargout = {old};

 case 'openoffscreenwindow'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'OpenOffscreenWindow requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) <= 3), error('OpenOffscreenWindow takes w, a colour and a rect.'); end;
  colour = S.bgColor;
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   colour = colorToRGBA(varargin{2}, 'Offscreen window colour', S.colorRange);
  end
  r = S.physicalRect;
  if numel(varargin) >= 3 && ~isempty(varargin{3})
   r = varargin{3};
   if ~(isnumeric(r) && isreal(r) && ~issparse(r) && numel(r) == 4 && all(isfinite(r(:)))), error(...
       'The offscreen window rect must be [left top right bottom] in whole pixels.'); end;
   r = double(r(:)');
  end
  handle = PsychMetalCore('OpenOffscreen', r(3) - r(1), r(4) - r(2), colour);
  S.offscreen(end+1,:) = [handle, r(3) - r(1), r(4) - r(2)];
  S.textureSize(end+1,:) = [handle, r(3) - r(1), r(4) - r(2)];
  varargout = {handle, [0 0 r(3) - r(1), r(4) - r(2)]};

 case 'queueflip'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''QueueFlip'') requires w and a presentation time.'); end;
  if ~(isnumeric(varargin{2}) && isreal(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2}) && ...
      varargin{2} > 0), error('The presentation time must be a positive GetSecs timestamp.'); end;
  out = PsychMetalCore('QueueFlip', double(varargin{2}));
  varargout = {out(1), out(2), out(3)};

 case 'queueresults'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && numel(varargin) <= 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''QueueResults'') requires w and an optional wait flag.'); end;
  wait = true;
  if numel(varargin) == 2 && ~isempty(varargin{2}), wait = logicalFlag(varargin{2}, 'wait'); end
  varargout = {PsychMetalCore('QueueResults', double(wait))};

 case 'queuecancel'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''QueueCancel'') requires w.'); end;
  varargout = {PsychMetalCore('QueueCancel')};

 case 'mouseevents'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''MouseEvents'') requires w.'); end;
  [events, dropped] = PsychMetalCore('MouseEvents');
  varargout = {events, dropped};

 case 'touchevents'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''TouchEvents'') requires w.'); end;
  [events, dropped] = PsychMetalCore('TouchEvents');
  varargout = {events, dropped};

 case 'linkinfo'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''LinkInfo'') requires w.'); end;
  k = PsychMetalCore('LinkInfo');
  varargout = {struct('lanes',k(1), 'laneGbps',k(2), 'payloadGbps',k(3), 'pixelGbps',k(4), 'compressed',k(5))};

 case {'drawtexture','drawtextures'}
  % DrawTexture is DrawTextures with one texture; both are Screen's. Every
  % argument is one value for all draws or one per draw: rectangles 4xN,
  % colours 3xN/4xN. One native call draws them all, in order.
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) >= 2), error('PsychMetal(''%s'') requires the window handle and a texture.', command); end;
  [S, targetRect] = useTarget(S, varargin{1}, command);
  if ~(numel(varargin) <= 8), error(['%s takes w, texture(s), srcRect(s), dstRect(s), angle(s), ' ...
      'filterMode(s), globalAlpha(s) and modulateColor(s).'], command); end;
  a = [varargin(2:end), cell(1, 8 - numel(varargin))];
  handles = a{1};
  if ~(isnumeric(handles) && isreal(handles) && ~issparse(handles) && ~isempty(handles) && ...
      isvector(handles) && all(isfinite(handles(:)))), error('Invalid texture handle.'); end;
  handles = double(handles(:))';
  [known, rows] = ismember(handles, S.textureSize(:,1));
  if ~(all(known)), error('Unknown texture handle.'); end;
  src = rectColumns(a{2}, 'srcRect must be [left top right bottom] in texture pixels, or 4xN.');
  dst = rectColumns(a{3}, 'dstRect must be [left top right bottom] in window pixels, or 4xN.');
  filterMessage = ['filterMode must be 0 (nearest) or 1 (bilinear), one or one per texture; ' ...
      'Screen''s mipmap and oversampled modes 2-4 have no Metal equivalent.'];
  angles = perDraw(a{4}, 'The rotation angle must be finite: one, or one per texture.');
  filters = perDraw(a{5}, filterMessage);
  if ~(all(filters == 0 | filters == 1)), error(filterMessage); end;
  alphas = perDraw(a{6}, 'globalAlpha must be finite: one, or one per texture.');
  colours = a{7};
  nColours = double(~isempty(colours));
  if ~isempty(colours) && ~isvector(colours), nColours = size(colours, 2); end
  counts = [numel(handles), size(src,2), size(dst,2), numel(angles), numel(filters), numel(alphas), nColours];
  n = max(counts);
  if ~(all(counts <= 1 | counts == n)), error(...
      '%s: give each argument one value, or one per texture (%d).', command, n); end;
  if numel(rows) == 1, rows = rows(ones(1, n)); end
  tw = S.textureSize(rows,2)'; th = S.textureSize(rows,3)';
  if isempty(src), src = [zeros(2,n); tw; th]; elseif size(src,2) == 1, src = src(:, ones(1, n)); end
  if isempty(dst)
   % Native size, centred in what is drawn into.
   c = [targetRect(1) + targetRect(3); targetRect(2) + targetRect(4)] / 2;
   half = abs(src(3:4,:) - src(1:2,:)) / 2;
   dst = [c - half; c + half];
  elseif size(dst,2) == 1
   dst = dst(:, ones(1, n));
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
  PsychMetalCore('DrawTextures', handles + zeros(1, n), src ./ [tw; th; tw; th], ...
      [min(dst(1:2,:), dst(3:4,:)); max(dst(1:2,:), dst(3:4,:))], ...
      (angles + zeros(1, n)) * pi / 180, tint, filters + zeros(1, n));

 case 'closetexture'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) >= 2 && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''CloseTexture'') requires the window handle and a texture.'); end;
  if ~(numel(varargin) == 2), error('CloseTexture takes a window and a texture.'); end;
  handle=varargin{2};
  if ~(isnumeric(handle) && isreal(handle) && isscalar(handle) && isfinite(handle)), error('Invalid texture handle.'); end;
  row=find(S.textureSize(:,1)==handle,1);
  if ~(~isempty(row)), error('Unknown texture handle.'); end;
  PsychMetalCore('CloseTexture',handle);
  S.textureSize(row,:)=[];
  S.offscreen(S.offscreen(:,1)==handle,:)=[];
  if S.target==handle, S.target=0; end

 case 'prefetchdrawable'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 2 && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''PrefetchDrawable'') needs the window handle and a logical.'); end;
  on = logicalFlag(varargin{2},'prefetch');
  if on && S.drawableCount < 3
   warning('PsychMetal:PrefetchStarvesPool', ...
       ['Prefetching with %d drawables starves the pool and halves the ' ...
        'presentation rate. Open the window with 3 drawables instead.'], ...
       S.drawableCount);
  end
  PsychMetalCore('PrefetchDrawable', double(on));

 case 'colorrange'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'ColorRange requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) <= 2), error('ColorRange takes a window and an optional range.'); end;
  old = S.colorRange;
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   r = double(varargin{2});
   if ~(isscalar(r) && isfinite(r) && r > 0), error('ColorRange must be a positive scalar.'); end;
   S.colorRange = r;
  end
  varargout = {old};

 case 'getsecs'
  if ~(isempty(varargin)), error('GetSecs takes no arguments.'); end;
  varargout = {PsychMetalCore('Now')};

 case 'waitsecs'
  if ~(~isempty(varargin)), error('WaitSecs needs a duration or ''UntilTime''.'); end;
  if ischar(varargin{1}) || isstring(varargin{1})
   if ~(strcmpi(char(varargin{1}), 'untiltime')), error(...
       'The only string form is PsychMetal(''WaitSecs'', ''UntilTime'', t).'); end;
   if ~(numel(varargin) == 2), error('''UntilTime'' needs a time.'); end;
   deadline = double(varargin{2});
   if ~(isscalar(deadline) && isfinite(deadline)), error('The deadline must be a finite scalar.'); end;
  else
   if ~(numel(varargin) == 1), error('WaitSecs takes one duration.'); end;
   secs = double(varargin{1});
   if ~(isscalar(secs) && isfinite(secs)), error('The duration must be a finite scalar.'); end;
   deadline = PsychMetalCore('Now') + secs;
  end
  varargout = {PsychMetalCore('Wait', deadline)};

 case {'resolution','resolutions'}
  screenArg = -1;
  if ~isempty(varargin) && ~isempty(varargin{1})
   screenArg = double(varargin{1});
   if ~(isscalar(screenArg) && isfinite(screenArg) && screenArg == fix(screenArg) ...
       && screenArg >= 0), error('Screen number must be a non-negative integer.'); end;
  end
  m = PsychMetalCore('Modes', screenArg);
  if strcmpi(command, 'resolutions')
   if ~(numel(varargin) <= 1), error('Resolutions takes only a screen number.'); end;
   varargout = {modeStruct(m)};
  else
   if ~(numel(varargin) <= 4), error(...
       'Resolution takes screen, width, height and optional refreshHz.'); end;
   if ~(numel(varargin)~=2), error('Supply both width and height.'); end;
   if numel(varargin)==3, if ~(~isempty(varargin{2}) && ~isempty(varargin{3})), error('Supply both width and height.'); end; end
   old = modeStruct(m(1,:));
   if numel(varargin) >= 3 && ~isempty(varargin{2}) && ~isempty(varargin{3})
    if numel(varargin)==4
     hz=varargin{4};
     if ~(isnumeric(hz) && isreal(hz) && isscalar(hz) && isfinite(hz) && hz>0), error('refreshHz must be positive.'); end;
     PsychMetalCore('SetMode', screenArg, double(varargin{2}), double(varargin{3}), double(hz));
    else
     PsychMetalCore('SetMode', screenArg, double(varargin{2}), double(varargin{3}));
    end
   end
   varargout = {old};
  end

 case 'rect'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isWindow(S, varargin{1})), error('Rect requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) == 1), error('Rect takes only the window handle.'); end;
  varargout = {windowRect(S, varargin{1})};

 case 'windowsize'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isWindow(S, varargin{1})), error('WindowSize requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) == 1), error('WindowSize takes only the window handle.'); end;
  r = windowRect(S, varargin{1});
  varargout = {r(3) - r(1), r(4) - r(2)};

 case 'getflipinterval'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'GetFlipInterval requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) == 1), error('GetFlipInterval takes only the window handle.'); end;
  g = PsychMetalCore('GridAnchor');
  if numel(g) >= 3 && g(3) >= 30 && isfinite(g(2)) && g(2) > 0
   varargout = {g(2)};
  else
   varargout = {S.ifi};
  end

 case 'backgroundcolor'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'BackgroundColor requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) == 2), error('BackgroundColor needs a window and a colour.'); end;
  bg = colorToRGBA(varargin{2}, 'Background colour', S.colorRange);
  PsychMetalCore('SetBackgroundColor', bg(1), bg(2), bg(3), bg(4));
  S.bgColor = bg;
  if nargout >= 1, varargout{1} = bg; end

 case 'getmouse'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''GetMouse'') requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) == 1), error('GetMouse takes only the window handle.'); end;
  [mx, my, buttons] = PsychMetalCore('Mouse');
  varargout = {mx, my, buttons};

 case 'setmouse'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''SetMouse'') requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) == 3), error('SetMouse takes the window handle, x and y.'); end;
  for k = 2:3
   if ~(isnumeric(varargin{k}) && isreal(varargin{k}) && isscalar(varargin{k}) && isfinite(varargin{k})), error(...
       'SetMouse x and y must be finite real scalars, in window pixels.'); end;
  end
  PsychMetalCore('SetMouse', double(varargin{2}), double(varargin{3}));

 case {'hidecursor','showcursor'}
  if ~(isempty(varargin)), error('%s takes no arguments.', command); end;
  PsychMetalCore('Cursor', double(strcmpi(command, 'showcursor')));

 case 'kbcheck'
  if ~(isempty(varargin)), error(['PsychMetal(''KbCheck'') takes no arguments. ' ...
      'There is no deviceNumber: macOS merges every keyboard into one ' ...
      'state before PsychMetal can see it, so all of them are always read.']); end;
  [keyIsDown, secs, keyCode, securePid] = PsychMetalCore('Keys');
  if securePid ~= 0
   warnSecureInput(securePid);
  end
  varargout = {keyIsDown, secs, keyCode};

 case 'kbqueuecreate'
  if ~(numel(varargin)<=2), error('KbQueueCreate takes [keyMask] [, pollInterval]. No device argument.'); end;
  mask=ones(1,256); interval=.002;
  if numel(varargin)>=1 && ~isempty(varargin{1}), mask=varargin{1}; end
  if numel(varargin)>=2 && ~isempty(varargin{2}), interval=varargin{2}; end
  if ~(~issparse(mask) && (isnumeric(mask)||islogical(mask)) && isreal(mask) && numel(mask)==256 && all(isfinite(mask(:)))), error('keyMask must have 256 finite real entries.'); end;
  if ~(isnumeric(interval) && isreal(interval) && isscalar(interval) && isfinite(interval) && interval>=.001 && interval<=.1), error('pollInterval must be .001 to .1 seconds.'); end;
  PsychMetalCore('KbQueueCreate',double(mask(:)'),double(interval));

 case {'kbqueuestart','kbqueuestop','kbqueueflush','kbqueuerelease'}
  if ~(isempty(varargin)), error('This queue command takes no arguments.'); end;
  names={'kbqueuestart','kbqueuestop','kbqueueflush','kbqueuerelease'};
  core={'KbQueueStart','KbQueueStop','KbQueueFlush','KbQueueRelease'};
  PsychMetalCore(core{find(strcmpi(command,names),1)});

 case 'kbqueuegetevents'
  if ~(isempty(varargin)), error('KbQueueGetEvents takes no arguments.'); end;
  [events,dropped]=PsychMetalCore('KbQueueGetEvents');
  varargout={events,dropped};

 case 'kbqueuecheck'
  if ~(isempty(varargin)), error('KbQueueCheck takes no arguments.'); end;
  [pressed,firstPress,firstRelease,lastPress,lastRelease]=PsychMetalCore('KbQueueCheck');
  varargout={pressed,firstPress,firstRelease,lastPress,lastRelease};

 case 'kbqueuestatus'
  if ~(isempty(varargin)), error('KbQueueStatus takes no arguments.'); end;
  varargout={PsychMetalCore('KbQueueStatus')};

 case 'kbwait'
  if ~(numel(varargin) <= 2), error('KbWait takes untilRelease and pollInterval.'); end;
  untilRelease = false; pollInterval = 0.005;
  if numel(varargin) >= 1 && ~isempty(varargin{1})
   untilRelease = logicalFlag(varargin{1},'untilRelease');
  end
  if numel(varargin) >= 2 && ~isempty(varargin{2})
   pollInterval = double(varargin{2});
   if ~(isreal(pollInterval) && isscalar(pollInterval) && isfinite(pollInterval) && pollInterval > 0), error(...
       'pollInterval must be a nonnegative scalar.'); end;
  end
  while true
   [down, secs] = PsychMetal('KbCheck');
   if down ~= untilRelease, break; end
   pause(pollInterval);
  end
  if nargout >= 1, varargout{1} = secs; end

 case 'kbname'
  if ~(numel(varargin) == 1), error('KbName takes one argument.'); end;
  arg = varargin{1};
  tbl = keyNameTable();
  if ischar(arg)
   hit = find(strcmp(tbl(:,2), arg));
   if isempty(hit)
    hit = find(strcmpi(tbl(:,2), arg));   % case-insensitive second chance
   end
   if ~(~isempty(hit)), error('Unknown key name ''%s''.', arg); end;
   varargout{1} = tbl{hit(1), 1};
  elseif isscalar(arg)
   hit = find([tbl{:,1}] == arg);
   if ~(~isempty(hit)), error('No key has usage code %g.', arg); end;
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
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''GetImage'') requires the window handle returned by OpenWindow.'); end;
  if ~(numel(varargin) <= 2), error('PsychMetal(''GetImage'') supports PsychMetal(''GetImage'', w [, rect]).'); end;
  if ~(S.readback), error('GetImage requires a window opened with readback.'); end;
  if numel(varargin) == 2 && ~isempty(varargin{2})
   imageRect = varargin{2};
   if ~(isnumeric(imageRect) && isreal(imageRect) && numel(imageRect) == 4), error(...
       'GetImage rect must be [left top right bottom] in whole pixels inside the window.'); end;
   varargout = {PsychMetalCore('GetImage', double(imageRect(:)'))};
  else
   varargout = {PsychMetalCore('GetImage')};
  end

 case 'noisevalues'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'NoiseValues requires the window handle from OpenWindow.'); end;
  if ~(numel(varargin) >= 2), error('NoiseValues needs a window and a rect.'); end;
  if ~(numel(varargin) <= 7), error(...
      'NoiseValues takes w, rect, seed, distribution, chroma, mean and spread.'); end;
  [nrect, nseed, nnormal, ncolour, nmean, nspread] = ...
      noiseArgs(varargin(2:end), S, 'NoiseValues');
  nw = round(nrect(3) - nrect(1));
  nh = round(nrect(4) - nrect(2));
  varargout = {PsychMetalCore('NoiseValues', nw, nh, nseed, ...
      double(nnormal), double(ncolour), nmean(1:3), nspread) * S.colorRange};

 case {'fillrect','framerect','filloval','frameoval','drawdots','drawlines', ...
       'drawgabor','drawnoise'}
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin)), error('A PsychMetal drawing command requires the window handle from OpenWindow.'); end;
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
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(~isempty(varargin) && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''Flip'') requires the window handle returned by OpenWindow.'); end;
  if ~(numel(varargin) <= 2), error(...
      'PsychMetal(''Flip'') supports PsychMetal(''Flip'', w [, when]).'); end;
  haveWhen = numel(varargin) == 2 && ~isempty(varargin{2});
  if haveWhen
   if ~(isnumeric(varargin{2}) && isreal(varargin{2}) && isscalar(varargin{2})), error(...
       '''when'' must be a finite real scalar in GetSecs time.'); end;
   when = double(varargin{2});
   if ~(isfinite(when)), error('''when'' must be a finite real scalar in GetSecs time.'); end;
   if ~(when >= 0), error('''when'' must be zero or a positive GetSecs timestamp.'); end;
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
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''FlipInfo'') requires w.'); end;
  % The display reports on a frame after Flip has returned, unless the session
  % waits for confirmation: what became of it is asked for now, not remembered.
  status = PsychMetalCore('FlipStatus');
  varargout = {struct('confirmed',status(1) == 1, 'dropped',status(2) == 1, ...
      'slipped',S.lastSlipRefreshes, 'queueMs',S.lastQueueMs, 'flipMs',S.lastFlipMs, ...
      'flips',S.flipCount, 'droppedFrames',status(3), 'slipFlips',S.slipCount)};

 case 'prepareflip'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''PrepareFlip'') requires w.'); end;
  token = PsychMetalCore('PrepareFlip');
  varargout = {token};

 case 'presentnow'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''PresentNow'') requires w.'); end;
  out = PsychMetalCore('PresentNow');
  varargout = {out(1), out(2)};

 case 'setdisplaysync'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''SetDisplaySync'') requires w and a flag.'); end;
  if ~(isscalar(varargin{2}) && (islogical(varargin{2}) || isnumeric(varargin{2}))), error(...
      'The display-sync flag must be a logical scalar.'); end;
  PsychMetalCore('SetDisplaySync', double(logicalFlag(varargin{2},'displaySync')));

 case 'gridanchor'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''GridAnchor'') requires w.'); end;
  g = PsychMetalCore('GridAnchor');
  varargout = {[g(1), g(2), g(3)]};

 case 'nextphase'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 3 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''NextPhase'') requires w, a time and a phase.'); end;
  if ~(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2})), error(...
      'The time must be a finite GetSecs timestamp.'); end;
  if ~(isnumeric(varargin{3}) && isscalar(varargin{3}) && isfinite(varargin{3})), error(...
      'The phase must be a finite number.'); end;
  varargout = {PsychMetalCore('NextPhase', double(varargin{2}), double(varargin{3}))};

 case 'nextrefresh'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 2 && isnumeric(varargin{1}) && isscalar(varargin{1}) && ...
      varargin{1} == S.buffer), error('PsychMetal(''NextRefresh'') requires w and a time.'); end;
  if ~(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2})), error(...
      'The time must be a finite GetSecs timestamp.'); end;
  varargout = {PsychMetalCore('NextRefresh', double(varargin{2}))};

 case 'waittodraw'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) >= 2 && numel(varargin) <= 3 && ...
      isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''WaitToDraw'') requires w and a target presentation time.'); end;
  if ~(isnumeric(varargin{2}) && isscalar(varargin{2}) && isfinite(varargin{2})), error(...
      'The target presentation time must be a finite GetSecs timestamp.'); end;
  target = double(varargin{2});
  drawBudget = 0.004;
  if numel(varargin) == 3 && ~isempty(varargin{3})
   if ~(isnumeric(varargin{3}) && isscalar(varargin{3}) && isfinite(varargin{3}) && ...
       varargin{3} >= 0), error('The drawing budget must be a nonnegative number of seconds.'); end;
   drawBudget = double(varargin{3});
  end
  out = PsychMetalCore('WaitToDraw', target, drawBudget);
  varargout = {out(1), out(2), out(3)};

 case 'diagnostic'
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && varargin{1} == S.buffer), error(...
      'PsychMetal(''Diagnostic'') requires the window handle returned by OpenWindow.'); end;
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
  if ~(~isempty(S)), error('PsychMetal is not open.'); end;
  if ~(numel(varargin) == 1 && isnumeric(varargin{1}) && isscalar(varargin{1}) && isWindow(S, varargin{1})), error(...
      'PsychMetal(''Close'') requires the window handle returned by OpenWindow.'); end;
  if varargin{1} ~= S.buffer
   % An offscreen window: it is a texture, and closes as one.
   PsychMetal('CloseTexture', S.buffer, varargin{1});
   return;
  end
  PsychMetalCore('Close');
  S = [];

 case 'environment'
  if ~(isempty(varargin)), error('Environment takes no arguments.'); end;
  e=PsychMetalCore('Environment');
  e.interpreterVersion=version;
  if exist('OCTAVE_VERSION','builtin'),e.interpreter='Octave';else,e.interpreter='MATLAB';end
  e.schemaVersion=1;
  if ~isempty(S),e.window=S;end
  varargout={e};

 case 'version'
  if ~(isempty(varargin)), error('PsychMetal(''Version'') takes no arguments.'); end;
  varargout = {'0.8.0'};

 otherwise
  error('PsychMetal:Command', ...
      'Unknown PsychMetal command ''%s''. Call PsychMetal for a command list.', command);
end
end

function [S, rect] = useTarget(S, id, command)
% The window or offscreen window a drawing command names: draws go into it from
% now on, and rect is its own.
if ~(isWindow(S, id)), error(['PsychMetal(''%s'') requires the window handle from OpenWindow, ' ...
    'or one from OpenOffscreenWindow.'], command); end;
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
if ~(~isnan(ascent)), error('The text must not be empty.'); end;
entry = struct('key', key, 'lines', {lines}, 'sizes', sizes, 'ascent', ascent);
if isempty(kept), kept = entry; else, kept = [entry, kept(1:min(end, 15))]; end
end

function printGeneralHelp
names=commandNames();
fprintf('PsychMetal 0.8.0: native Metal on Apple Silicon.\n');
fprintf('Use PsychMetal(''Command?'') for help. See README.md for supported contracts.\n');
for k=1:numel(names), fprintf('  %s\n',names{k}); end
end

function printCommandHelp(name)
name=lower(strtrim(name));
if ~any(strcmpi(name,commandNames())) && ~strcmp(name,'latency')
 error('PsychMetal:Help','Unknown help topic %s.',name);
end
switch name
 case {'makestimulus','drawstimulus'}
  fprintf(['s=PsychMetal(''MakeStimulus'',''noise'' or ''grating''[,options]);\n' ...
   'PsychMetal(''DrawStimulus'',w,s[,rect,maskTexture,overrides]);\n' ...
   'Options: mean (0..1 RGB), contrast, frequency (cycles/pixel), orientation/phase (degrees),\n' ...
   'seed, grain (pixels), colour, normal, opacity, aperture (rect/ellipse/gaussian), sigma.\n' ...
   'Mask is one-channel coverage: 0 transparent, 1 opaque. See GPU-STIMULI.md.\n']);
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
 case 'touchevents'
  fprintf(['[events,dropped]=PsychMetal(''TouchEvents'',w) returns what fingers on the trackpad have done since the\n' ...
   'last call, or since the window opened, one row each: [time finger phase x y]. phase is 0 for a finger\n' ...
   'going down, 1 for each movement sampled, 2 for its lifting, 3 for the system taking it over. finger\n' ...
   'numbers the fingers that are down, from 1. x y are the finger''s place on the trackpad as a place in\n' ...
   'the window, in pixels: the trackpad''s corners are the window''s. The time is the one the event\n' ...
   'carries. The first call starts listening and returns nothing, so call it once before the trial.\n' ...
   'Contacts arrive only while the pointer is over the window and this application is active.\n']);
 case 'linearize'
  fprintf(['PsychMetal(''Linearize'',w,gamma) makes every colour and texture value linear light for a display\n' ...
   'whose light is its input raised to gamma (one value, or [r g b]). Drawing and blending then happen\n' ...
   'in a 16-bit float frame and a last pass writes display values. PsychMetal(''Linearize'',w,table)\n' ...
   'takes an Nx3 table instead: the display value 0..1 for each of N evenly spaced linear values.\n' ...
   'PsychMetal(''Linearize'',w,[]) turns it off. It costs one more full-screen pass per frame.\n' ...
   'The table or gamma must come from a photometer; PsychMetal does not measure the display.\n']);
 case {'createshader','closeshader','drawshader'}
  fprintf('Custom Metal fragment functions: see CUSTOM-SHADERS.md for ABI, limits and lifecycle.\n');
 case 'drawmaskedtexture'
  fprintf(['PsychMetal(''DrawMaskedTexture'',w,texture,mask[,src,dst,angle,filter,alpha,tint,coverage]);\n' ...
   'Analytic/image coverage in destination coordinates, rotating with the image. See MASKED-IMAGES.md.\n']);
 case 'makemask'
  fprintf(['mask=PsychMetal(''MakeMask'',kind[,options]) creates a reusable analytic GPU mask recipe.\n' ...
   'Kinds: ellipse, gaussian, annulus, raised_cosine. See GPU-MASKS.md for geometry/edge units.\n' ...
   'edge 0 is exactly hard: each pixel is wholly in or out, so images meeting there are never mixed.\n' ...
   'Pass a recipe as DrawStimulus mask, or use its final coverage argument with an image mask.\n']);

 case 'playtimeline'
  fprintf(['result=PsychMetal(''PlayTimeline'',w,frames[,tracks,keyframes]) replays queued window draws natively.\n' ...
   'tracks: N x 6 [one-based draw index, parameter, kind, even period, amplitude, offset].\n' ...
   'keyframes: N x 4 [one-based draw index, parameter, zero-based frame, value], linearly interpolated.\n' ...
   'Parameters: 0 contrast, 1 phase degrees, 2/3 x/y translation; kinds: 0 cosine, 1 ramp.\n' ...
   'Escape cancels. result.shown counts the samples the display reported shown, result.late those shown\n' ...
   'late (firstLateSample the first, one-based), and meanSampleMs is how long a sample actually stayed on\n' ...
   'screen. Live updates and cancellation from another thread are Python-only: MATLAB and Octave run\n' ...
   'nothing else while PlayTimeline blocks. See TIMELINE.md.\n']);

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
names={'CreateShader','CloseShader','DrawShader','MakeStimulus','MakeMask','DrawStimulus','DrawMaskedTexture','OpenWindow','MakeTexture','UpdateTexture','DrawTexture','DrawTextures','CloseTexture','PrefetchDrawable', ...
'BlendFunction','Linearize','DrawText','TextBounds','LinkInfo','FillPoly','FramePoly','Clip', ...
'OpenOffscreenWindow','QueueFlip','QueueResults','QueueCancel','MouseEvents','TouchEvents', ...
'ColorRange','GetSecs','WaitSecs','Resolution','Resolutions','Rect','WindowSize','GetFlipInterval', ...
'BackgroundColor','GetMouse','SetMouse','HideCursor','ShowCursor','KbCheck','KbQueueCreate','KbQueueStart', ...
'KbQueueStop','KbQueueFlush','KbQueueRelease','KbQueueGetEvents','KbQueueCheck','KbQueueStatus', ...
'KbWait','KbName','GetImage','NoiseValues','FillRect','FrameRect','FillOval','FrameOval','DrawDots','DrawLines', ...
'DrawGabor','DrawNoise','Flip','FlipInfo','PrepareFlip','PresentNow','SetDisplaySync','GridAnchor','NextPhase', ...
'NextRefresh','WaitToDraw','Diagnostic','Close','Version','Environment','PlayTimeline'};
end

function [kind, param, rect, color, extra, info] = buildShapes(cmd, args, S)
kind = []; param = []; rect = zeros(4,0); color = zeros(4,0); extra = zeros(4,0);
info = [];
switch cmd
 case 'drawnoise'
  if ~(numel(args) >= 2), error('DrawNoise needs a window and a rect.'); end;
  if ~(numel(args) <= 7), error(...
      'DrawNoise takes w, rect, seed, distribution, chroma, mean and spread.'); end;
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
   if ~(isscalar(sigma) && isfinite(sigma) && sigma > 0), error('sigma must be positive.'); end;
  end
  freq = 0;
  if numel(args) >= 5 && ~isempty(args{5})
   freq = double(args{5});
   if ~(isscalar(freq) && isfinite(freq) && freq >= 0), error(...
       'Spatial frequency must be zero or positive, in cycles per pixel.'); end;
  end
  angle = 0;
  if numel(args) >= 6 && ~isempty(args{6})
   angle = double(args{6});
   if ~(isscalar(angle) && isfinite(angle)), error('Orientation must be a scalar in degrees.'); end;
  end
  phase = 0;
  if numel(args) >= 7 && ~isempty(args{7})
   phase = double(args{7});
   if ~(isscalar(phase) && isfinite(phase)), error('Phase must be a scalar in degrees.'); end;
  end
  if ~(numel(args) <= 7), error(...
      'DrawGabor takes w, colour, rect, sigma, frequency, orientation and phase.'); end;
  if isvector(r), r = r(:); end
  if ~(isreal(r) && ~issparse(r) && size(r,1) == 4 && all(isfinite(r(:)))), error(...
      'The rectangle must be [left top right bottom], or 4xN for several.'); end;
  n = size(r,2);
  kind = 6 + zeros(1, n);
  param = sigma + zeros(1, n);
  rect = [min(r(1,:),r(3,:)); min(r(2,:),r(4,:)); ...
          max(r(1,:),r(3,:)); max(r(2,:),r(4,:))];
  color = expandColors(spec, n, S.colorRange);
  extra = [freq; angle * pi / 180; phase * pi / 180; 0] * ones(1, n);

 case {'fillrect','framerect','filloval','frameoval'}
  spec = []; if numel(args) >= 2, spec = args{2}; end
  r = S.physicalRect;
  if numel(args) >= 3 && ~isempty(args{3}), r = double(args{3}); end
  pen = 1;
  if numel(args) >= 4 && ~isempty(args{4})
   pen = double(args{4});
   if ~(isscalar(pen) && isfinite(pen) && pen > 0), error('Pen width must be positive.'); end;
  end
  if ~(numel(args) <= 4), error('%s takes w, colour, rect and pen width.', cmd); end;
  if isvector(r), r = r(:); end
  if ~(isreal(r) && ~issparse(r) && size(r,1) == 4 && all(isfinite(r(:)))), error(...
      'The rectangle must be [left top right bottom], or 4xN for several.'); end;
  n = size(r,2);
  switch cmd
   case 'fillrect',   k = 0;
   case 'framerect',  k = 1;
   case 'filloval',   k = 2;
   otherwise,         k = 3;
  end
  kind = k + zeros(1, n);
  param = pen + zeros(1, n);
  rect = [min(r(1,:),r(3,:)); min(r(2,:),r(4,:)); ...
          max(r(1,:),r(3,:)); max(r(2,:),r(4,:))];
  color = expandColors(spec, n, S.colorRange);
  extra = zeros(4, n);

 case 'drawdots'
  if ~(numel(args)<=6), error('DrawDots takes at most six arguments after command.'); end;
  if ~(numel(args) >= 2), error('DrawDots needs a 2xN position matrix.'); end;
  xy = double(args{2});
  if isvector(xy), xy = xy(:); end
  if ~(isreal(xy) && ~issparse(xy) && all(isfinite(xy(:))) && size(xy,1) == 2), error('Dot positions must be 2xN.'); end;
  n = size(xy,2);
  sz = 10;
  if numel(args) >= 3 && ~isempty(args{3}), sz = double(args{3}(:))'; end
  if ~(isreal(sz) && all(isfinite(sz)) && all(sz>0) && (isscalar(sz) || numel(sz) == n)), error('Dot size must be scalar or 1xN.'); end;
  if isscalar(sz), sz = sz + zeros(1, n); end
  spec = []; if numel(args) >= 4, spec = args{4}; end
  ctr = [0 0];
  if numel(args) >= 5 && ~isempty(args{5}), ctr = double(args{5}(:))'; end
  if ~(isreal(ctr) && all(isfinite(ctr)) && numel(ctr) == 2), error('The centre offset must be [x y].'); end;
  dotType = 1;
  if numel(args) >= 6 && ~isempty(args{6})
   dotType = double(args{6});
   if ~(isscalar(dotType) && any(dotType == [0 1 2 3 4])), error(...
       'dot_type must be 0 (square) or 1 to 4 (round).'); end;
  end
  cx = xy(1,:) + ctr(1); cy = xy(2,:) + ctr(2);
  h = sz / 2;
  kind = (dotType ~= 0) * 4 + zeros(1, n);
  param = zeros(1, n);
  rect = [cx - h; cy - h; cx + h; cy + h];
  color = expandColors(spec, n, S.colorRange);
  extra = zeros(4, n);

 case 'drawlines'
  if ~(numel(args)<=5), error('DrawLines takes at most five arguments after command.'); end;
  if ~(numel(args) >= 2), error('DrawLines needs a 2xN endpoint matrix.'); end;
  xy = double(args{2});
  if ~(isreal(xy) && ~issparse(xy) && all(isfinite(xy(:))) && size(xy,1) == 2 && mod(size(xy,2), 2) == 0), error(...
      'Line endpoints must be 2xN with N even: pairs of points.'); end;
  n = size(xy,2) / 2;
  wdt = 1;
  if numel(args) >= 3 && ~isempty(args{3}), wdt = double(args{3}(:))'; end
  if ~(isreal(wdt) && all(isfinite(wdt)) && all(wdt>0) && (isscalar(wdt) || numel(wdt) == n)), error('Line width must be scalar or 1xN.'); end;
  if isscalar(wdt), wdt = wdt + zeros(1, n); end
  spec = []; if numel(args) >= 4, spec = args{4}; end
  ctr = [0 0];
  if numel(args) >= 5 && ~isempty(args{5}), ctr = double(args{5}(:))'; end
  if ~(isreal(ctr) && numel(ctr)==2 && all(isfinite(ctr))), error('Center must be finite [x y].'); end;
  p0 = xy(:, 1:2:end); p1 = xy(:, 2:2:end);
  kind = 5 + zeros(1, n);
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
if ~(isreal(r) && ~issparse(r) && numel(r) == 4 && all(isfinite(r(:))) && all(r(:)==fix(r(:)))), error(...
    '%s needs a rect [left top right bottom].', what); end;
r = [min(r(1),r(3)); min(r(2),r(4)); max(r(1),r(3)); max(r(2),r(4))];
if ~(r(3) - r(1) >= 1 && r(4) - r(2) >= 1), error(...
    '%s needs a rect at least one pixel across.', what); end;

if numel(a) >= 2 && ~isempty(a{2})
 seed = double(a{2});
else
 seed = randi([0 16777215]);
end
if ~(isscalar(seed) && isfinite(seed) && seed == fix(seed) && ...
    seed >= 0 && seed <= 16777215), error(...
    'Seed must be an integer from 0 to 16777215.'); end;

normalFlag = false;
if numel(a) >= 3 && ~isempty(a{3})
 d = lower(char(a{3}));
 if ~(any(strcmp(d, {'uniform','normal'}))), error(...
     'Distribution must be ''uniform'' or ''normal''.'); end;
 normalFlag = strcmp(d, 'normal');
end

colourFlag = false;
if numel(a) >= 4 && ~isempty(a{4})
 c = lower(char(a{4}));
 if ~(any(strcmp(c, {'mono','colour','color'}))), error(...
     'Chroma must be ''mono'' or ''colour''.'); end;
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
 if ~(isscalar(spread) && isfinite(spread) && spread >= 0), error(...
     'Spread must be zero or positive.'); end;
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
if ~(numel(c) == 4), error('%s must be scalar grey, RGB or RGBA.', what); end;
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
if ~(isnumeric(spec) && isreal(spec) && ~issparse(spec) && ndims(spec) == 2), error(message); end;
r = double(spec);
if isvector(r) && numel(r) == 4, r = r(:); end
if ~(size(r,1) == 4 && all(isfinite(r(:)))), error(message); end;
end

function v = perDraw(spec, message)
% DrawTextures per-draw values: empty, one, or a vector with one per draw.
if isempty(spec), v = zeros(1, 0); return; end
if ~((isnumeric(spec) || islogical(spec)) && isreal(spec) && ~issparse(spec) && ...
    isvector(spec) && all(isfinite(double(spec(:))))), error(message); end;
v = double(spec(:))';
end

function c = expandColors(spec, n, cRange)
if nargin < 3 || isempty(cRange), cRange = 255; end
if isempty(spec)
 c = ones(4, n);
 return;
end
if ~((isnumeric(spec)||islogical(spec)) && isreal(spec) && ~issparse(spec)), error('Colors must be dense real numeric values.'); end;
spec = double(spec) / cRange;
if isvector(spec), spec = spec(:); end
switch size(spec,1)
 case 1, spec = [spec; spec; spec; ones(1, size(spec,2))];
 case 3, spec = [spec; ones(1, size(spec,2))];
 case 4, % already RGBA
 otherwise
  error('PsychMetal:Color', ...
      'Colour must be scalar grey, RGB or RGBA, optionally one per shape.');
end
if size(spec,2) == 1
 spec = spec(:, ones(1, n));
end
if ~(size(spec,2) == n), error(...
    'Supply one colour, or one colour per shape (%d).', n); end;
if ~(all(isfinite(spec(:)))), error('Colour components must be finite.'); end;
if any(spec(:) > 1.001)
 warning('PsychMetal:ColorRange', ...
     ['A colour component of %g exceeds this window''s ColorRange of %g and ' ...
      'will be clamped. Set the range with PsychMetal(''ColorRange'', w, r).'], ...
     max(spec(:)) * cRange, cRange);
end
c = min(max(spec, 0), 1);
end

function value=logicalFlag(input,name)
if ~((islogical(input)||isnumeric(input)) && isreal(input) && ~issparse(input) && ...
    isscalar(input) && isfinite(input) && (input==0 || input==1)), error('%s must be true or false.', name); end;
value=logical(input);
end


function p=stimulusParameters(p,options)
if ~(isnumeric(p) && isreal(p) && ~issparse(p) && numel(p)==15), error('Invalid stimulus description.'); end;
p=double(p(:)');
if ~(isstruct(options) && isscalar(options)), error('Stimulus options must be a scalar struct.'); end;
names={'mean','contrast','frequency','orientation','phase','seed','grain','colour','normal','opacity','aperture','sigma'};
indices={2:4,5,6,7,8,9,10,11,12,13,14,15};
fields=fieldnames(options);
for k=1:numel(fields)
 hit=find(strcmp(names,fields{k}),1); if ~(~isempty(hit)), error('Unknown stimulus option: %s', fields{k}); end;
 value=options.(fields{k});
 if hit==11
  if ~(ischar(value) && any(strcmp(value,{'rect','ellipse','gaussian'}))), error('Invalid aperture.'); end;
  value=find(strcmp(value,{'rect','ellipse','gaussian'}))-1;
 end
 if ~((isnumeric(value)||islogical(value)) && isreal(value) && ~issparse(value) && ...
     (isscalar(value)||(hit==1 && numel(value)==3))), error('Invalid stimulus option: %s', fields{k}); end;
 p(indices{hit})=double(value(:)');
end
PsychMetalCore('CheckStimulus',p);
end


function p=makeMaskParameters(kind,options)
kinds={'ellipse','gaussian','annulus','raised_cosine'};
if ~(ischar(kind) && any(strcmp(kind,kinds))), error('Unknown mask kind.'); end;
k=find(strcmp(kind,kinds))-1;
if ~(isstruct(options) && isscalar(options)), error('Mask options must be a scalar struct.'); end;
p=[k .35 0 1 0 0 0 0];
if k==2,p(3)=.5;p(5)=.05;elseif k==3,p(5)=.1;end
allowed={{'radius','edge','center','invert'},{'sigma','center','invert'}, ...
 {'inner','radius','edge','center','invert'},{'radius','edge','center','invert'}};
names={'sigma','inner','radius','edge','center','invert'};indices={2,3,4,5,6:7,8};
fields=fieldnames(options);
for i=1:numel(fields)
 name=fields{i};if ~(any(strcmp(name,allowed{k+1}))), error('Invalid option for mask: %s', name); end;
 value=options.(name);hit=find(strcmp(name,names),1);
 if ~((isnumeric(value)||islogical(value)) && isreal(value) && ~issparse(value) && ...
  numel(value)==numel(indices{hit})), error('Invalid mask option: %s', name); end;
 p(indices{hit})=double(value(:)');
end
PsychMetalCore('CheckMask',p);
end
function p=maskParameters(recipe)
if ~(isstruct(recipe) && isscalar(recipe) && isfield(recipe,'psychmetalMask') && ...
 isequal(recipe.psychmetalMask,1) && isfield(recipe,'parameters')), error('Use MakeMask to create a mask recipe.'); end;
p=recipe.parameters;
if ~(isnumeric(p) && isreal(p) && ~issparse(p) && numel(p)==8), error('Invalid mask description.'); end;
p=double(p(:)');PsychMetalCore('CheckMask',p);
end
