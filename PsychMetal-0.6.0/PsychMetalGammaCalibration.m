function report = PsychMetalGammaCalibration(opts)
% PsychMetalGammaCalibration  Measure the display's gamma by eye, as well as an eye can.
%
%   report = PsychMetalGammaCalibration
%   report = PsychMetalGammaCalibration(struct('full', true))
%
% A pattern whose pixels are half one grey and half another emits the mean of
% their light, whatever the display's gamma. You adjust a uniform square inside
% such a pattern until the two match, and the square's grey is then known to
% emit that light. Nothing else is assumed, and no instrument is used.
%
%   1. Half of white, twice: against black and white rows four pixels thick,
%      and against columns. Rows and columns that agree are evidence that the
%      display shows such a pattern at its mean light; their mean is taken as
%      half of white.
%   2. A quarter and three quarters. Stripes of black and the half grey are a
%      quarter of white, and stripes of the half grey and white three quarters.
%   3. The fit. The three matches are compared with a power law (its best
%      gamma), with gamma 2.2 and with the sRGB curve, each by how many grey
%      levels it misses them. report.table follows the measured points, for
%      PsychMetal('Linearize', w, report.table).
%   4. A check. With that table in use, a square at half is shown inside black
%      and white stripes. They should now match, and you say whether they do.
%
% That is four matches and a question: a minute or two. struct('full', true) is
% the long form, about ten minutes: half of white against nine patterns (rows
% and columns 1, 2, 4 and 8 pixels thick and a one-pixel checkerboard), which
% shows whether fine patterns are at their mean light, then seven levels from
% an eighth to seven eighths of white, every match made twice. Coarse patterns
% need distance.
%
% The grey's number is not shown while you match, so it cannot guide you.
%
% Options, as fields of opts:
%   full      true for the long form (default false)
%   repeats   matches of each pattern, 1 to 10 (default 1; 2 with full)
%   levels    levels of the curve, 3 or 7 (default 3; 7 with full)
%   channels  'grey' (default), or 'rgb': red, green and blue each on its own
%   pattern   the pattern the curve is measured with: 'rows' or 'cols' and a
%             thickness of 1, 2, 4 or 8, or 'check1' (default 'rows4'; 'rows8'
%             with full)
%   patterns  those half of white is matched against first: by default the
%             pattern and its other orientation, and all nine with full
%   check     false leaves that out (default true)
%   seed      seeds the starting greys
%   observer  replaces the person, for tests: a function of (low, high, mask,
%             pattern, start, label) returning a grey
%
% Keys: each tap of Up or Down changes the grey by one, of Right or Left by
% eight; a key held down counts once. Space
% accepts. Escape stops, and what was measured so far is reported. A mouse
% click skips a match.
%
% This is a calibration by eye. It finds the grey that matches a known fraction
% of white to about one grey level; it cannot measure the light itself, and
% below the darkest level matched it measures nothing. For work that depends on
% luminance, use a photometer.
%
% report has pattern, repeats, levels, matches (one element per match),
% patternCheck, curves (one field per channel: points [light grey], matches,
% gamma, rmsPower, rmsGamma22, rmsSRGB, table), gamma (one per channel), table
% (256x3, or [] when not every channel was measured), verified and complete.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(opts), opts = struct(); end
assert(isstruct(opts) && isscalar(opts), 'PsychMetalGammaCalibration takes one struct of options.');
known = {'full', 'repeats', 'levels', 'channels', 'pattern', 'patterns', 'check', 'seed', 'observer'};
given = fieldnames(opts);
for k = 1:numel(given)
 assert(any(strcmp(given{k}, known)), 'Unknown option ''%s''.', given{k});
end
full = isequal(option(opts, 'full', false), true) || isequal(option(opts, 'full', false), 1);
repeats = option(opts, 'repeats', 1 + full);
levels = option(opts, 'levels', 3 + 4 * full);
channels = option(opts, 'channels', 'grey');
if full, pattern = option(opts, 'pattern', 'rows8'); else, pattern = option(opts, 'pattern', 'rows4'); end
check = option(opts, 'check', true);
seed = option(opts, 'seed', []);
observer = option(opts, 'observer', []);
every = {'rows1', 'rows2', 'rows4', 'rows8', 'cols1', 'cols2', 'cols4', 'cols8', 'check1'};
assert(isnumeric(repeats) && isscalar(repeats) && repeats == floor(repeats) && repeats >= 1 && repeats <= 10, ...
    'repeats is 1 to 10.');
