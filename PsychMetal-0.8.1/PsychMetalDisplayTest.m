function report = PsychMetalDisplayTest
% PsychMetalDisplayTest  Check what the display does to a frame after the GPU has handed it over.
%
%   report = PsychMetalDisplayTest
%
% GetImage and PsychMetalReadbackTest establish the frame the GPU rendered.
% They cannot see the cable or the panel, and both can change a picture. This
% test shows three patterns that expose the common ways, asks what you see,
% and reports.
%
%   1. The link. The DisplayPort link is read from the system, with the bit
%      rate this window needs. A link that cannot carry the picture is
%      compressed (Display Stream Compression), and compression is not always
%      invisible.
%   2. Compression. Static single-pixel noise, with a small patch whose noise
%      is new on every frame. On an uncompressed link the static noise is
%      static. On a compressed link, noise that changes takes bits from the
%      noise coded with it, and static noise near the patch twinkles. Shown
%      and asked twice, in colour and then in grey, because a link can alter
%      one and not the other.
%   3. Pixel response. A static noise field beside one that is new on every
%      frame, with the same distribution of values. Their mean luminance
%      should be equal. A panel whose pixels do not settle within a frame
%      shows the changing field darker.
%   4. Gamma. Single-pixel rows of black and white, which emit half of
%      white's light whatever the display's gamma, around a uniform grey you
%      adjust until the two match. The matching grey gives the gamma to pass
%      to PsychMetal('Linearize'). This is an estimate by eye, and no
%      substitute for a photometer.
%
% Keys: Y or N to answer, the arrow keys to adjust, Space to accept, Escape to
% stop. A mouse click skips a pattern without an answer.
%
% report has link (as PsychMetal('LinkInfo')), colourTwinkleSeen,
% greyTwinkleSeen and dimmingSeen (true, false, or [] when not answered),
% matchingGrey and gamma ([] when not estimated).
%
% SPDX-License-Identifier: MIT

report = struct('link', [], 'colourTwinkleSeen', [], 'greyTwinkleSeen', [], 'dimmingSeen', [], ...
    'matchingGrey', [], 'gamma', []);
w = [];
try
 [w, rect] = PsychMetal('OpenWindow', [], 0);
 PsychMetal('HideCursor');
 report.link = PsychMetal('LinkInfo', w);
 [answer, ~, stopped] = runPattern(w, rect, 'colour');
 if ~isempty(answer), report.colourTwinkleSeen = strcmp(answer, 'y'); end
 if ~stopped
  [answer, ~, stopped] = runPattern(w, rect, 'grey');
  if ~isempty(answer), report.greyTwinkleSeen = strcmp(answer, 'y'); end
 end
 if ~stopped
  [answer, ~, stopped] = runPattern(w, rect, 'response');
  if ~isempty(answer), report.dimmingSeen = strcmp(answer, 'y'); end
 end
 if ~stopped
  [answer, grey] = runPattern(w, rect, 'gamma');
  if ~isempty(answer)
   report.matchingGrey = grey;
   report.gamma = log(0.5) / log(grey / 255);
  end
 end
 PsychMetal('ShowCursor');
 PsychMetal('Close', w); w = [];
catch e
 try, PsychMetal('ShowCursor'); catch, end
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 rethrow(e);
end

% ---- report ---------------------------------------------------------------
link = report.link;
fprintf('\n===== display =====\n');
if isnan(link.lanes)
 fprintf('Link: not identified (a built-in panel, HDMI, or a system this cannot read).\n');
else
 fprintf('Link: %g lanes at %g Gbit/s carry %.1f Gbit/s. This window needs %.1f.\n', ...
     link.lanes, link.laneGbps, link.payloadGbps, link.pixelGbps);
 if link.compressed == 1
  fprintf('The picture cannot fit: the link is compressed.\n');
 elseif link.compressed == 0
  fprintf('The picture fits with room for blanking: the link has no need to compress.\n');
 else
  fprintf('The picture fits only without much blanking: compression cannot be ruled out.\n');
 end
end
fprintf('Static colour noise twinkled beside changing noise: %s.\n', said(report.colourTwinkleSeen));
fprintf('Static grey noise twinkled beside changing noise: %s.\n', said(report.greyTwinkleSeen));
if isequal(report.greyTwinkleSeen, true)
 fprintf('  The display link alters fine detail, grey as well as coloured. Single-pixel noise is not delivered\n');
 fprintf('  as rendered: use larger elements or a lower resolution.\n');
elseif isequal(report.colourTwinkleSeen, true)
 fprintf('  The display link alters fine coloured detail. Single-pixel coloured noise is not delivered as\n');
 fprintf('  rendered: use grey noise, larger elements or a lower resolution.\n');
end
fprintf('Changing noise was darker than static noise: %s.\n', said(report.dimmingSeen));
if isequal(report.dimmingSeen, true)
 fprintf('  The panel does not settle within a frame. A region that changes every frame is darker than its\n');
 fprintf('  values say; compare it only with regions that change as often.\n');
end
if isempty(report.gamma)
 fprintf('Gamma: not estimated.\n');
else
 fprintf('Gamma, by eye: %.2f (grey %d matched half of white). PsychMetal(''Linearize'', w, %.2f)\n', ...
     report.gamma, report.matchingGrey, report.gamma);
 fprintf('  uses it. This is one match of one pattern, and assumes a power law: PsychMetalGammaCalibration\n');
 fprintf('  measures the curve. Measure with a photometer before relying on either.\n');
