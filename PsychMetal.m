function varargout = PsychMetal(command, varargin)
% PsychMetal  PTB drawing with native Metal presentation on macOS.
%
% PsychMetal
% PsychMetal('OpenWindow?')
% PsychMetal('MakeTexture?')
% PsychMetal('Flip?')
% PsychMetal('Diagnostic?')
% PsychMetal('Close?')
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
  assert(numel(varargin) <= 1, ...
      'OpenWindow accepts only an optional screen number.');
  screens = Screen('Screens'); screen = max(screens);
  if ~isempty(varargin) && ~isempty(varargin{1})
   screen = double(varargin{1});
   assert(isscalar(screen) && ismember(screen, screens), ...
       'Invalid screen number. Available screens: %s', mat2str(screens));
  end
  logicalRect = Screen('Rect', screen);
  physicalRect = Screen('Rect', screen, 1);
  globalRect = Screen('GlobalRect', screen);
  width = physicalRect(3) - physicalRect(1);
  height = physicalRect(4) - physicalRect(2);
  displayRect = [0 0 width height];
  oldSkipSync = Screen('Preference', 'SkipSyncTests', 2);
  host = Screen('OpenWindow', screen, 0, [40 40 168 136], [], [], [], [], [], 32);
  buffer = [];
  fprintf('PsychMetal: PTB host window opened.\n');
  ifi = Screen('GetFlipInterval', host);
  try
   % The program sees one stable PTB drawing surface. PsychMetalCore owns
   % the two alternating IOSurface/Metal presentation buffers internally.
   buffer = Screen('OpenOffscreenWindow', host, 0, [0 0 width height], 32, 32);
   [gltex, target] = Screen('GetOpenGLTexture', host, buffer);
   % This call has the documented side effect of selecting buffer as the
   % drawing target. The core captures its FBO and replaces color attachment 0.
   Screen('GetWindowInfo', buffer);
   fprintf('PsychMetal: PTB drawing FBO selected; attaching double-buffered IOSurfaces directly.\n');
   PsychMetalCore('Open', width, height, ifi, target, gltex, screen, ...
       globalRect(1), globalRect(2), globalRect(3), globalRect(4));
   fprintf('PsychMetal: Metal presenter ready; Screen(''Flip'') is not used.\n');
  catch e
   try, PsychMetalCore('Close'); catch, end
   try, Screen('Preference', 'SkipSyncTests', oldSkipSync); catch, end
   try
    if ~isempty(buffer), Screen('Close', buffer); end
    Screen('Close', host);
   catch
   end
   rethrow(e);
  end
  S = struct('host',host,'buffer',buffer,'current',1,'ifi',ifi, ...
      'screenNumber',screen,'globalRect',globalRect,'logicalRect',logicalRect, ...
      'physicalRect',physicalRect,'oldSkipSync',oldSkipSync, ...
      'lastQueueMs',NaN,'lastFlipMs',NaN);
 varargout = {buffer, displayRect, ifi};

 case 'maketexture'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) >= 2 && varargin{1} == S.buffer, ...
      'PsychMetal(''MakeTexture'') requires w and an image matrix.');
  % MakeTexture requires an onscreen parent. Use PsychMetal's hidden PTB
  % host while returning an otherwise ordinary Screen texture handle.
  texture = Screen('MakeTexture', S.host, varargin{2:end});
  varargout = {texture};

 case 'flip'
  % Submit the completed buffer and wait only until the display link assigns
  % its calibrated projected presentation timestamp.
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(~isempty(varargin) && varargin{1} == S.buffer, ...
      'PsychMetal(''Flip'') requires the window handle returned by OpenWindow.');
  assert(numel(varargin) == 1, ...
      'PsychMetal(''Flip'') supports only PsychMetal(''Flip'', w).');
  Screen('DrawingFinished', S.buffer);
  tf = GetSecs;
  token = PsychMetalCore('Queue', S.current - 1);
  S.lastQueueMs = (GetSecs - tf) * 1000;
  S.current = 3 - S.current;
  % Return once CAMetalDisplayLink has accepted this frame. raw(1) is
  % Apple's target presentation timestamp. Confirmed presentedTime arrives
  % later and is retained internally for diagnostics.
  raw = PsychMetalCore('WaitScheduled', token);
  flipReturn = GetSecs;
  S.lastFlipMs = (flipReturn - tf) * 1000;
  % Match Screen('Flip') output order for the supported basic mode:
  % [VBLTimestamp, StimulusOnsetTime, FlipTimestamp, Missed, Beampos].
  % VBL/onset are Apple's projected target. Beam position is unavailable.
  missed = 0;
  if raw(2) ~= 0, missed = NaN; end
  screenCompatible = [raw(1), raw(1), flipReturn, missed, -1];
  varargout = num2cell(screenCompatible);

 case 'diagnostic'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && varargin{1} == S.buffer, ...
      'PsychMetal(''Diagnostic'') requires the window handle returned by OpenWindow.');
  % Diagnostics are outside the presentation loop, so wait for all delayed
  % presented handlers before returning the projected/actual comparison.
  [h, summary] = PsychMetalCore('Diagnostic');
  summary.lastQueueMs = S.lastQueueMs;
  summary.lastFlipMs = S.lastFlipMs;
  summary.ptbScreenNumber = S.screenNumber;
  summary.ptbGlobalRect = S.globalRect;
  summary.ptbLogicalRect = S.logicalRect;
  summary.ptbPhysicalRect = S.physicalRect;
  actual = h(:,3);
  actualStatus = h(:,4); % 0 confirmed, 1 presentedTime missing, 2 pending.
  actual(actualStatus ~= 0) = NaN;
  projected = h(:,2);
  rawTarget = h(:,9);
  observedLag = (actual - rawTarget) / S.ifi;
  finiteLag = observedLag(isfinite(observedLag));
  if isempty(finiteLag), summary.calibratedTargetLagFrames = NaN;
  else, summary.calibratedTargetLagFrames = round(median(finiteLag)); end
  if isempty(projected), frameID = zeros(0,1); else, frameID = round((projected-projected(1))/S.ifi); end
  d = struct('flipNumber',h(:,1), ...
      'frameID',frameID, ...
      'projectedTimestamp',projected, ...
      'rawAppleTargetTimestamp',rawTarget, ...
      'actualTimestamp',actual, ...
      'actualStatus',actualStatus, ...
      'targetErrorMs',(actual-projected)*1000, ...
      'scheduledAt',h(:,5), ...
      'projectionLeadMs',(projected-h(:,5))*1000, ...
      'confirmationCallbackTime',h(:,6), ...
      'confirmationDelayMs',(h(:,6)-actual)*1000, ...
      'displayLinkTick',h(:,7), ...
      'commandStatus',h(:,8), ...
      'summary',summary);
  varargout={d};

 case 'close'
  assert(~isempty(S), 'PsychMetal is not open.');
  assert(numel(varargin) == 1 && varargin{1} == S.buffer, ...
      'PsychMetal(''Close'') requires the window handle returned by OpenWindow.');
  try, PsychMetalCore('Close'); catch, end
  if ~isempty(S)
   % Restore the user's PTB preference before closing the hidden host. The
   % host's synchronization tests are irrelevant because it never presents.
   try, Screen('Preference', 'SkipSyncTests', S.oldSkipSync); catch, end
   try
    openWindows = Screen('Windows');
    if ismember(S.buffer, openWindows), Screen('Close', S.buffer); end
    if ismember(S.host, openWindows), Screen('Close', S.host); end
   catch
   end
  end
  S = [];

 otherwise
  error('PsychMetal:Command', ...
      'Unknown PsychMetal command ''%s''. Call PsychMetal for a command list.', command);
