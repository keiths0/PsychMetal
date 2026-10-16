function trials = PsychMetalModulationMatchDemo(seconds, seed)
% PsychMetalModulationMatchDemo  Match the phase or frequency of a flickering blob or a modulated tone.
%
%   trials = PsychMetalModulationMatchDemo          % until Quit or Escape
%   trials = PsychMetalModulationMatchDemo(60, 1)   % at most 60 s, a repeatable sequence
%
% Each trial has a reference and a test, each either seen or heard. Seen: a
% Gaussian blob whose brightness runs from the grey background up to white and
% back. Heard: a tone whose loudness runs from silence up to full and back. Both
% follow (1 + cos(2*pi*f*t + phase)) / 2, t the time since the trial began,
% which is the presentation time of a frame: for the blob, the time of each
% frame; for the tone, each sample's time on the same clock.
%
% The display's refresh rate R is measured first, from confirmed frames. A seen
% stimulus runs only at R / N for an even number N of frames per cycle, with a
% frame on the cycle's start: every cycle then shows the same N frames, equally
% spaced through it, among them its peak and its trough. At 60 Hz, 15 Hz (4
% frames) is possible and 20 Hz (3) is not. Its phase is a whole number of
% frames, a multiple of 1 / N of a cycle. The reference runs at one of seven
% octaves of such frequencies, the fastest the highest at or below 16 Hz (at 60
% or 120 Hz: 15, 7.5, 3.75, 1.875, 0.94, 0.47 and 0.23 Hz), at random. Each
% frame shows the cycle's sample for its place on the refresh grid, so a missed
% frame is skipped rather than delaying the rest, and seen and heard stay together.
%
% Match phase: the test runs at the reference's frequency from a random phase,
% and a dial sets its phase, a circular quantity: a turn is a cycle. A seen test
% moves in steps of a frame, 1 / N of a cycle; a heard one continuously. The
% dial's pointer starts each trial at a random angle, so it says nothing about
% the answer. Match frequency: both start at a peak together, the test from a
% random frequency, and a slider sets its frequency on a log scale across eight
% octaves, which always include the reference octaves with room beyond them so
% that no target sits at an end. A seen test takes the nearest frequency with an
% even number of frames, so its steps are coarse near the top (at 60 Hz: 30, 15,
% 10, 7.5, 6 Hz ...); a heard one moves continuously. The eight octaves shift by
% up to an octave either way each trial, so the knob's place says nothing exact
% about the frequency.
%
% Drag the dial round or the slider's knob along with the mouse, or hold the
% arrow keys: right and up increase, left and down decrease, left and right
% slowly (a tenth of a cycle or an octave a second), up and down quickly (half).
% Match, Space or Return records the setting and shows the error: for phase, the
% test's lead as a percentage of a cycle, the shorter way round the circle (-50
% to 50); for frequency, (f_test - f_reference) / f_reference as a percentage.
% The next trial starts a moment later. The switches across the top choose what
% is matched (Tab switches too) and whether the reference and the test are seen
% or heard; changing one starts a new trial. Quit or Escape ends the demo.
%
% When both are heard, the reference tone is 400 Hz and the test 647 Hz, a ratio
% of 1.6175, far from any harmonic or simple ratio; otherwise a heard stimulus is
% 400 Hz. When both are seen, the reference is on the left.
%
% The errors are only as good as the times behind them: a loudspeaker or display
% that adds delay it does not report shifts every phase setting by that delay,
% which at 15 Hz is 1.5% of a cycle per millisecond. The blob's brightness is
% (1 + cos) / 2 in display values, not luminance; the times of its peaks and
% troughs, which phase matching uses, are the same either way.
%
% trials is a struct array: trial, mode, reference, test, refreshHz,
% referenceHz, referencePhase, start, response, errorPercent, seconds.
%
% The same demo as python/modulation_match_demo.py. SPDX-License-Identifier: MIT.
if nargin < 1, seconds = []; end
if nargin < 2, seed = []; end
if ~isempty(seed), rand('state', seed); end %#ok<RAND>
C = constants();
% Any output: with Bluetooth or AirPlay the demo still works and says that phases include a delay it cannot measure.
info = PsychMetal('OpenAudio', struct('routes', 'any'));
if info.timed, note = ''; else, note = sprintf('  %s adds a delay the system cannot measure: phases include it.', info.device); end
audioGuard = onCleanup(@() PsychMetal('CloseAudio')); %#ok<NASGU>
[w, rect, ifi] = PsychMetal('OpenWindow');
windowGuard = onCleanup(@() closeWindow(w)); %#ok<NASGU>
area = safeArea(w, rect);
ox = area(1); oy = area(2);
width = area(3) - area(1); height = area(4) - area(2);
P = layoutFor(area);
textSize = max(14, height * 0.028);
keys = struct('escape', PsychMetal('KbName', 'ESCAPE'), 'space', PsychMetal('KbName', 'space'), ...
    'enter', PsychMetal('KbName', 'Return'), 'tab', PsychMetal('KbName', 'tab'), 'left', PsychMetal('KbName', 'LeftArrow'), ...
    'right', PsychMetal('KbName', 'RightArrow'), 'up', PsychMetal('KbName', 'UpArrow'), ...
    'down', PsychMetal('KbName', 'DownArrow'));
