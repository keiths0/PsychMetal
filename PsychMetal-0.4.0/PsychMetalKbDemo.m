function PsychMetalKbDemo(seconds)
% PsychMetalKbDemo  An on-screen keyboard that lights up as you type.
%
% Usage: PsychMetalKbDemo([seconds = 120]);
%
% Draws a schematic keyboard with PsychMetal('FillRect') and lights each key
% while it is held, polling PsychMetal('KbCheck') once per refresh. Press
% ESCAPE, or any mouse button, to leave.
%
% This is a demo, and it is also the instrument that verifies the keyboard
% path, which is why it draws a LAYOUT rather than a list of names. The chain
% from a physical key to a name has two hand-written tables in it — virtual
% keycode to HID usage in PsychMetalCore.mm, and usage to name in PsychMetal.m
% — and an error in either produces a plausible-looking wrong answer. Here both
% are visible at once: press a key and the rectangle in that physical position
% should light, and the readout underneath should name that key. If the wrong
% rectangle lights, the first table is wrong. If the right one lights and the
% readout names something else, the second is.
%
% Worth pressing deliberately:
%
%   left and right shift    They must light SEPARATELY. Paired modifiers are
%                           collapsed onto the left-hand keycode by the OS, so
%                           an implementation that reads only keycodes reports
%                           both as LeftShift. Same for control, option and
%                           command. Left and right shift are a common pair of
%                           2AFC response keys, so this matters.
%   an external keyboard    USB or Bluetooth. macOS merges every keyboard into
%                           one state before PsychMetal sees it, and this is
%                           where that claim is either true or not.
%   several keys at once    A keyboard's own hardware limits how many
%                           simultaneous keys it can report. That ceiling is
%                           the keyboard's, not PsychMetal's, and this shows
%                           you what yours is.
%
% Keys with no rectangle — the numeric keypad, media keys — are still read.
% They appear in the readout, so nothing is silently invisible.
%
% Text is drawn from a 5x7 bitmap font defined at the bottom of this file, one
% glyph per line in '.' and '#', because PsychMetal has no text drawing. Every
% glyph is therefore checkable by eye in the source.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds), seconds = 120; end