end
end

function printGeneralHelp
fprintf('\nPsychMetal - PTB drawing with native Metal presentation on macOS\n\n');
fprintf('Supported commands:\n\n');
fprintf('  [w, rect, ifi] = PsychMetal(''OpenWindow'' [, screenNumber]);\n');
fprintf('  texture = PsychMetal(''MakeTexture'', w, image [, Screen options...]);\n');
fprintf('  [vbl, onset, flipTime, missed, beampos] = PsychMetal(''Flip'', w);\n');
fprintf('  history = PsychMetal(''Diagnostic'', w);\n');
fprintf('  PsychMetal(''Close'', w);\n\n');
fprintf('For detailed help, call OpenWindow?, MakeTexture?, Flip?, Diagnostic?, or Close?.\n');
fprintf('Example: PsychMetal(''Flip?'')\n\n');
end

function printCommandHelp(name)
switch lower(strtrim(name))
 case 'openwindow'
  fprintf('\nUsage:\n\n');
  fprintf('[w, rect, ifi] = PsychMetal(''OpenWindow'' [, screenNumber]);\n\n');
  fprintf(['Opens one stable PTB offscreen drawing window and a Metal presentation window.\n' ...
      'Draw with ordinary Screen commands using w. screenNumber selects a display from\n' ...
      'Screen(''Screens''); the default is the highest-numbered display. OpenWindow creates\n' ...
      'a display-sized borderless window and enters the built-in\n' ...
      'native macOS fullscreen mode required for possible Game Mode activation. On a notched\n' ...
      'MacBook, visibility beside the notch depends on the Octave application''s display-safe-area\n' ...
      'compatibility setting. rect is the\n' ...
      'full-resolution pixel drawing rectangle\n' ...
      '(physical Retina resolution, not scaled logical points), and ifi is the nominal refresh\n' ...
      'interval in seconds. Only 8-bit monoscopic drawing and\n' ...
      'the basic presentation path are supported.\n\n']);
  fprintf('See also: Flip Diagnostic Close\n\n');

 case 'maketexture'
  fprintf('\nUsage:\n\n');
  fprintf('texture = PsychMetal(''MakeTexture'', w, imageMatrix [, Screen options...]);\n\n');
  fprintf(['Creates a normal PTB texture directly from a MATLAB/Octave image matrix.\n' ...
      'PsychMetal supplies its hidden onscreen host because Screen(''MakeTexture'') rejects\n' ...
      'the offscreen drawing handle w as a parent. Optional arguments after imageMatrix are\n' ...
      'passed unchanged to Screen(''MakeTexture''). Draw the returned texture normally:\n\n' ...
      '  Screen(''DrawTexture'', w, texture, [], destination, angle, filterMode);\n\n' ...
      'Close it with Screen(''Close'', texture) when it is no longer needed.\n\n']);
  fprintf('See also: OpenWindow Flip Close\n\n');

 case 'flip'
  fprintf('\nUsage:\n\n');
  fprintf('[VBLTimestamp StimulusOnsetTime FlipTimestamp Missed Beampos] = ...\n');
  fprintf('    PsychMetal(''Flip'', w);\n\n');
  fprintf(['Finishes drawing into the current IOSurface, queues it through CAMetalDisplayLink,\n' ...
      'and attaches the other IOSurface to the same PTB drawing FBO. No full-frame blit is used.\n' ...
      'Flip returns when the display link accepts the frame; it\n' ...
      'does not wait for the later presented-handler confirmation. VBLTimestamp and\n' ...
      'StimulusOnsetTime are Apple''s projected target presentation time and may be roughly two\n' ...
      'refresh intervals in the future. FlipTimestamp is when Flip returned. Missed is zero for\n' ...
      'successful scheduling and NaN on scheduling failure. Beampos is always -1 because scanline\n' ...
      'queries are unavailable. Scheduled ''when'', waitframes, dontclear,\n' ...
      'dontsync, multiflip, stereo, HDR, and DataPixx modes are not implemented. Use Diagnostic\n' ...
      'afterward to compare every projected timestamp with later confirmed presentedTime feedback.\n\n']);
  fprintf('See also: OpenWindow Diagnostic Close\n\n');

 case 'diagnostic'
  fprintf('\nUsage:\n\n');
  fprintf('history = PsychMetal(''Diagnostic'', w);\n\n');
  fprintf(['Waits outside the animation loop for outstanding Metal presented handlers, then returns\n' ...
      'one row per Flip. Main fields are:\n\n' ...
      '  projectedTimestamp       Target time returned by Flip.\n' ...
      '  rawAppleTargetTimestamp  Uncorrected CAMetalDisplayLink target.\n' ...
      '  actualTimestamp          Later confirmed presentedTime, or NaN.\n' ...
      '  actualStatus             0=confirmed, 1=Apple returned zero, 2=pending, 3=GPU error.\n' ...
      '  targetErrorMs            actual minus projected time in milliseconds.\n' ...
      '  projectionLeadMs         projected time minus scheduling time.\n' ...
      '  scheduledAt              Time the display-link callback accepted the frame.\n' ...
      '  confirmationCallbackTime Time the presented handler ran.\n' ...
      '  confirmationDelayMs      callback time minus actual presentedTime.\n' ...
      '  displayLinkTick, frameID, flipNumber, commandStatus, summary.\n' ...
      '  summary.calibratedTargetLagFrames reports the learned whole-refresh correction.\n\n' ...
      'Diagnostic may pause for about the outstanding compositor pipeline depth. It should be\n' ...
      'called after timing-critical presentation, before Close.\n\n']);
  fprintf('See also: OpenWindow Flip Close\n\n');

 case 'close'
  fprintf('\nUsage:\n\n');
  fprintf('PsychMetal(''Close'', w);\n\n');
  fprintf(['Stops CAMetalDisplayLink, hides the Metal window, and closes the PTB drawing and host\n' ...
      'windows. Call Diagnostic first if projected-versus-confirmed history is required.\n\n']);
  fprintf('See also: OpenWindow Flip Diagnostic\n\n');

 otherwise
  fprintf('\nNo PsychMetal help topic named ''%s'' exists.\n', name);
  fprintf('Available topics: OpenWindow, MakeTexture, Flip, Diagnostic, Close.\n\n');
end
end
