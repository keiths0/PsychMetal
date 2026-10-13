function result = PsychMetalAudioDemo(seconds)
% PsychMetalAudioDemo  A live spectrogram of the microphone, a recorder and a player.
%
%   PsychMetalAudioDemo           % until Quit or Escape
%   PsychMetalAudioDemo(30)       % at most 30 seconds
%
% The spectrogram scrolls from right to left, 0 to 8 kHz from bottom to top.
% Hold the mouse button down on Record to record; letting go stops it. Play
% plays the recording; Stop stops it. Quit or Escape ends the demo. On a Mac
% the first run asks for microphone access for MATLAB or Octave.
%
% The same demo as python/audio_demo.py. SPDX-License-Identifier: MIT.
if nargin < 1, seconds = []; end
fftSize = 2048; topHz = 8000; floorDb = -100; ceilingDb = -20;
% Any output: with Bluetooth or AirPlay the demo still works and says that its times are not measured.
try
  info = PsychMetal('OpenAudio', struct('input', true, 'recordSeconds', 60, 'routes', 'any'));
catch err
  if ~strcmp(err.identifier, 'PsychMetal:Microphone'), rethrow(err); end
  fprintf('The sound recorder needs the microphone, and access to it is off.\n%s\n', err.message);
  result = struct('log', {{}}, 'recordedSeconds', NaN, 'playedAt', NaN, 'microphone', false);
  return