w = [];
try
 [w, rect] = PsychMetal('OpenWindow', [], 18);
 PsychMetal('HideCursor');

 K = keyboardLayout();
 usages = [K.usage];

 % Fit the layout to the window, preserving the aspect of a key.
 spanX = max([K.x] + [K.w]);
 spanY = max([K.y] + [K.h]);
 width  = rect(3) - rect(1);
 height = rect(4) - rect(2);
 % Two thirds of the height for the keyboard, the rest for the readout.
 unit = min(width * 0.92 / spanX, height * 0.62 / spanY);
 originX = rect(1) + (width - unit * spanX) / 2;
 originY = rect(2) + height * 0.14;
 gap = unit * 0.06;   % the gutter between keycaps

 % Key rectangles, computed once. Only the colours change per frame.
 bodies = zeros(4, numel(K));
 for k = 1:numel(K)
  bodies(:,k) = [originX + K(k).x * unit + gap
                 originY + K(k).y * unit + gap
                 originX + (K(k).x + K(k).w) * unit - gap
                 originY + (K(k).y + K(k).h) * unit - gap];
 end

 % Labels, also computed once: a key's glyphs do not move, they only change
 % colour. Sized per key, so a letter is large and RSHIFT still fits.
 labelRects = cell(1, numel(K));
 for k = 1:numel(K)
  labelRects{k} = layoutLabel(K(k).label, bodies(:,k));
 end

 upColour    = [46; 48; 56];
 downColour  = [245; 205; 90];
 edgeColour  = [88; 90; 104];
 textUp      = [205; 208; 220];
 textDown    = [24; 22; 18];
 readoutCol  = [235; 238; 248];

 readoutY = originY + spanY * unit + unit * 0.55;
 readoutPx = max(2, round(unit / 9));

 PsychMetal('Flip', w);
 deadline = PsychMetal('GetSecs') + seconds;

 while PsychMetal('GetSecs') < deadline
  [~, ~, keyCode] = PsychMetal('KbCheck');
  if keyCode(41), break; end            % ESCAPE
  [~, ~, buttons] = PsychMetal('GetMouse', w);
  if any(buttons), break; end

  down = keyCode(usages);

  % Three batched calls for the whole keyboard. Every rectangle goes to the
  % GPU as one instanced draw, so the key count costs nothing worth counting.
  colours = repmat(upColour, 1, numel(K));
  colours(:, down) = repmat(downColour, 1, sum(down));
  PsychMetal('FillRect', w, colours, bodies);
  PsychMetal('FrameRect', w, edgeColour, bodies, max(1, round(unit / 40)));

  glyphs = [labelRects{:}];
  glyphColours = zeros(3, size(glyphs, 2));
  at = 0;
  for k = 1:numel(K)
   n = size(labelRects{k}, 2);
   if n == 0, continue; end
   if down(k)
    glyphColours(:, at+1:at+n) = repmat(textDown, 1, n);
   else
    glyphColours(:, at+1:at+n) = repmat(textUp, 1, n);
   end
   at = at + n;
  end
  if ~isempty(glyphs)
   PsychMetal('FillRect', w, glyphColours, glyphs);
  end

  % The readout names what is down, using the same KbName table a script
  % would. A key with no rectangle still appears here.
  readout = readoutText(keyCode);
  readoutRects = glyphRects(readout, ...
      rect(1) + (width - textWidth(readout, readoutPx)) / 2, ...
      readoutY, readoutPx);
  if ~isempty(readoutRects)
   PsychMetal('FillRect', w, readoutCol, readoutRects);
  end

  % Unscheduled: this demo has nothing to say about presentation timing and
  % should not pretend otherwise by asking for a deadline it does not need.
  PsychMetal('Flip', w);
 end

 PsychMetal('ShowCursor');
 PsychMetal('Close', w); w = [];

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

% -------------------------------------------------------------------------
function s = readoutText(keyCode)
% What to show under the keyboard. Names come from PsychMetal('KbName'), so
% this exercises the same lookup an experiment would.
names = PsychMetal('KbName', keyCode);
if isempty(names)
 s = 'PRESS ESCAPE TO EXIT';
 return;
end
if numel(names) > 6, names = [names(1:6), {'...'}]; end
s = upper(strjoin(names, ' '));
end

% -------------------------------------------------------------------------
function K = keyboardLayout()
% Where each key sits, in key units, with y growing downward. Positions are
% the ANSI layout because that is what makes the demo a test: the rectangle
% that lights should be under the finger that pressed it.
K = struct('usage', {}, 'x', {}, 'y', {}, 'w', {}, 'h', {}, 'label', {});
fn = arrayfun(@(k) sprintf('F%d', k), 1:12, 'UniformOutput', false);

K = addRow(K, 0, 0,     [41 58:69], 1.15, [{'ESC'}, fn]);

K = addRow(K, 1, 0,     [53 30:39 45 46], 1, ...
    {'`','1','2','3','4','5','6','7','8','9','0','-','='});
K = addRow(K, 1, 13,    42, 2, {'DEL'});

K = addRow(K, 2, 0,     43, 1.5, {'TAB'});
K = addRow(K, 2, 1.5,   [20 26 8 21 23 28 24 12 18 19], 1, ...
    {'Q','W','E','R','T','Y','U','I','O','P'});