PsychMetal('BackgroundColor', w, C.grey);
refresh = measureRefresh(w, ifi);
C.references = referenceFrequencies(refresh, C);
presented = PsychMetal('Flip', w) + 1 / refresh;     % when the frame being drawn will be shown

% The two carriers loop from the start and are silent unless asked: a heard
% stimulus is a change of modulation, never a start or a stop.
t = (0:round(info.rate) - 1)' / info.rate;          % one second: whole cycles of any whole-Hz carrier
tones.sounds = [PsychMetal('MakeSound', C.level * sin(2 * pi * C.carriers(1) * t)), ...
                PsychMetal('MakeSound', C.level * sin(2 * pi * C.carriers(2) * t))];
tones.voices = [PsychMetal('Play', tones.sounds(1), [], [], [], [], 0), ...
                PsychMetal('Play', tones.sounds(2), [], [], [], [], 0)];
tones.setting = {NaN, NaN};
toneGuard = onCleanup(@() closeTones(tones)); %#ok<NASGU>
for k = 1:2, tones = setTone(tones, k, [], 0); end

settings = struct('mode', 'Phase', 'reference', 'Seen', 'test', 'Heard');
trials = struct('trial', {}, 'mode', {}, 'reference', {}, 'test', {}, 'refreshHz', {}, 'referenceHz', {}, ...
    'referencePhase', {}, 'start', {}, 'response', {}, 'errorPercent', {}, 'seconds', {});
