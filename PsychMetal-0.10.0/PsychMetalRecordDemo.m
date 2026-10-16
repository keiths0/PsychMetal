function report = PsychMetalRecordDemo(path, codec, seconds, scale, clock)
% PsychMetalRecordDemo  Recording what PsychMetal draws to a movie, then playing the movie back.
%
%   PsychMetalRecordDemo                          % psychmetal_recording.mov, ProRes 4444
%   PsychMetalRecordDemo('clip.mp4', 'hevc')
%   PsychMetalRecordDemo([], [], 5, 0.5)          % 5 seconds at half size
%
% Python: python3 record_demo.py [path] [--codec c] [--seconds s] [--scale x].
%
% Part 1 draws a drifting Gabor patch, a dot circling at one turn a second and a
% frame counter for a few seconds, recording every frame. Now and then the
% program pauses for half a second without drawing: the last frame stays on the
% screen, and in the movie it lasts just as long. (The pause comes every 1.5 s.)
% With audio, a click is scheduled for every whole second, when the dot passes
% three o'clock: the movie's sound track has the clicks on those frames.
%
% Part 2 opens the movie it just wrote and shows it again, smaller and on black,
% each frame at its time in the movie and with the movie's own sound track, so
% the pause and the clicks come back as they were. It checks the movie's frame
% times against Flip's and the clicks against their scheduled times.
%
% The default recording clock is virtual: encoder waiting does not change
% the intended stimulus or generated soundtrack. Pass 'live' as the fifth
% argument to capture live timing instead. Physical diagnostics stay physical.
% Escape (or three fingers) ends part 1 early.
%
% SPDX-License-Identifier: MIT
if nargin < 1 || isempty(path), path = 'psychmetal_recording.mov'; end
if nargin < 2 || isempty(codec), codec = 'prores4444'; end
if nargin < 3 || isempty(seconds), seconds = 3; end
if nargin < 4 || isempty(scale), scale = 1; end
if nargin < 5 || isempty(clock), clock = 'virtual'; end
[w, rect, ifi] = PsychMetal('OpenWindow', [], 128);
windowGuard = onCleanup(@() closeWindow(w)); %#ok<NASGU>
PsychMetal('HideCursor');
W = rect(3); H = rect(4);
r = min(W, H) * .2;
escape = PsychMetal('KbName', 'ESCAPE');
try
 PsychMetal('OpenAudio');
 st = PsychMetal('AudioStatus');
 click = PsychMetal('MakeSound', PsychMetal('Click', st.info.rate));
catch
 click = [];               % no wired output: the movie is recorded without sound
end
[~, name, ext] = fileparts(path);
fprintf(['\nPart 1: the stimulus, recorded to %s%s. At 1.5 s it pauses for half a second on purpose:\n' ...
         '        the frame stays up, and the movie must hold it as long.\n'], name, ext);
PsychMetal('StartMovieRecording', w, path, struct('codec', codec, 'scale', scale, 'clock', clock));
paused = 0;
vbl = PsychMetal('Flip', w); began = vbl;
shown = vbl;               % when each frame was aimed, as Flip reported it
frames = 1;
for k = 1:floor(seconds)
 if ~isempty(click), PsychMetal('Play', click, began + k); end
end
every = round(1.5 / ifi);
textSize = max(14, H * .04);
while vbl - began < seconds
 [~, ~, keys] = PsychMetal('KbCheck');
 if keys(escape), break; end
 t = vbl - began;
 PsychMetal('FillRect', w, 128);
 PsychMetal('DrawGabor', w, [], [W / 2 - r, H / 2 - r, W / 2 + r, H / 2 + r], .5, 6 / r, 0, 360 * t);
 angle = 2 * pi * t;
 x = W / 2 + 1.4 * r * cos(angle); y = H / 2 + 1.4 * r * sin(angle);
 PsychMetal('FillOval', w, [230 60 50], [x - r / 8, y - r / 8, x + r / 8, y + r / 8]);
 PsychMetal('DrawText', w, sprintf('frame %d', frames), W * .05, H * .05, 255, textSize);
 PsychMetal('DrawText', w, sprintf('%6.3f s', t), W * .05, H * .05 + 1.3 * textSize, 255, textSize);
 if mod(frames, every) == 0
  % Half a second with nothing new: the frame before stays up, here and in the movie.
  vbl = PsychMetal('Flip', w, vbl + .5);
  shown(end + 1) = vbl; %#ok<AGROW>
  paused = paused + 1;
 else
  vbl = PsychMetal('Flip', w);
  shown(end + 1) = vbl; %#ok<AGROW>
 end
 frames = frames + 1;