assert(isequal(levels, 3) || isequal(levels, 7), 'levels is 3 or 7.');
assert(ischar(channels) && any(strcmp(channels, {'grey', 'rgb'})), 'channels is ''grey'' or ''rgb''.');
assert(ischar(pattern) && any(strcmp(pattern, every)), 'pattern is rows or cols with 1, 2, 4 or 8, or check1.');
partner = '';
if strncmp(pattern, 'rows', 4), partner = ['cols' pattern(5:end)]; end
if strncmp(pattern, 'cols', 4), partner = ['rows' pattern(5:end)]; end
if full, patterns = every; elseif isempty(partner), patterns = {pattern}; else, patterns = {pattern, partner}; end
patterns = option(opts, 'patterns', patterns);
assert(iscellstr(patterns) && all(ismember(patterns, every)), 'patterns is a cell array of pattern names.');
if ~check, patterns = {}; end
if strcmp(channels, 'grey'), names = {'grey'}; else, names = {'red', 'green', 'blue'}; end
masks = struct('grey', [1 1 1], 'red', [1 0 0], 'green', [0 1 0], 'blue', [0 0 1]);
if ~isempty(seed), rand('state', seed); end %#ok<RAND>
nominal = 2.2;       % used only to choose starting greys and for corrections of under half a grey level

report = struct('pattern', pattern, 'repeats', repeats, 'levels', levels, 'matches', [], 'patternCheck', [], ...
    'curves', struct(), 'gamma', [], 'table', [], 'verified', [], 'complete', false);
report.matches = struct('stage', {}, 'channel', {}, 'pattern', {}, 'low', {}, 'high', {}, 'light', {}, ...
    'start', {}, 'matched', {});
report.patternCheck = struct('pattern', {}, 'matches', {}, 'mean', {});

steps = [0.5 0 1; 0.25 0 0.5; 0.75 0.5 1];
if levels == 7, steps = [steps; 0.125 0 0.25; 0.375 0.25 0.5; 0.625 0.5 0.75; 0.875 0.75 1]; end

S = struct('w', [], 'rect', [], 'side', 0, 'outer', [], 'inner', [], 'count', 0, 'todo', 0, 'stopped', false, ...
    'repeats', repeats, 'nominal', nominal, 'masks', masks);
S.observer = observer;
S.todo = numel(names) * levels * repeats + numel(patterns) * repeats;
if strcmp(channels, 'grey') && any(strcmp(pattern, patterns))
 S.todo = S.todo - repeats;                                    % half of white in the curve's pattern is matched once
end
cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
try
 [S.w, S.rect] = PsychMetal('OpenWindow', [], 0);
 PsychMetal('HideCursor');
 W = S.rect(3); H = S.rect(4);
 S.side = 16 * floor(min(W, H) * 0.0375);
 left = floor((W - S.side) / 2); top = floor(H * 0.26);
 S.outer = [left, top, left + S.side, top + S.side];
 S.inner = [left + S.side / 4, top + S.side / 4, left + 3 * S.side / 4, top + 3 * S.side / 4];

 % ---- 1. half of white, by pattern --------------------------------------
 if ~isempty(patterns)
  for k = 1:numel(patterns)
   if S.stopped, break; end
   [values, S, report, cache] = matchPattern(S, report, cache, 'grey', patterns{k}, 0, 255, 0.5, 'patterns');
   if ~isempty(values)
    report.patternCheck(end + 1) = struct('pattern', patterns{k}, 'matches', values, 'mean', mean(values));
   end
  end
 end

 % ---- 2. the curve, by halving ------------------------------------------
 for c = 1:numel(names)
  channel = names{c};
  target = [0 1]; shown = [0 255]; shownLight = [0 1];   % the grey shown for each target, and its light
  points = zeros(0, 2); matched = {};
  for s = 1:size(steps, 1)
   if S.stopped, break; end
   lo = find(target == steps(s, 2), 1); hi = find(target == steps(s, 3), 1);
   if isempty(lo) || isempty(hi), continue; end
   light = (shownLight(lo) + shownLight(hi)) / 2;
   [values, S, report, cache] = matchPattern(S, report, cache, channel, pattern, shown(lo), shown(hi), light, 'curve');
   if steps(s, 1) == 0.5 && strcmp(channel, 'grey') && any(strcmp(partner, patterns))
    % Half of white was also matched against the other orientation: use both.
    key = sprintf('grey|%s|0|255', partner);
    if isKey(cache, key), values = [values, cache(key)]; end
   end
   if isempty(values), continue; end
   m = mean(values);
   % The grey shown later is a whole number; its light differs from the match's by this much.
   target(end + 1) = steps(s, 1); shown(end + 1) = round(m); %#ok<AGROW>
   shownLight(end + 1) = light * (round(m) / m) ^ nominal; %#ok<AGROW>
   points(end + 1, :) = [light, m]; matched{end + 1} = values; %#ok<AGROW>
  end
  if ~isempty(points)
   [points, order] = sortrows(points);
   curve = analyse(points);
   curve.points = points;
   curve.matches = matched(order);
   report.curves.(channel) = curve;
  end
 end
 if numel(fieldnames(report.curves)) == numel(names)
  report.complete = true;
  table = zeros(256, 3);
  for c = 1:numel(names)
   curve = report.curves.(names{c});
   report.gamma(c) = curve.gamma;
   if numel(names) == 1, table = repmat(curve.table, 1, 3); else, table(:, c) = curve.table; end
   report.complete = report.complete && size(curve.points, 1) == levels;
  end
  report.table = table;
 end

 % ---- 4. the check: with the table in use, half is half -----------------
 if ~isempty(report.table) && isempty(observer) && ~S.stopped
  PsychMetal('Linearize', S.w, report.table);
  texture = PsychMetal('MakeTexture', S.w, patternImage(S.side, pattern, 0, 255, [1 1 1]));
  lines = {'Check. The table just measured is in use, so the square is set to half of white.', ...
      sprintf('The pattern is %s, black and white: also half of white.', patternName(pattern)), ...
      'Step back, or defocus, until the pattern blurs.', ...
      'Does the square match the pattern?   Y yes   N no'};
  [answer, ~, S.stopped] = runScreen(S, lines, texture, 127.5, [1 1 1], {'y', 'n'}, false);
  PsychMetal('CloseTexture', S.w, texture);
  PsychMetal('Linearize', S.w, []);
  if ~isempty(answer), report.verified = strcmp(answer, 'y'); end
 end
 PsychMetal('ShowCursor');
 PsychMetal('Close', S.w); S.w = [];