K = addRow(K, 2, 11.5,  [47 48], 1, {'[',']'});
K = addRow(K, 2, 13.5,  49, 1.5, {'\'});

K = addRow(K, 3, 0,     57, 1.75, {'CAPS'});
K = addRow(K, 3, 1.75,  [4 22 7 9 10 11 13 14 15], 1, ...
    {'A','S','D','F','G','H','J','K','L'});
K = addRow(K, 3, 10.75, [51 52], 1, {';',''''});
K = addRow(K, 3, 12.75, 40, 2.25, {'RETURN'});

% The two shifts are separate entries on purpose. If they ever light together
% from one press, the sidedness correction in PsychMetalCore.mm has regressed.
K = addRow(K, 4, 0,     225, 2.25, {'LSHIFT'});
K = addRow(K, 4, 2.25,  [29 27 6 25 5 17 16], 1, ...
    {'Z','X','C','V','B','N','M'});
K = addRow(K, 4, 9.25,  [54 55 56], 1, {',','.','/'});
K = addRow(K, 4, 12.25, 229, 2.75, {'RSHIFT'});

K = addRow(K, 5, 0,     224, 1.25, {'LCTRL'});
K = addRow(K, 5, 1.25,  226, 1.25, {'LOPT'});
K = addRow(K, 5, 2.5,   227, 1.5,  {'LCMD'});
K = addRow(K, 5, 4,     44, 6.25,  {'SPACE'});
K = addRow(K, 5, 10.25, 231, 1.5,  {'RCMD'});
K = addRow(K, 5, 11.75, 230, 1.25, {'ROPT'});
K = addRow(K, 5, 13,    228, 1.25, {'RCTRL'});

% The arrow cluster, with the half-height up and down keys of a real board.
% Spelled out rather than drawn as arrow glyphs, because a down-arrow glyph
% would have to be keyed on some character, and the obvious one collides with
% the letter V.
K = addKey(K, 80, 15.25, 5,   1, 1,   'LEFT');
K = addKey(K, 82, 16.25, 5,   1, 0.5, 'UP');
K = addKey(K, 81, 16.25, 5.5, 1, 0.5, 'DOWN');
K = addKey(K, 79, 17.25, 5,   1, 1,   'RIGHT');
end

function K = addRow(K, y, x0, usages, w, labels)
% One run of equal-width keys, left to right from x0.
for k = 1:numel(usages)
 K = addKey(K, usages(k), x0 + (k-1)*w, y, w, 1, labels{k});
end
end

function K = addKey(K, usage, x, y, w, h, label)
K(end+1) = struct('usage', usage, 'x', x, 'y', y, 'w', w, 'h', h, ...
    'label', label);
end

% -------------------------------------------------------------------------
function r = layoutLabel(label, body)
% Centre a label in a keycap, at the largest size that fits it. Sizing per key
% rather than globally is what lets a letter be large while RSHIFT still fits
% inside its cap.
bw = body(3) - body(1);
bh = body(4) - body(2);
px = floor(min(bw * 0.72 / max(1, textWidth(label, 1)), bh * 0.42 / 7));
if px < 1
 r = zeros(4, 0);
 return;
end
x = body(1) + (bw - textWidth(label, px)) / 2;
y = body(2) + (bh - 7 * px) / 2;
r = glyphRects(label, x, y, px);
end

function n = textWidth(s, px)
n = (6 * numel(s) - 1) * px;   % 5 wide plus one column of space, less the last
end

function r = glyphRects(s, x, y, px)
% One rectangle per lit font pixel. A whole screen of text is a few thousand
% rectangles and they all batch into one draw, so this is cheaper than it
% looks and needs no texture.
[chars, glyphs] = font();
r = zeros(4, 35 * numel(s));   % 35 pixels is the most a 5x7 glyph can light
n = 0;
for k = 1:numel(s)
 hit = find(chars == upper(s(k)), 1);
 if isempty(hit), continue; end
 [rowIdx, colIdx] = find(glyphs{hit} == '#');
 left = x + (k-1)*6*px + (colIdx-1)*px;
 top  = y + (rowIdx-1)*px;
 m = numel(rowIdx);
 r(:, n+1:n+m) = [left(:)'; top(:)'; left(:)' + px; top(:)' + px];
 n = n + m;
end
r = r(:, 1:n);
end

% -------------------------------------------------------------------------
function [chars, glyphs] = font()
% A 5x7 bitmap font, one glyph per line, so every letter can be checked by
% eye rather than decoded. Rows are separated by |. Only the characters the
% key labels and the readout need; anything else draws as a blank.
persistent c g
if ~isempty(c), chars = c; glyphs = g; return; end
spec = {
 'A', '.###.|#...#|#...#|#####|#...#|#...#|#...#'
 'B', '####.|#...#|#...#|####.|#...#|#...#|####.'
 'C', '.###.|#...#|#....|#....|#....|#...#|.###.'
 'D', '####.|#...#|#...#|#...#|#...#|#...#|####.'
 'E', '#####|#....|#....|####.|#....|#....|#####'
 'F', '#####|#....|#....|####.|#....|#....|#....'
 'G', '.###.|#...#|#....|#.###|#...#|#...#|.###.'
 'H', '#...#|#...#|#...#|#####|#...#|#...#|#...#'
 'I', '#####|..#..|..#..|..#..|..#..|..#..|#####'
 'J', '....#|....#|....#|....#|#...#|#...#|.###.'
 'K', '#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#'
 'L', '#....|#....|#....|#....|#....|#....|#####'
 'M', '#...#|##.##|#.#.#|#...#|#...#|#...#|#...#'
 'N', '#...#|##..#|#.#.#|#..##|#...#|#...#|#...#'
 'O', '.###.|#...#|#...#|#...#|#...#|#...#|.###.'
 'P', '####.|#...#|#...#|####.|#....|#....|#....'
 'Q', '.###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#'
 'R', '####.|#...#|#...#|####.|#.#..|#..#.|#...#'
 'S', '.###.|#...#|#....|.###.|....#|#...#|.###.'
 'T', '#####|..#..|..#..|..#..|..#..|..#..|..#..'
 'U', '#...#|#...#|#...#|#...#|#...#|#...#|.###.'
 'V', '#...#|#...#|#...#|#...#|#...#|.#.#.|..#..'
 'W', '#...#|#...#|#...#|#...#|#.#.#|##.##|#...#'
 'X', '#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#'
 'Y', '#...#|#...#|.#.#.|..#..|..#..|..#..|..#..'
 'Z', '#####|....#|...#.|..#..|.#...|#....|#####'
 '0', '.###.|#...#|#..##|#.#.#|##..#|#...#|.###.'
 '1', '..#..|.##..|..#..|..#..|..#..|..#..|.###.'
 '2', '.###.|#...#|....#|...#.|..#..|.#...|#####'
 '3', '#####|...#.|..##.|....#|....#|#...#|.###.'
 '4', '...#.|..##.|.#.#.|#..#.|#####|...#.|...#.'
 '5', '#####|#....|####.|....#|....#|#...#|.###.'
 '6', '..##.|.#...|#....|####.|#...#|#...#|.###.'
 '7', '#####|....#|...#.|..#..|.#...|.#...|.#...'
 '8', '.###.|#...#|#...#|.###.|#...#|#...#|.###.'
 '9', '.###.|#...#|#...#|.####|....#|...#.|.##..'
 '-', '.....|.....|.....|#####|.....|.....|.....'
 '=', '.....|.....|#####|.....|#####|.....|.....'
 '[', '..##.|..#..|..#..|..#..|..#..|..#..|..##.'
 ']', '.##..|..#..|..#..|..#..|..#..|..#..|.##..'
 '\', '#....|#....|.#...|..#..|...#.|....#|....#'
 '/', '....#|....#|...#.|..#..|.#...|#....|#....'
 ';', '.....|..#..|.....|.....|..#..|..#..|.#...'
 '''','..#..|..#..|.....|.....|.....|.....|.....'
 ',', '.....|.....|.....|.....|..#..|..#..|.#...'
 '.', '.....|.....|.....|.....|.....|..##.|..##.'
 '`', '.#...|..#..|.....|.....|.....|.....|.....'
 };
c = repmat(' ', 1, size(spec,1));
g = cell(1, size(spec,1));
for k = 1:size(spec,1)
 c(k) = spec{k,1};
 g{k} = reshape(strjoin(strsplit(spec{k,2}, '|'), ''), 5, 7)';
end
chars = c; glyphs = g;
end
