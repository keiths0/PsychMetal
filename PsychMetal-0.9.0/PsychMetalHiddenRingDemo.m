function report = PsychMetalHiddenRingDemo(seconds, speed, cellSize)
% PsychMetalHiddenRingDemo  A ring of noise in noise, hidden until it moves.
%
%   PsychMetalHiddenRingDemo                 % 20 s, drifting 1 pixel per frame, 1-pixel cells
%   PsychMetalHiddenRingDemo(30, 0, 3)       % still background, 3-pixel cells
%
% Python: python3 hidden_ring_demo.py [seconds] --speed N --cell N. The phone
% app offers the same two settings on the demo's start page.
%
% The background is a fixed noise image in a centered square, with black
% outside. The ring holds a second fixed noise image and moves with the mouse,
% by the same amount, anywhere in the window including the black margins. A
% click or the space bar changes the ring to a drifting grating and back.
% Escape ends it. Neither noise image is made or uploaded: each value is
% computed on the GPU from the seed and the pixel's place in the rectangle
% drawn, so moving a rectangle moves its image.
%
% speed is how many pixels the background drifts sideways each frame; 0 is
% still. The ring rides along with it, and the mouse's movement is added to
% that. It is then never drawn in the same place on two frames running: where
% the mouse would exactly undo the drift, it is drawn a step back. A ring that
% leaves one side comes in at the other.
%
% cellSize is the width of a noise cell in pixels. The ring is made of whole cells,
% always a whole number of cells from the background's corner, so its edge
% cuts no cell: every pixel shows one image or the other, and a ring that is
% not moving against the background cannot be seen.
%
% SPDX-License-Identifier: MIT
if nargin < 1 || isempty(seconds), seconds = 20; end
if nargin < 2 || isempty(speed), speed = 1; end
if nargin < 3 || isempty(cellSize), cellSize = 1; end
assert(isscalar(seconds) && isfinite(seconds) && seconds > 0, 'seconds must be positive.');
assert(isscalar(speed) && speed == round(speed) && speed >= 0, ...
       'speed must be a whole number of pixels per frame, 0 or more.');
assert(isscalar(cellSize) && cellSize == round(cellSize) && cellSize >= 1, 'cell must be a whole number of pixels, 1 or more.');
scroll = double(speed); grain = double(cellSize);

[w, rect, ifi] = PsychMetal('OpenWindow');
windowGuard = onCleanup(@() closeWindow(w)); %#ok<NASGU>
width = rect(3); height = rect(4);
side = min(width, height);
bx = floor((width - side) / 2); by = floor((height - side) / 2);
square = [bx, by, bx + side, by + side];
background = PsychMetal('MakeStimulus', 'noise', struct('seed', 13, 'grain', grain));
noise = PsychMetal('MakeStimulus', 'noise', struct('seed', 37, 'grain', grain));
grating = PsychMetal('MakeStimulus', 'grating', struct('frequency', .025, 'contrast', .9));
% The ring, uploaded once, with one texel for each pixel it covers.
cells = 2 * round(side / 4 / grain);            % half the square across, a whole number of cells
size_ = cells * grain;
[x, y] = meshgrid((0:cells - 1) + 0.5 - cells / 2);
r = sqrt(x .* x + y .* y) / (cells / 2);
mask = PsychMetal('MakeTexture', w, single(kron(r >= .55 & r <= 1, ones(grain))));
% A drifting background's rectangle is wider than the square by its drift for
% every frame of the run, and starts that far off to the left.
run = ceil(seconds / ifi) + 2;
around = ceil(width / grain) * grain;           % a ring that leaves one side comes in this far back
PsychMetal('SetMouse', w, width / 2, height / 2);
space = PsychMetal('KbName', 'space'); escape = PsychMetal('KbName', 'ESCAPE');
times = zeros(1, 0); why = 'time';
showNoise = true; switchWas = false;
% Where the ring's corner is, from the background's corner.
ringX = (width - size_) / 2 + scroll * run; ringY = (height - size_) / 2;
lastX = width / 2; lastY = height / 2; drawn = [];
vbl = PsychMetal('Flip', w); began = vbl;
while vbl - began < seconds && numel(times) < run
    [px, py, buttons] = PsychMetal('GetMouse', w);
    ringX = ringX + px - lastX;
    ringY = min(max(ringY + py - lastY, 0), height - size_);
    lastX = px; lastY = py;
    if ~scroll, ringX = min(max(ringX, 0), width - size_); end
    [~, ~, keys] = PsychMetal('KbCheck');
    if keys(escape), why = 'Escape'; break; end
    % The switch works when it is let go.
    switchNow = logical(buttons(1) || keys(space));
    if switchWas && ~switchNow, showNoise = ~showNoise; end
    switchWas = switchNow;
    edge = scroll * (numel(times) - run);       % the background's left edge on this frame
    left = bx + edge + grain * round((ringX - bx) / grain);
    top = by + grain * round((ringY - by) / grain);
    if scroll && isequal(drawn, [left top]), left = left - grain; end   % never still on the screen
    drawn = [left top];
    PsychMetal('FillRect', w, [0 0 0]);
    % Drift the carrier under a fixed square aperture; the ring is not clipped,
    % so it can cross into the black margins.
    PsychMetal('Clip', w, square);
    PsychMetal('DrawStimulus', w, background, [bx + edge, by, bx + edge + scroll * run + side, by + side]);
    PsychMetal('Clip', w, []);
    left = mod(left, around);
    if showNoise, carrier = noise; else, carrier = grating; end
    for x0 = [left, left - around, left + around]      % the ring, and it coming round
        if x0 < width && x0 + size_ > 0
            PsychMetal('DrawStimulus', w, carrier, [x0, top, x0 + size_, top + size_], mask, [], ...
                       struct('phase', -180 * (vbl - began), 'orientation', 30));
        end
    end
    vbl = PsychMetal('Flip', w);
    times(end + 1) = vbl; %#ok<AGROW>
end
info = PsychMetal('FlipInfo', w);
intervals = diff(times);
report = struct('frames', numel(times), 'meanHz', 1 / mean(intervals), ...
                'longestMs', 1000 * max([intervals 0]), 'droppedFrames', info.droppedFrames, 'endedBy', why);
fprintf('%d frames: %.2f per second; longest gap %.1f ms; %d never shown. Ended by %s.\n', ...
        report.frames, report.meanHz, report.longestMs, report.droppedFrames, why);
end

function closeWindow(w)
try, PsychMetal('Close', w); catch, end
end