end
end

% -------------------------------------------------------------------------
function text = said(answer)
if isempty(answer), text = 'not answered';
elseif answer, text = 'yes';
else, text = 'no'; end
end

function [answer, grey, stopped] = runPattern(w, rect, kind)
% Draw one pattern until it is answered ('y', 'n' or 'space'), skipped by a
% mouse click (answer '') or stopped with Escape.
names = {'y', 'n', 'p', 'space', 'UpArrow', 'DownArrow', 'ESCAPE'};
codes = zeros(1, numel(names));
for k = 1:numel(names), codes(k) = PsychMetal('KbName', names{k}); end
settle = 30;         % frames before a pattern takes an answer, so one press cannot answer two
W = rect(3); H = rect(4);
textSize = max(12, floor(H / 50));
patchOn = true; grey = 186;
answer = ''; stopped = false; stripes = [];
top = floor(H * 0.26);
switch kind
 case {'colour', 'grey'}
  if strcmp(kind, 'colour'), chroma = 'colour'; else, chroma = 'mono'; end
  side = 2 * floor(min(W, H) * 0.35);
  left = floor((W - side) / 2);
  field = [left, top, left + side, top + side];
  q = floor(side / 4); inset = floor(q / 2);
  patch = [field(3) - q - inset, top + inset, field(3) - inset, top + inset + q];
  answers = {'y', 'n'};
 case 'response'
  side = 2 * floor(min(W, H) * 0.3);
  gap = floor(side / 8);
  a = [floor(W / 2) - floor(gap / 2) - side, top, floor(W / 2) - floor(gap / 2), top + side];
  b = [a(3) + gap, top, a(3) + gap + side, top + side];
  answers = {'y', 'n'};
 case 'gamma'
  side = 2 * floor(min(W, H) * 0.3);
  left = floor((W - side) / 2);
  rows = zeros(side, 2, 'uint8'); rows(1:2:end, :) = 255;
  stripes = PsychMetal('MakeTexture', w, rows);
  quarter = floor(side / 4);
  inner = [left + quarter, top + quarter, left + floor(3 * side / 4), top + floor(3 * side / 4)];
  answers = {'space'};
end
isAnswer = ismember(names, answers);
held = false(1, numel(names));
frame = 0;
while true
 switch kind
  case {'colour', 'grey'}
   PsychMetal('DrawNoise', w, field, 1, 'uniform', chroma);
   if patchOn, PsychMetal('DrawNoise', w, patch, 2 + mod(frame, 16000000), 'uniform', chroma); end
   if patchOn, patchName = 'changing'; else, patchName = 'off'; end
   lines = {sprintf(['Compression, %s noise. The noise is static, except in a square at its upper right, ' ...
       'which is new every frame.'], kind), ...
       'Look at the static noise below and beside that square, or cover the square with your hand.', ...
       sprintf('P turns the changing square off and on, for comparison. Now: %s.', patchName), ...
       sprintf('Does the static %s noise twinkle while the square is changing?   Y yes   N no', kind)};
  case 'response'
   PsychMetal('DrawNoise', w, a, 1, 'uniform', 'mono');
   PsychMetal('DrawNoise', w, b, 2 + mod(frame, 16000000), 'uniform', 'mono');
   lines = {'Pixel response. The left field is static. The right field is new every frame.', ...
       'Both have the same values in the same proportions, so they should be equally bright.', ...
       'Step back, or defocus, until the noise blurs to grey.', ...
       'Is the right field darker than the left?   Y yes   N no'};
  case 'gamma'
   PsychMetal('DrawTexture', w, stripes, [], [left, top, left + side, top + side], 0, 0);
   PsychMetal('FillRect', w, grey, inner);
   lines = {'Gamma. The stripes are single rows of black and white: half the light of white.', ...
       'Step back until the stripes blur, then make the square in the middle match them.', ...
       'Each tap of Up or Down changes the grey by one level; holding does no more. Space accepts.', ...
       sprintf('Grey %d of 255: gamma %.2f.', grey, log(0.5) / log(grey / 255))};
 end
 for k = 1:numel(lines)
  PsychMetal('DrawText', w, lines{k}, floor(W * 0.04), floor(H * 0.02 + (k - 1) * textSize * 1.35), 220, textSize);
 end
 PsychMetal('Flip', w);
 frame = frame + 1;
 [~, ~, keyCode] = PsychMetal('KbCheck');
 down = logical(keyCode(codes));
 fresh = down & ~held;
 held = down;
 if down(7), stopped = true; break; end
 if strcmp(kind, 'gamma')
  if fresh(5), grey = min(254, grey + 1); end       % one step per press: a held key does not repeat
  if fresh(6), grey = max(1, grey - 1); end
 end
 if frame <= settle, continue; end
 if any(strcmp(kind, {'colour', 'grey'})) && fresh(3), patchOn = ~patchOn; end
 hit = find(fresh & isAnswer, 1);
 if ~isempty(hit), answer = names{hit}; break; end
 [~, ~, buttons] = PsychMetal('GetMouse', w);
 if any(buttons), break; end
end
if ~isempty(stripes), PsychMetal('CloseTexture', w, stripes); end
end