shown = [];
trial = newTrial(settings, presented, C, refresh);
resume = [];                      % while the error shows: when the next trial starts
wasDown = false; heldKeys = false; heldTab = false; dragging = false; sliding = false; lastAngle = 0;
if isempty(seconds), finish = Inf; else, finish = PsychMetal('GetSecs') + seconds; end
then = PsychMetal('GetSecs');
while PsychMetal('GetSecs') < finish
  now = PsychMetal('GetSecs');
  dt = now - then; then = now;
  [x, y, buttons] = PsychMetal('GetMouse', w);
  down = buttons(1); pressed = down && ~wasDown; wasDown = down;
  [~, ~, code] = PsychMetal('KbCheck');
  confirmKey = code(keys.space) || code(keys.enter);
  confirmed = confirmKey && ~heldKeys; heldKeys = confirmKey;
  if code(keys.tab) && ~heldTab                    % Tab: the other match, a new trial
    if strcmp(settings.mode, 'Phase'), settings.mode = 'Frequency'; else, settings.mode = 'Phase'; end
    trial = newTrial(settings, presented, C, refresh); resume = []; shown = [];
  end
  heldTab = code(keys.tab);

  if code(keys.escape) || (pressed && inside(P.buttons(2, :), x, y)), break; end
  for s = 1:3                                      % a switch: new settings, a new trial
    for side = 1:2
      choice = C.choices{s}{side};
      if pressed && inside(P.switches{s}(side, :), x, y) && ~strcmp(settings.(C.names{s}), choice)
        settings.(C.names{s}) = choice;
        trial = newTrial(settings, presented, C, refresh); resume = []; shown = [];
      end
    end
  end

  if ~isempty(resume)
    if now >= resume, trial = newTrial(settings, presented, C, refresh); resume = []; end
  else
    if pressed && strcmp(trial.mode, 'Phase') && hypot(x - P.dial(1), y - P.dial(2)) <= P.dial(3) * 1.4
      dragging = true; lastAngle = atan2(y - P.dial(2), x - P.dial(1));
    end
    if pressed && strcmp(trial.mode, 'Frequency') && x >= P.slider(1) - 2 * P.slider(4) && ...
        x <= P.slider(2) + 2 * P.slider(4) && abs(y - P.slider(3)) <= 3 * P.slider(4)
      sliding = true;
    end
    if sliding && down
      trial = slide(trial, (x - P.slider(1)) / (P.slider(2) - P.slider(1)));
    end
    if dragging && down
      angle = atan2(y - P.dial(2), x - P.dial(1));
      trial = turn(trial, wrapAngle(angle - lastAngle) / (2 * pi));
      lastAngle = angle;
    end
    by = dt * ((code(keys.right) - code(keys.left)) * C.slow + (code(keys.up) - code(keys.down)) * C.fast);
    if strcmp(trial.mode, 'Phase'), trial = turn(trial, by); else, trial = slide(trial, trial.position + by / C.span); end
    if confirmed || (pressed && inside(P.buttons(1, :), x, y))
      shown = record(trial, numel(trials) + 1, now);
      trials(end + 1) = shown; %#ok<AGROW>
      resume = now + C.feedback;
    end
  end
  if ~down, dragging = false; sliding = false; end

  % The stimuli: the reference's and the test's waves on the trial's clock.
  running = isempty(resume);
  [testHz, testPhase] = testWave(trial);
  refWave = [trial.referenceHz trial.referencePhase];
  tstWave = [testHz testPhase];
  heard = {[], []};
  if running && strcmp(trial.reference, 'Heard'), heard{1} = refWave; end
  if running && strcmp(trial.test, 'Heard')
    if strcmp(trial.reference, 'Heard'), heard{2} = tstWave; else, heard{1} = tstWave; end
  end
  for k = 1:2, tones = setTone(tones, k, heard{k}, trial.origin); end
  seen = {};
  if strcmp(trial.reference, 'Seen') && strcmp(trial.test, 'Seen')
    seen = {1, refWave, 'Reference'; 3, tstWave, 'Test'};
  elseif strcmp(trial.reference, 'Seen')
    seen = {2, refWave, 'Reference'};
  elseif strcmp(trial.test, 'Seen')
    seen = {2, tstWave, 'Test'};
  end
  for k = 1:size(seen, 1)
    box = P.blobs(seen{k, 1}, :);
    wave = seen{k, 2};
    if running
      PsychMetal('DrawGabor', w, [255 255 255 255 * frameLevel(trial, presented, wave(1), wave(2))], box, 0.3);
    end
    label(w, seen{k, 3}, (box(1) + box(3)) / 2, box(4) - textSize * 0.5, textSize * 0.8, []);
  end
  if strcmp(trial.reference, 'Heard') && strcmp(trial.test, 'Heard')
    label(w, sprintf('Listen: reference %d Hz, test %d Hz', C.carriers), ox + width / 2, oy + height * 0.4, textSize, width * 0.94);
  elseif strcmp(trial.reference, 'Heard') || strcmp(trial.test, 'Heard')
    if strcmp(trial.reference, 'Heard'), role = 'reference'; else, role = 'test'; end
    label(w, sprintf('The %s is the %d Hz tone.', role, C.carriers(1)), ox + width / 2, oy + height * 0.585, textSize * 0.8, width * 0.94);
  end

  for s = 1:3
    boxes = P.switches{s};
    label(w, C.titles{s}, (boxes(1, 1) + boxes(2, 3)) / 2, boxes(1, 2) - textSize * 1.15, textSize * 0.75, []);
    for side = 1:2
      if strcmp(settings.(C.names{s}), C.choices{s}{side}), colour = [60 140 220]; else, colour = [70 70 90]; end
      PsychMetal('FillRect', w, colour, boxes(side, :));
      PsychMetal('FrameRect', w, [150 150 170], boxes(side, :), 2);
      centred(w, C.choices{s}{side}, boxes(side, :), textSize * 0.8);
    end
  end
  if strcmp(trial.mode, 'Phase')                 % a dial: phase is circular
    cx = P.dial(1); cy = P.dial(2); radius = P.dial(3);
    if running, colour = [70 70 90]; else, colour = [90 90 100]; end
    PsychMetal('FillOval', w, colour, [cx - radius cy - radius cx + radius cy + radius]);
    PsychMetal('FrameOval', w, [150 150 170], [cx - radius cy - radius cx + radius cy + radius], 3);
    angle = trial.pointer + testPhaseUnwrapped(trial) - trial.dialStart;   % at the phase shown
    PsychMetal('DrawLines', w, [cx + [0.2 0.9] * radius * cos(angle); cy + [0.2 0.9] * radius * sin(angle)], 4, [240 240 245]);
    label(w, 'phase', cx, cy + radius + textSize * 0.3, textSize * 0.75, []);
  else                                           % a slider: frequency has ends
    left = P.slider(1); right = P.slider(2); sy = P.slider(3); knob = P.slider(4);
    PsychMetal('FillRect', w, [70 70 90], [left sy - knob * 0.3 right sy + knob * 0.3]);
    PsychMetal('FrameRect', w, [150 150 170], [left sy - knob * 0.3 right sy + knob * 0.3], 1);
    kx = left + knobPlace(trial) * (right - left);                        % at the frequency shown
    if running, colour = [225 225 235]; else, colour = [150 150 160]; end
    PsychMetal('FillOval', w, colour, [kx - knob sy - knob kx + knob sy + knob]);
    PsychMetal('FrameOval', w, [110 110 130], [kx - knob sy - knob kx + knob sy + knob], 2);
    label(w, 'frequency', (left + right) / 2, sy + knob * 1.3, textSize * 0.75, []);
  end
  names = {'Match', 'Quit'};
  for k = 1:2
    PsychMetal('FillRect', w, [70 70 90], P.buttons(k, :));
    PsychMetal('FrameRect', w, [150 150 170], P.buttons(k, :), 2);
    centred(w, names{k}, P.buttons(k, :), textSize);
  end
  if isempty(shown) && strcmp(trial.mode, 'Phase')
    status = sprintf('Turn the dial until the test matches the reference, then Match. Display %.2f Hz.', refresh);
  elseif isempty(shown)
    status = sprintf('Slide the knob until the test matches the reference, then Match. Display %.2f Hz.', refresh);
  else, status = describe(shown); end
  PsychMetal('DrawText', w, sprintf('Trial %d.  %s%s', numel(trials) + isempty(resume), status, note), [], oy + height * 0.91, ...
      [235 235 240], textSize * 0.8, [], width * 0.92);
  presented = PsychMetal('Flip', w) + 1 / refresh;