end
if info.timed, note = ''; else, note = sprintf('  %s adds a delay the system cannot measure.', info.device); end
audioGuard = onCleanup(@() PsychMetal('CloseAudio')); %#ok<NASGU>
rate = info.inputRate;
[w, rect] = PsychMetal('OpenWindow');
windowGuard = onCleanup(@() closeWindow(w)); %#ok<NASGU>
area = safeArea(w, rect);
width = area(3) - area(1); height = area(4) - area(2);
margin = min(width, height) * 0.04;
view = [area(1) + margin, area(2) + margin, area(3) - margin, area(2) + height * 0.72];
rows = 256; columns = 512;
image = zeros(rows, columns, 3, 'uint8');
lut = colormapRows();
texture = PsychMetal('MakeTexture', w, image);
[names, boxes] = buttonsFor(area);
textSize = max(14, height * 0.03);
escape = PsychMetal('KbName', 'ESCAPE');
PsychMetal('BackgroundColor', w, [18 18 26]);
window = 0.5 - 0.5 * cos(2 * pi * (0:fftSize - 1)' / fftSize);
hz = (0:fftSize / 2)' * rate / fftSize;
rowHz = linspace(topHz, 0, rows)';

sound = []; voice = []; recordingId = []; recording = false; waiting = false;
playedAt = NaN; recordedSeconds = NaN; wasDown = false; log = {}; gain = 1; peak = 0;
if isempty(seconds), finish = Inf; else, finish = PsychMetal('GetSecs') + seconds; end
while PsychMetal('GetSecs') < finish
  [x, y, buttons] = PsychMetal('GetMouse', w);
  down = buttons(1); pressed = down && ~wasDown; wasDown = down;
  [anyKey, ~, keys] = PsychMetal('KbCheck');
  if (anyKey && keys(escape)) || (pressed && inside(boxes(4, :), x, y)), break; end
  if pressed && inside(boxes(1, :), x, y)
    PsychMetal('StopSound'); recordingId = PsychMetal('StartRecording'); recording = true; log{end + 1} = 'record'; %#ok<AGROW>
  elseif recording && ~down
    PsychMetal('StopRecording'); recording = false; waiting = true;
  elseif pressed && inside(boxes(2, :), x, y) && ~isempty(sound)
    PsychMetal('StopSound'); voice = PsychMetal('Play', sound, [], [], [], gain); log{end + 1} = 'play'; %#ok<AGROW>
  elseif pressed && inside(boxes(3, :), x, y)
    PsychMetal('StopSound'); log{end + 1} = 'stop'; %#ok<AGROW>
  end

  events = PsychMetal('AudioResults');
  for e = events
    if strcmp(e.kind, 'recording end') && isequal(e.id, recordingId)
      recording = false; waiting = false;
      [samples, rate] = PsychMetal('GetRecording');
      recordedSeconds = size(samples, 1) / rate;
      if ~isempty(sound), PsychMetal('CloseSound', sound); sound = []; end
      if ~isempty(samples), sound = PsychMetal('MakeSound', samples(:, 1), rate); end
      % Playback raises a quiet recording's peak to half scale, by at most 30x (+30 dB):
      % an uncompressed microphone records speech far below full scale.
      peak = double(max(abs(samples(:)))); if isempty(peak), peak = 0; end
      if peak > 0, gain = min(30, 0.5 / peak); else, gain = 1; end
    elseif strcmp(e.kind, 'sound start') && isequal(e.id, voice)
      playedAt = e.time;
    elseif strcmp(e.kind, 'sound end') && isequal(e.id, voice)
      voice = [];
    end
  end

  % The newest input as one new column on the right; older ones move left.
  samples = double(PsychMetal('InputRecent', fftSize / rate));
  magnitude = abs(fft(samples .* window)) / (sum(window) / 2);
  level = interp1(hz, 20 * log10(magnitude(1:fftSize / 2 + 1) + 1e-12), rowHz);
  index = min(max(round((level - floorDb) / (ceilingDb - floorDb) * 255), 0), 255) + 1;
  image(:, 1:end - 1, :) = image(:, 2:end, :);
  image(:, end, :) = reshape(lut(index, :), rows, 1, 3);
  PsychMetal('UpdateTexture', w, texture, image);
  PsychMetal('DrawTexture', w, texture, [], view);
  PsychMetal('FrameRect', w, [90 90 110], view, 2);
  for khz = 0:2:8
    ty = view(4) - (view(4) - view(2)) * khz * 1000 / topHz;
    if khz * 1000 == topHz, ly = ty + textSize * 0.3;            % the top line's label inside the picture
    else, ly = ty - textSize * (1.2 + 0.2 * (khz == 0)); end
    PsychMetal('DrawText', w, sprintf('%d kHz', khz), view(1) + 6, ly, [200 200 210], textSize * 0.7);
  end
  recent = samples(end - round(rate * 0.02) + 1:end);
  meter = min(max((20 * log10(sqrt(mean(recent .^ 2)) + 1e-12) - floorDb) / -floorDb, 0), 1);
  PsychMetal('FillRect', w, [60 200 120], [view(1) view(4) + margin * 0.3 view(1) + (view(3) - view(1)) * meter view(4) + margin * 0.6]);

  for k = 1:4
    active = (k == 1 && recording) || (k == 2 && ~isempty(voice));
    usable = k ~= 2 || ~isempty(sound);
    if active && k == 1, colour = [200 60 60]; elseif active, colour = [60 140 220];
    elseif usable, colour = [70 70 90]; else, colour = [40 40 50]; end
    PsychMetal('FillRect', w, colour, boxes(k, :));
    PsychMetal('FrameRect', w, [150 150 170], boxes(k, :), 2);
    label = names{k};
    if k == 1, if recording, label = 'Recording'; else, label = 'Hold to record'; end, end
    fit = textSize;
    bounds = PsychMetal('TextBounds', w, label, fit);
    if bounds(3) > 0.88 * (boxes(k, 3) - boxes(k, 1))     % a narrow screen: smaller, to fit its button
      fit = fit * 0.88 * (boxes(k, 3) - boxes(k, 1)) / bounds(3);
      bounds = PsychMetal('TextBounds', w, label, fit);
    end
    PsychMetal('DrawText', w, label, (boxes(k, 1) + boxes(k, 3) - bounds(3)) / 2, ...
        (boxes(k, 2) + boxes(k, 4) - bounds(4)) / 2, [240 240 245], fit);
  end
  if recording, status = 'Recording...';
  elseif waiting, status = 'Finishing the recording...';
  elseif ~isnan(recordedSeconds)
    status = sprintf('Recorded %.2f s, peak %.0f dB; plays %+.0f dB through %s.', recordedSeconds, ...
        20 * log10(max(peak, 1e-6)), 20 * log10(gain), info.device);
  else, status = 'Hold Record and speak.'; end
  if ~isnan(playedAt), status = sprintf('%s  Playback started at %.4f s (GetSecs).', status, playedAt); end
  PsychMetal('DrawText', w, [status note], [], area(2) + height * 0.905, [210 210 220], textSize * 0.8, [], width * 0.92);
  PsychMetal('Flip', w);
end
if ~isempty(sound), PsychMetal('CloseSound', sound); end
result = struct('log', {log}, 'recordedSeconds', recordedSeconds, 'playedAt', playedAt, 'microphone', true);
end

function lut = colormapRows()
% 256 colours from near-black through violet and orange to pale yellow.
stops = [0 0.25 0.5 0.75 1];
rgb = [8 8 24; 70 20 110; 190 50 90; 250 150 40; 255 250 200];
x = linspace(0, 1, 256)';
lut = uint8([interp1(stops, rgb(:, 1), x) interp1(stops, rgb(:, 2), x) interp1(stops, rgb(:, 3), x)]);
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

function [names, boxes] = buttonsFor(rect)
% Four buttons in a row below the spectrogram, one [left top right bottom] per row.
names = {'Record', 'Play', 'Stop', 'Quit'};
width = rect(3) - rect(1); height = rect(4) - rect(2);
gap = width * 0.03; w = (width - 5 * gap) / 4;
left = rect(1) + gap + (0:3)' * (w + gap);
boxes = [left rect(2) + height * 0.78 + zeros(4, 1) left + w rect(2) + height * 0.88 + zeros(4, 1)];
end

function yes = inside(box, x, y)
yes = x >= box(1) && x <= box(3) && y >= box(2) && y <= box(4);
end

function closeWindow(w)
try, PsychMetal('Close', w); catch, end
end
