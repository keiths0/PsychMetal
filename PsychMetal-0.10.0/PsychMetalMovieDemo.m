function report = PsychMetalMovieDemo(path, sound)
% PsychMetalMovieDemo  A movie, frame by frame: played whole, then drawn inside a stimulus.
%
%   PsychMetalMovieDemo                          % the test movie make test writes
%   PsychMetalMovieDemo('~/Movies/clip.mov')
%   PsychMetalMovieDemo('clip.mp4', 'stretch')
%
% Python: python3 movie_demo.py [path] [--sound mode].
%
% Any movie macOS reads (.mov, .mp4, .m4v; H.264, HEVC, ProRes and the rest).
%
% Part 1 plays the movie with PlayMovie: every frame for the same whole number of
% refreshes, the nearest to the refresh rate over the movie's frame rate. A 30 fps
% movie on a 60 Hz display shows each frame for 2 refreshes and plays at its own
% rate; a 24 fps movie shows each for 3 and plays at 20 fps, and says so. Nothing
% is dropped or shown longer than the rest. The report says what the display
% reported: frames shown, and any shown late.
%
% Part 2 draws the frames with DrawMovieFrame, which works like DrawTexture, so a
% movie can be one element of a stimulus: here it turns slowly inside a frame,
% with its frame number written under it, stepping one movie frame every
% `refreshes` refreshes.
%
% sound: 'auto' (default: the movie's sound when it plays at its own rate),
% 'off', 'resample' (sound follows the frames' rate, its pitch with it) or
% 'stretch' (sound follows the frames' rate at its own pitch).
%
% Escape (or three fingers) ends either part early.
%
% SPDX-License-Identifier: MIT
if nargin < 1 || isempty(path)
 path = fullfile(fileparts(which('PsychMetal')), 'tests', 'movies', 'frames_h264.mp4');
end
if nargin < 2 || isempty(sound), sound = 'auto'; end
w = PsychMetal('OpenWindow', [], 0);
windowGuard = onCleanup(@() closeAll(w)); %#ok<NASGU>
PsychMetal('HideCursor');
rect = PsychMetal('Rect', w);
audio = true;
try
 PsychMetal('OpenAudio');
catch
 audio = false;           % no wired output: the frames play without the sound
end
[movie, info] = PsychMetal('OpenMovie', w, path);
[~, name, ext] = fileparts(path);
if info.soundChannels > 0
 soundText = sprintf('sound %d channels at %d Hz.', info.soundChannels, info.soundRate);
else
 soundText = 'no sound.';
end
fprintf('\n%s%s: %d x %d, %d frames at %.3f per second (%s), %s\n', name, ext, info.width, info.height, ...
        info.frames, info.frameRate, info.codec, soundText);
if ~info.constantRate
 fprintf('The frames are not evenly spaced in time; each is still shown for the same number of refreshes.\n');
end
W = rect(3); H = rect(4);
scale = min([1, .8 * W / info.width, .7 * H / info.height]);
mw = info.width * scale; mh = info.height * scale;
box = [(W - mw) / 2, (H - mh) / 2, (W + mw) / 2, (H + mh) / 2];

% Part 1: the whole movie.
if ~audio, sound = 'off'; end
r = PsychMetal('PlayMovie', w, movie, struct('dstRect', box, 'sound', sound));
fprintf(['Part 1: %d frames, each for %d refreshes of %.2f Hz: %.3f frames per second ' ...
         '(the movie''s own: %.3f). Sound: %s.\n'], r.frames, r.refreshes, r.expectedRefreshHz, r.rate, ...
        info.frameRate, r.sound);
fprintf(['        The display reported %d of %d refreshes; %d late, by %d refreshes in all; ' ...
         'longest interval %.1f ms.\n'], r.shown, r.submitted, r.late, r.lateRefreshes, r.longestIntervalMs);

% Part 2: one element of a stimulus.
k = r.refreshes;
escape = PsychMetal('KbName', 'ESCAPE');
frames = info.frames;
shown = 0;
textSize = max(14, H * .03);
for i = 0:frames * k - 1
 [~, ~, keys] = PsychMetal('KbCheck');
 if keys(escape), break; end
 index = floor(i / k) + 1;
 angle = 10 * (i / (frames * k)) - 5;
 PsychMetal('FillRect', w, 40);
 PsychMetal('FrameRect', w, [255 200 0], [box(1) - 8, box(2) - 8, box(3) + 8, box(4) + 8], 4);
 PsychMetal('DrawMovieFrame', w, movie, index, [], box, angle);
 label = sprintf('frame %d of %d', index, frames);
 bounds = PsychMetal('TextBounds', w, label, textSize);
 PsychMetal('DrawText', w, label, (W - bounds(3)) / 2, box(4) + 16, [220 220 220], textSize);
 PsychMetal('Flip', w);
 shown = shown + 1;
end
fprintf('Part 2: %d refreshes, the movie turning inside a frame, one movie frame every %d.\n', shown, k);
PsychMetal('CloseMovie', movie);
report = struct('play', r, 'refreshes', shown);
end

function closeAll(w)
try, PsychMetal('ShowCursor'); catch, end
try, PsychMetal('Close', w); catch, end
try, PsychMetal('CloseAudio'); catch, end
end