end
end

function C = constants()
C.fastest = 16;                        % Hz: the fastest reference is the highest allowed at or below this
C.octaves = 7;                         % reference frequencies: that one and six octaves below
C.span = 8;                            % the slider: an octave below the slowest reference to one above the fastest
C.carriers = [400 647];                % Hz: a heard reference, and a heard test beside it
C.level = 0.25;                        % each tone's peak amplitude
C.feedback = 1.2;                      % seconds the error shows before the next trial
C.slow = 0.1; C.fast = 0.5;            % dial turns, or slider octaves, per second with the arrow keys
C.grey = 128;
C.names = {'mode', 'reference', 'test'};
C.titles = {'Match', 'Reference', 'Test'};
C.choices = {{'Phase', 'Frequency'}, {'Seen', 'Heard'}, {'Seen', 'Heard'}};
end

function f = referenceFrequencies(rate, C)
% Seven octaves of R / N, N even, the fastest the highest at or below C.fastest.
n = max(2, 2 * ceil(rate / C.fastest / 2));
f = rate ./ (n * 2 .^ (0:C.octaves - 1));
end

function f = displayable(hz, rate)
% The frequency nearest hz (on a log scale) that a display at rate shows with an
% even number of frames per cycle.
n = rate / hz;
low = max(2, 2 * floor(n / 2)); high = low + 2;
if abs(log(n / low)) <= abs(log(high / n)), f = rate / low; else, f = rate / high; end
end