end
rec = PsychMetal('StopMovieRecording', w);
% What the display reported for the same frames: [token status presented committed], oldest first.
PsychMetal('WaitSecs', .2);
reports = PsychMetal('RecentFrames', w, min(256, numel(shown)));
reports = reports(max(1, end - numel(shown) + 1):end, :);
[~, name, ext] = fileparts(rec.path);
fprintf(['        %d frames recorded over %d refreshes (%.3f s at %.2f Hz) to %s%s, %s, %d x %d; ' ...
         '%d half-second pauses.\n'], rec.frames, rec.refreshes, rec.duration, rec.refreshHz, name, ext, ...
        rec.codec, rec.width, rec.height, paused);
fprintf(['        %d frames were shown late live (the copy and the encoder add work); in the movie every ' ...
         'frame is at the refresh it was aimed at.\n'], rec.late);
if rec.sound
 fprintf('        Sound: %.3f s on the track (%.3f s lost).\n', rec.soundSeconds, rec.soundLostSeconds);
else
 fprintf('        Sound: none (audio was not open).\n');
end

[movie, info] = PsychMetal('OpenMovie', w, rec.path);
times = PsychMetal('MovieFrameTimes', movie);
steps = unique(round(diff(times(:)') * rec.refreshHz * 1000) / 1000);
fprintf('Part 2: the movie has %d frames; they are %s refreshes apart.\n', info.frames, mat2str(steps));
% The movie's frame times against Flip's: they should agree to the refresh, frame for frame.
n = min(numel(times), numel(shown));
offsets = round(((times(1:n)' - times(1)) - (shown(1:n) - shown(1))) * rec.refreshHz * 1000) / 1000;
worst = max(abs(offsets));
if worst == 0 && numel(times) == numel(shown)
 fprintf('        Against the times Flip returned live: the largest difference is 0 refreshes (as it should be).\n');
else
 fprintf('        Against the times Flip returned live: the largest difference is %g refreshes; %d frames in the movie, %d flipped.\n', ...
         worst, numel(times), numel(shown));
end
% And against what the display reported showing: the times the participant saw.
seenRows = reports(:, 2) == 0 & reports(:, 3) > 0;
if size(reports, 1) == n && any(seenRows)
 k0 = find(seenRows, 1);
 movieRel = times(1:n)' - times(k0); displayRel = reports(:, 3)' - reports(k0, 3); flipRel = shown(1:n) - shown(k0);
 againstDisplay = round((movieRel(seenRows') - displayRel(seenRows')) * rec.refreshHz * 1000) / 1000;
 fprintf('        Against what the display reported showing (%d of %d frames reported): the largest difference is %g refreshes.\n', ...
         sum(seenRows), n, max(abs(againstDisplay)));
 % Absolute: the time each Flip returned against the display's report of the same frame.
 absolute = round((reports(seenRows, 3)' - shown(seenRows')) * rec.refreshHz * 100) / 100;
 [values, ~, which] = unique(absolute);
 counts = accumarray(which(:), 1)';
 fprintf('        Display report minus the time Flip returned, frame by frame (refreshes): %s.\n', ...
         strjoin(arrayfun(@(v, c) sprintf('%+.2f for %d', v, c), values, counts, 'UniformOutput', false), ', '));
 odd = find(abs(round((movieRel - flipRel) * rec.refreshHz)) > 0);
 for k = odd(1:min(4, end))
  fprintf('          frame %d: movie %.2f, Flip returned %.2f, display %.2f refreshes after frame %d\n', k - 1, ...
          movieRel(k) * rec.refreshHz, flipRel(k) * rec.refreshHz, displayRel(k) * rec.refreshHz, k0 - 1);
 end
end
clicks = [];
if info.soundChannels > 0
 % Each click's first sample, by the movie's clock: it should be at a whole second.
 track = PsychMetal('MovieSound', movie);
 loud = find(abs(track(:, 1)) > .5);
 if ~isempty(loud)
  starts = loud([true; diff(loud) > info.soundRate / 10]);
  clicks = (starts(:)' - 1) / info.soundRate;
  fprintf('        Clicks on the sound track at %s s, scheduled for whole seconds: off by %s ms.\n', ...
          sprintf('%.4f ', clicks), sprintf('%+.2f ', 1000 * (clicks - round(clicks))));
 else
  fprintf('        No clicks on the sound track.\n');
 end
end
s = min([1, .9 * W / info.width, .9 * H / info.height]);
box = [(W - info.width * s) / 2, (H - info.height * s) / 2, (W + info.width * s) / 2, (H + info.height * s) / 2];
fprintf('        Replaying the movie from the file, smaller and on black, with its own sound track:\n');
track = [];
if info.soundChannels > 0 && ~isempty(click)
 st = PsychMetal('AudioStatus');
 track = PsychMetal('MakeSound', PsychMetal('MovieSound', movie, st.info.rate));
end
capacity = min(8, max(1, floor(256*1024*1024/(info.width*info.height*4))));
PsychMetal('PrepareMovie', movie, capacity);
% Decode the first picture before choosing the shared A/V start. Opening
% the reader after Play has started can consume the entire scheduling lead.
PsychMetal('FillRect', w, 0);
PsychMetal('DrawMovieFrame', w, movie, 1, [], box);
start = PsychMetal('NextRefresh', w, PsychMetal('GetSecs') + max(.1, 6 * ifi));
if ~isempty(track), PsychMetal('Play', track, start); end
late = 0; skipped = 0; displayed = 0; maxLate = 0; k = 1; decodeBudget = 0;
while k <= numel(times)
 if k > 1
  % Preview follows the audio clock; expired frames remain in the saved file.
  due = find(times <= times(1) + PsychMetal('GetSecs') + decodeBudget - start, 1, 'last');
  if isempty(due), due = k; end
  newest = min(numel(times), max(k, due));
  skipped = skipped + newest - k; k = newest;
  decodeBegan = PsychMetal('GetSecs');
  PsychMetal('FillRect', w, 0);
  PsychMetal('DrawMovieFrame', w, movie, k, [], box);
  decodeBudget = max(0, PsychMetal('GetSecs') - decodeBegan);
 end
 aim = start + times(k) - times(1);
 seen = PsychMetal('Flip', w, aim);
 delay = max(0, seen - aim);
 late = late + (delay > .5 * ifi); maxLate = max(maxLate, delay);
 displayed = displayed + 1; k = k + 1;
end
elapsed = PsychMetal('GetSecs') - start;
if ~isempty(track), PsychMetal('CloseSound', track); end
fprintf(['        Preview: %d frames shown, %d preview frames skipped; %.3f s elapsed to the last frame, ' ...
         '%.3f s in the file; maximum video delay %.2f ms.\n'], ...
         displayed, skipped, elapsed, times(end) - times(1), 1000 * maxLate);
if skipped || late
 fprintf(['        Replay could not show every frame on time. The preview follows the audio clock; ' ...
          'the saved movie still contains every recorded frame.\n']);
end
PsychMetal('CloseMovie', movie);
report = struct('recording', rec, 'frames', frames, 'paused', paused, 'movieFrames', info.frames, ...
                'steps', steps, 'play', struct('frames', displayed, 'late', late, 'skipped', skipped, 'maxLateMs', 1000 * maxLate, 'elapsed', elapsed), 'clicks', clicks, ...
                'worst', worst);
end

function closeWindow(w)
try, PsychMetal('ShowCursor'); catch, end
try, PsychMetal('Close', w); catch, end
try, PsychMetal('CloseAudio'); catch, end
end