catch e
 try, PsychMetal('ShowCursor'); catch, end
 try, if ~isempty(S.w), PsychMetal('Close', S.w); end; catch, end
 rethrow(e);
end
printReport(report);
end

% -------------------------------------------------------------------------
function value = option(opts, name, default)
if isfield(opts, name) && ~isempty(opts.(name)), value = opts.(name); else, value = default; end
end

function name = patternName(pattern)
t = pattern(end) - '0';
plural = ''; if t > 1, plural = 's'; end
switch pattern(1:end - 1)
 case 'rows', name = sprintf('rows %d pixel%s thick', t, plural);
 case 'cols', name = sprintf('columns %d pixel%s thick', t, plural);
 otherwise, name = 'checkerboard of single pixels';
end
end

function image = patternImage(side, pattern, low, high, mask)
% side x side uint8, half its pixels low and half high; side is a multiple of 16.
band = mod(floor((0:side - 1)' / (pattern(end) - '0')), 2) == 0;
switch pattern(1:end - 1)
 case 'rows', on = repmat(band, 1, side);
 case 'cols', on = repmat(band', side, 1);
 otherwise, on = repmat(band, 1, side) == repmat(band', side, 1);
end
grey = uint8(low) * ones(side, side, 'uint8');
grey(on) = uint8(high);
if isequal(mask, [1 1 1])
 image = grey;
else
 image = zeros(side, side, 3, 'uint8');
 for c = 1:3
  if mask(c), image(:, :, c) = grey; end
 end
end
end

function [values, S, report, cache] = matchPattern(S, report, cache, channel, pattern, low, high, light, stage)
% Matches of this pattern, each from a new starting grey: a row of greys, possibly empty.
key = sprintf('%s|%s|%d|%d', channel, pattern, low, high);
if isKey(cache, key), values = cache(key); return; end
expected = 255 * light ^ (1 / S.nominal);
mask = S.masks.(channel);
values = [];
for r = 1:S.repeats
 S.count = S.count + 1;
 offset = 8 + 12 * rand;
 if rand < 0.5, offset = -offset; end
 start = min(254, max(1, round(expected + offset)));
 label = sprintf('Match %d of %d, %s.', S.count, S.todo, channel);
 if ~isempty(S.observer)
  got = S.observer(low, high, mask, pattern, start, label);
 else
  texture = PsychMetal('MakeTexture', S.w, patternImage(S.side, pattern, low, high, mask));
  lines = {sprintf('%s The pattern is %s.', label, patternName(pattern)), ...
      'Step back, or defocus, until the pattern blurs to a uniform field.', ...
      'Make the square in the middle match it: as bright, no brighter. Judge the areas, not the edge.', ...
      'Each tap of Up or Down changes the square by one level, of Right or Left by eight; holding does no more. Space accepts.'};
  [answer, got, S.stopped] = runScreen(S, lines, texture, start, mask, {'space'}, true);
  PsychMetal('CloseTexture', S.w, texture);
  if isempty(answer), got = []; end
 end
 if isempty(got), break; end
 values(end + 1) = got; %#ok<AGROW>
 report.matches(end + 1) = struct('stage', stage, 'channel', channel, 'pattern', pattern, 'low', low, ...
     'high', high, 'light', light, 'start', start, 'matched', got);
end
cache(key) = values;
end

function [answer, grey, stopped] = runScreen(S, lines, texture, grey, mask, answers, adjustable)
% Draw the pattern and the square until an answer key is pressed. answer is ''
% after a mouse click or Escape; stopped is true after Escape.
names = {'y', 'n', 'space', 'UpArrow', 'DownArrow', 'LeftArrow', 'RightArrow', 'ESCAPE'};
steps = [0 0 0 1 -1 -8 8 0];
codes = zeros(1, numel(names));
for k = 1:numel(names), codes(k) = PsychMetal('KbName', names{k}); end
settle = 30;         % frames before a screen takes an answer, so one press cannot answer two
W = S.rect(3); H = S.rect(4);
textSize = max(12, floor(H / 50));
isAnswer = ismember(names, answers);
held = false(1, numel(names));
answer = ''; stopped = false; frame = 0;
while true
 PsychMetal('DrawTexture', S.w, texture, [], S.outer, 0, 0);
 PsychMetal('FillRect', S.w, grey * mask, S.inner);
 for k = 1:numel(lines)
  PsychMetal('DrawText', S.w, lines{k}, floor(W * 0.04), floor(H * 0.02 + (k - 1) * textSize * 1.35), 220, textSize);
 end
 PsychMetal('Flip', S.w);
 frame = frame + 1;
 [~, ~, keyCode] = PsychMetal('KbCheck');
 down = logical(keyCode(codes));
 fresh = down & ~held;
 held = down;
 if down(8), stopped = true; break; end
 if adjustable
  for k = 4:7
   if fresh(k), grey = min(255, max(0, grey + steps(k))); end
  end
 end
 if frame <= settle, continue; end
 hit = find(fresh & isAnswer, 1);
 if ~isempty(hit), answer = names{hit}; break; end
 [~, ~, buttons] = PsychMetal('GetMouse', S.w);
 if any(buttons), break; end
end
end

function fit = analyse(points)
% Fit matched points [light grey], light a fraction of white strictly between 0
% and 1: the power law that best fits them (least squares in log light), how
% far each curve's predicted greys are from the matched ones in grey levels
% rms, and a table of 256 display values 0-1 for evenly spaced linear values,
% which follows the points with a power law between each pair and continues the
% darkest one to black.
light = points(:, 1); grey = points(:, 2);
lg = log(grey / 255); ll = log(light);
fit.gamma = sum(ll .* lg) / sum(lg .* lg);
rmsOf = @(predicted) sqrt(mean((predicted - grey) .^ 2));
fit.rmsPower = rmsOf(255 * light .^ (1 / fit.gamma));
fit.rmsGamma22 = rmsOf(255 * light .^ (1 / 2.2));
srgb = 1.055 * light .^ (1 / 2.4) - 0.055;
srgb(light <= 0.0031308) = 12.92 * light(light <= 0.0031308);
fit.rmsSRGB = rmsOf(255 * srgb);
x = [ll; 0]; y = [lg; 0];
linear = (0:255)' / 255;
table = zeros(256, 1);
lx = log(linear(2:end));
ly = interp1(x, y, lx, 'linear');
slope = (y(2) - y(1)) / (x(2) - x(1));
below = lx < x(1);
ly(below) = y(1) + (lx(below) - x(1)) * slope;
table(2:end) = exp(ly);
fit.table = min(1, max(0, table));
end

function printReport(report)
fprintf('\n===== gamma =====\n');
if ~isempty(report.patternCheck)
 fprintf('Half of white, by pattern: the grey that matched black and white.\n');
 for k = 1:numel(report.patternCheck)
  row = report.patternCheck(k);
  fprintf('  %-30s %6.1f   (%s)\n', patternName(row.pattern), row.mean, listed(row.matches));
 end
 means = [report.patternCheck.mean];
 within = [];
 for k = 1:numel(report.patternCheck)
  values = report.patternCheck(k).matches;
  for a = 1:numel(values) - 1, within = [within, abs(values(a) - values(a + 1:end))]; end %#ok<AGROW>
 end
 typical = 0;
 if ~isempty(within), typical = mean(within); end
 tolerance = max(2, 1.5 * typical);
 spread = max(means) - min(means);
 names = {report.patternCheck.pattern};
 thickness = cellfun(@(name) name(end) - '0', names);
 isRows = strncmp(names, 'rows', 4); isCols = strncmp(names, 'cols', 4);
 if any(isRows) && any(isCols)
  rows = find(isRows & thickness == max(thickness(isRows)), 1);
  cols = find(isCols & thickness == max(thickness(isCols)), 1);
  coarse = (means(rows) + means(cols)) / 2;
  others = setdiff(1:numel(means), [rows cols]);
  if abs(means(rows) - means(cols)) > tolerance
   fprintf('  Rows and columns differ (%.1f and %.1f). Neither can be trusted to be half of white.\n', means(rows), means(cols));
   fprintf('  Treat what follows as approximate, and measure with a photometer.\n');
  else
   fprintf('  Rows and columns agree (%.1f and %.1f): half of white is grey %.1f, a gamma of %.2f at that point.\n', ...
       means(rows), means(cols), coarse, log(0.5) / log(coarse / 255));
   if ~isempty(others)
    [far, at] = max(abs(means(others) - coarse));
    if far <= tolerance
     fprintf('  The finer patterns agree with them: fine detail is shown at its mean light.\n');
    else
     fprintf('  Finer patterns are up to %.1f grey levels from it (%s: %.1f):\n', far, patternName(names{others(at)}), means(others(at)));
     fprintf('  this display does not show all fine detail at its mean light.\n');
    end
   end
  end
 elseif numel(means) > 1
  fprintf('  The patterns matched differ by %.1f grey levels.\n', spread);
 end
end
channels = fieldnames(report.curves);
if isempty(channels)
 fprintf('Curve: not measured.\n');
 return;
end
fprintf('The curve, measured with %s:\n', patternName(report.pattern));
differences = []; darkest = 1;
if ~isempty(report.matches)
 keys = arrayfun(@(m) sprintf('%s|%s|%d|%d', m.channel, m.pattern, m.low, m.high), report.matches, 'UniformOutput', false);
 [~, ~, group] = unique(keys);
 for g = 1:max(group)
  values = [report.matches(group == g).matched];
  for a = 1:numel(values) - 1, differences = [differences, abs(values(a) - values(a + 1:end))]; end %#ok<AGROW>
 end
end
for c = 1:numel(channels)
 curve = report.curves.(channels{c});
 fprintf('  %s:  light   grey   matches\n', channels{c});
 for k = 1:size(curve.points, 1)
  values = curve.matches{k};
  fprintf('         %6.3f  %5.1f   (%s)\n', curve.points(k, 1), curve.points(k, 2), listed(values));
 end
 darkest = min(darkest, curve.points(1, 1));
 fprintf('    Best power law: gamma %.2f, which misses the matches by %.1f grey levels rms.\n', curve.gamma, curve.rmsPower);
 fprintf('    Gamma 2.2 misses them by %.1f, and the sRGB curve by %.1f.\n', curve.rmsGamma22, curve.rmsSRGB);
end
if ~isempty(differences)
 fprintf('Repeated matches of the same pattern differed by %.1f grey levels on average, %d at most.\n', ...
     mean(differences), max(differences));
end
if isempty(report.table)
 fprintf('Not every channel was measured, so there is no table.\n');
 return;
end
if ~report.complete
 fprintf('Some levels were skipped; the table follows the ones that were matched.\n');
end
fprintf('report.table follows the measured points: PsychMetal(''Linearize'', w, report.table). Below %g of white\n', darkest);
fprintf('nothing was measured, and the table continues the darkest measured part of the curve.\n');
if ~isempty(report.verified)
 if report.verified
  fprintf('Check, with the table in use: half matched black and white stripes: yes.\n');
 else
  fprintf('Check, with the table in use: half matched black and white stripes: no.\n');
  fprintf('  If the areas differed, the table does not make half of white half the light: do not use it.\n');
  fprintf('  If only an edge showed, the areas may match; an edge is not evidence either way.\n');
 end
end
fprintf('Measured by eye. A photometer measures light; this finds greys that match.\n');
end

function text = listed(values)
text = strtrim(sprintf('%d, ', values));
text = text(1:end - 1);
end