function rate = measureRefresh(w, ifi)
% The display's refresh rate from the engine's grid of confirmed frames.
for k = 1:max(60, round(1 / ifi))
  PsychMetal('DrawText', w, 'Measuring the display...', [], [], [220 220 225]);
  PsychMetal('Flip', w);
end
grid = PsychMetal('GridAnchor', w);
if ~(grid(3) >= 30 && isfinite(grid(2)) && grid(2) > 0)
  error('Could not measure the display refresh rate from confirmed frames.');
end
rate = 1 / grid(2);
end

function v = frameLevel(trial, presented, hz, phase)
% A seen stimulus's brightness, 0 to 1, for the frame presented then: the sample
% for that frame's place in its cycle, counted in whole frames on the refresh
% grid, so every cycle repeats exactly with its peak at 1 and its trough at 0.
n = round(trial.rate / hz);
k = mod(round((presented - trial.origin) * trial.rate) + round(phase * n / (2 * pi)), n);
if k == 0, v = 1; elseif 2 * k == n, v = 0; else, v = (1 + cos(2 * pi * k / n)) / 2; end
end

function p = absolutePhase(hz, phase, origin)
% The phase on GetSecs time of the wave with this phase on a clock that starts
% at origin. Whole cycles are removed before multiplying by 2*pi.
cycles = hz * origin;
p = wrapAngle(phase - 2 * pi * (cycles - floor(cycles)));
end

function a = wrapAngle(a)
a = a - 2 * pi * round(a / (2 * pi));
end

function e = phaseError(test, reference)
% How far the test leads the reference, as a percentage of a cycle, the shorter
% way round the circle: -50 to 50.
cycles = (test - reference) / (2 * pi);
e = 100 * (cycles - floor(cycles + 0.5));
end

function P = layoutFor(rect)
% Every control's place: switches{k} two boxes (rows), dial [x y radius],
% slider [left right y knobRadius], buttons (Match; Quit) and the blob boxes
% (left; centre; right).
width = rect(3) - rect(1); height = rect(4) - rect(2);
P.switches = cell(1, 3);
if width >= height                    % side by side, titles above
  gap = width * 0.025; group = (width - 4 * gap) / 3;
  top = height * 0.06; bottom = height * 0.13;
  for k = 1:3
    left = gap + (k - 1) * (group + gap);
    P.switches{k} = [left top left + group / 2 bottom; left + group / 2 top left + group bottom];
  end
  y = height * 0.4;
  P.slider = [width * 0.06, width * 0.44, height * 0.76, max(10, min(width, height) * 0.03)];
else                                  % upright: one row each, titles above
  left = width * 0.06; right = width * 0.94; middle = (left + right) / 2;
  for k = 1:3
    top = height * (0.06 + 0.085 * (k - 1));
    P.switches{k} = [left top middle top + height * 0.05; middle top right top + height * 0.05];
  end
  y = height * 0.42;
  P.slider = [width * 0.1, width * 0.9, height * 0.665, max(12, width * 0.035)];
end
P.dial = [width * 0.27, height * 0.74, min(width * 0.19, height * 0.1)];
P.buttons = [width * 0.5 height * 0.71 width * 0.72 height * 0.81; width * 0.78 height * 0.71 width * 0.95 height * 0.81];
half = min(width, height) * 0.17;
P.blobs = [[0.3; 0.5; 0.7] * width - half, y - half + zeros(3, 1), [0.3; 0.5; 0.7] * width + half, y + half + zeros(3, 1)];
% Laid out from the area's corner.
ox = rect(1); oy = rect(2);
for k = 1:3, P.switches{k} = P.switches{k} + [ox oy ox oy]; end
P.slider = P.slider + [ox ox oy 0];
P.dial = P.dial + [ox oy 0];
P.buttons = P.buttons + [ox oy ox oy];
P.blobs = P.blobs + [ox oy ox oy];
end

function area = safeArea(w, rect)
% The window less the screen's safe-area insets (a phone's camera housing and
% rounded corners; nothing on most Mac displays), in the window's pixels.
d = PsychMetal('Diagnostic', w);
scale = 1; insets = [0 0 0 0];
if isfield(d.summary, 'backingScaleFactor') && d.summary.backingScaleFactor > 0, scale = d.summary.backingScaleFactor; end
if isfield(d.summary, 'screenSafeAreaInsets') && numel(d.summary.screenSafeAreaInsets) == 4 && ...
    all(isfinite(d.summary.screenSafeAreaInsets)) && all(d.summary.screenSafeAreaInsets >= 0)
  insets = double(d.summary.screenSafeAreaInsets(:)') * scale;   % top, left, bottom, right
end
area = [rect(1) + insets(2), rect(2) + insets(1), rect(3) - insets(4), rect(4) - insets(3)];
end

function yes = inside(box, x, y)
yes = x >= box(1) && x <= box(3) && y >= box(2) && y <= box(4);
end

function trial = newTrial(settings, origin, C, rate)
% origin is the presentation time of a frame and rate the measured refresh rate,
% so a seen stimulus's frames fall on its own cycle's grid.
trial.mode = settings.mode; trial.reference = settings.reference; trial.test = settings.test;
trial.origin = origin; trial.rate = rate;
trial.referenceHz = C.references(randi(numel(C.references)));
trial.cycle = round(rate / trial.referenceHz);       % the reference's frames per cycle, even
trial.foot = C.references(1) / 2 ^ (C.span - 1);     % the slider's foot before its shift
trial.span = C.span;
trial.turns = 0;                                     % phase: the dial, from where it started
trial.pointer = 2 * pi * rand;                       % its pointer's starting angle
trial.shift = 2 * rand - 1;                          % frequency: the slider's range, in octaves
trial.position = 0;                                  % its knob, 0 to 1
trial.dialStart = 0;
if strcmp(trial.mode, 'Phase')
  trial.referencePhase = 2 * pi * (randi(trial.cycle) - 1) / trial.cycle;
  trial.dialStart = 2 * pi * rand;                   % the test's phase before any step
else
  trial.referencePhase = 0;                          % both start at a peak, on a frame
  hz = C.references(1) * 2 ^ ((1 - C.octaves) * rand);   % anywhere among the references' octaves
  trial.position = (log2(hz / trial.foot) - trial.shift) / C.span;
end
[hz, phase] = testWave(trial);
if strcmp(trial.mode, 'Phase'), trial.start = phase; else, trial.start = hz; end
end

function trial = turn(trial, by)
% Turns the dial (phase) by `by` turns.
trial.turns = trial.turns + by;
end

function trial = slide(trial, to)
% Puts the slider's knob (frequency) at `to`, 0 to 1.
trial.position = min(max(to, 0), 1);
end

function phase = testPhaseUnwrapped(trial)
% The test's phase, unwrapped: in whole frames when the test is seen.
phase = trial.dialStart + 2 * pi * trial.turns;
if strcmp(trial.test, 'Seen')
  step = 2 * pi / trial.cycle;
  phase = step * round(phase / step);
end
end

function [hz, phase] = testWave(trial)
if strcmp(trial.mode, 'Phase')
  hz = trial.referenceHz; phase = mod(testPhaseUnwrapped(trial), 2 * pi);
else
  hz = trial.foot * 2 ^ (trial.shift + trial.span * trial.position); phase = trial.referencePhase;
  if strcmp(trial.test, 'Seen'), hz = displayable(hz, trial.rate); end
end
end

function p = knobPlace(trial)
% Where the slider's knob is: at the frequency shown.
hz = testWave(trial);
p = min(max((log2(hz / trial.foot) - trial.shift) / trial.span, 0), 1);
end

function r = record(trial, number, now)
[hz, phase] = testWave(trial);
if strcmp(trial.mode, 'Phase')
  response = phase; e = phaseError(phase, trial.referencePhase);
else
  response = hz; e = 100 * (hz - trial.referenceHz) / trial.referenceHz;
end
r = struct('trial', number, 'mode', lower(trial.mode), 'reference', lower(trial.reference), ...
    'test', lower(trial.test), 'refreshHz', trial.rate, 'referenceHz', trial.referenceHz, 'referencePhase', trial.referencePhase, ...
    'start', trial.start, 'response', response, 'errorPercent', e, 'seconds', now - trial.origin);
end

function s = describe(r)
if strcmp(r.mode, 'phase')
  if r.errorPercent > 0, lead = 'leads'; elseif r.errorPercent < 0, lead = 'lags'; else, lead = 'matches'; end
  s = sprintf('Phase error %+.1f%% of a cycle: the test %s (reference %g Hz).', r.errorPercent, lead, r.referenceHz);
else
  s = sprintf('Frequency error %+.1f%%: %.3f Hz for %g Hz.', r.errorPercent, r.response, r.referenceHz);
end
end

function tones = setTone(tones, k, wave, origin)
% wave [hz phase] on the trial's clock from origin, or [] for silence.
if isempty(wave), setting = []; else, setting = [wave origin]; end
if isequal(setting, tones.setting{k}), return; end
tones.setting{k} = setting;
if isempty(wave)
  PsychMetal('Modulate', tones.voices(k), 0, pi, 1);          % 1 - (1 - cos(pi)) / 2 = 0
else
  PsychMetal('Modulate', tones.voices(k), wave(1), absolutePhase(wave(1), wave(2), origin), 1);
end
end

function closeTones(tones)
try
  PsychMetal('StopSound');
  for s = tones.sounds, PsychMetal('CloseSound', s); end
catch
end
end

function [px, tw, th] = fit(w, text, px, width)
% The text's size, made smaller if need be to fit width, and its extent.
b = PsychMetal('TextBounds', w, text, px);
if ~isempty(width) && b(3) > width
  px = px * width / b(3);
  b = PsychMetal('TextBounds', w, text, px);
end
tw = b(3); th = b(4);
end

function label(w, text, x, y, px, width)
% Text centred on x, its top at y, no wider than width.
[px, tw] = fit(w, text, px, width);
PsychMetal('DrawText', w, text, x - tw / 2, y, [225 225 230], px);
end

function centred(w, text, box, px)
% Text centred in a box, made smaller if need be to fit it.
[px, tw, th] = fit(w, text, px, 0.88 * (box(3) - box(1)));
PsychMetal('DrawText', w, text, (box(1) + box(3) - tw) / 2, (box(2) + box(4) - th) / 2, [240 240 245], px);
end

function closeWindow(w)
try, PsychMetal('Close', w); catch, end
end
