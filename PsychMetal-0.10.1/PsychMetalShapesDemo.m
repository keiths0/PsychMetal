function report = PsychMetalShapesDemo(seconds)
% PsychMetalShapesDemo  Every kind of shape PsychMetal draws, in colour and in motion.
%
%   PsychMetalShapesDemo          % 20 seconds
%   PsychMetalShapesDemo(60)
%
% Python: python3 shapes_demo.py [seconds].
%
% Twelve panels, each labelled with the call that draws it: filled and framed
% rectangles and ovals, filled and framed polygons (turning, which costs nothing
% extra: polygons are drawn on the GPU), lines, dots, arcs and wedges, text, a
% Gabor patch, and translucent ovals blending. The panels stack three across on a
% screen taller than wide and four across otherwise.
%
% Escape or a click ends it.
%
% SPDX-License-Identifier: MIT
if nargin < 1 || isempty(seconds), seconds = 20; end
assert(isscalar(seconds) && isfinite(seconds) && seconds > 0, 'seconds must be positive.');
[w, rect] = PsychMetal('OpenWindow');
windowGuard = onCleanup(@() closeWindow(w)); %#ok<NASGU>
PsychMetal('HideCursor');
width = rect(3); height = rect(4);
if width >= height, across = 4; down = 3; else, across = 3; down = 4; end
cellW = width / across; cellH = height / down;
label = min(cellW, cellH) * .085;
radius = min(cellW, cellH - 2.2 * label) * .36;
names = {'FillRect', 'FrameRect', 'FillOval', 'FrameOval', 'FillPoly', 'FramePoly', ...
         'DrawLines', 'DrawDots', 'FillArc, FrameArc, DrawArc', 'DrawText', 'DrawGabor', 'alpha blending'};
% Text is measured once and made to fit: each label centred along the bottom of
% its panel, the text panel's words within the panel's width.
labels = zeros(12, 2);
for k = 1:12, [labels(k, 1), labels(k, 2)] = fitted(w, names{k}, label, cellW - 16); end
words = {'Metal', 'text', 'Aa'}; wordSizes = [.45 .3 .55] * radius;
wordLayout = zeros(3, 2);
for j = 1:3, [wordLayout(j, 1), wordLayout(j, 2)] = fitted(w, words{j}, wordSizes(j), 2 * radius); end
escape = PsychMetal('KbName', 'ESCAPE');
frames = 0;
began = PsychMetal('GetSecs'); vbl = began;
while vbl - began < seconds
    [~, ~, buttons] = PsychMetal('GetMouse', w);
    [~, ~, keys] = PsychMetal('KbCheck');
    if keys(escape) || any(buttons), break; end
    t = vbl - began;
    PsychMetal('FillRect', w, [24 26 34]);
    for k = 1:12
        left = mod(k - 1, across) * cellW; top = floor((k - 1) / across) * cellH;
        PsychMetal('FillRect', w, [34 37 48], [left + 4, top + 4, left + cellW - 4, top + cellH - 4]);
        drawPanel(w, k, t, left + cellW / 2, top + (cellH - 1.6 * label) / 2 + 4, radius, words, wordLayout);
        PsychMetal('DrawText', w, names{k}, left + (cellW - labels(k, 2)) / 2, top + cellH - 1.6 * label, ...
                   [200 205 215], labels(k, 1));
    end
    vbl = PsychMetal('Flip', w);
    frames = frames + 1;
end
d = PsychMetal('Diagnostic', w);
PsychMetal('ShowCursor');
fprintf('%d frames of twelve panels; %d shapes encoded in all.\n', frames, d.summary.shapesEncoded);
report = struct('frames', frames);
end

function drawPanel(w, k, t, cx, cy, r, words, wordLayout)
palette = [230 75 60; 240 170 50; 90 190 110; 70 150 230; 150 100 220; 230 100 170];
switch k
    case 1    % FillRect: three rectangles in one call
        rects = [cx - r, cy - .7 * r, cx + .2 * r, cy + .2 * r; ...
                 cx - .5 * r, cy - .3 * r, cx + .6 * r, cy + .6 * r; ...
                 cx - .1 * r, cy - r, cx + r, cy - .1 * r]';
        PsychMetal('FillRect', w, palette(1:3, :)', rects);
    case 2    % FrameRect: four pen widths
        pens = [1 2 4 6];
        for j = 0:3
            s = r * (1 - .22 * j);
            PsychMetal('FrameRect', w, palette(j + 2, :), [cx - s, cy - .75 * s, cx + s, cy + .75 * s], pens(j + 1));
        end
    case 3    % FillOval: three ellipses in one call
        aspect = [1 .45; .45 1; .7 .7];
        rects = [cx - aspect(:, 1) * r, cy - aspect(:, 2) * r, cx + aspect(:, 1) * r, cy + aspect(:, 2) * r]';
        PsychMetal('FillOval', w, palette([4 6 2], :)', rects);
    case 4    % FrameOval: breathing ellipses
        for j = 0:4
            a = r * (1 - .17 * j); b = r * (.6 - .1 * j) * (1 + .4 * sin(t + j));
            PsychMetal('FrameOval', w, palette(j + 1, :), [cx - a, cy - b, cx + a, cy + b], 3);
        end
    case 5    % FillPoly: a turning star
        PsychMetal('FillPoly', w, palette(2, :), turned(star(5, r, .45 * r), .6 * t, cx, cy));
    case 6    % FramePoly: a hexagon and a triangle turning opposite ways
        PsychMetal('FramePoly', w, palette(3, :), turned(regular(6, r), -.4 * t, cx, cy), 6);
        PsychMetal('FramePoly', w, palette(5, :), turned(regular(3, .5 * r), .8 * t, cx, cy), 3);
    case 7    % DrawLines: spokes through the centre, one colour each
        n = 12;
        angle = t * .3 + (0:n - 1) * pi / n;
        ends = [cos(angle); sin(angle)] * r;
        xy = reshape([ends; -ends], 2, []);
        PsychMetal('DrawLines', w, xy, 3, palette(mod(0:n - 1, 6) + 1, :)', [cx cy]);
    case 8    % DrawDots: a turning ring of round dots
        n = 18;
        angle = -.5 * t + (0:n - 1) * 2 * pi / n;
        xy = [cos(angle); sin(angle)] .* (r * (.75 + .2 * sin(3 * angle)));
        PsychMetal('DrawDots', w, xy, .22 * r, palette(mod(0:n - 1, 6) + 1, :)', [cx cy], 2);
    case 9    % arcs: a wedge that opens and closes, and arcs that turn (degrees, clockwise from the top)
        sweep = 180 * (1 + sin(t)) + 10;
        PsychMetal('FillArc', w, palette(1, :), [cx - .6 * r, cy - .6 * r, cx + .6 * r, cy + .6 * r], 0, sweep);
        turn = mod(t * 180 / pi, 360);
        PsychMetal('FrameArc', w, palette(4, :), [cx - .95 * r, cy - .95 * r, cx + .95 * r, cy + .95 * r], turn, 270, 5);
        PsychMetal('DrawArc', w, palette(3, :), [cx - .78 * r, cy - .78 * r, cx + .78 * r, cy + .78 * r], -turn, 200);
    case 10   % DrawText: words measured to fit, centred
        for j = 0:2
            PsychMetal('DrawText', w, words{j + 1}, cx - wordLayout(j + 1, 2) / 2, cy - r + j * .65 * r, ...
                       palette(mod(j * 2 + floor(t), 6) + 1, :), wordLayout(j + 1, 1));
        end
    case 11   % DrawGabor: drifting
        PsychMetal('DrawGabor', w, [], [cx - r, cy - r, cx + r, cy + r], .45, 4 / r, 30, 180 * t);
    case 12   % alpha blending: three translucent ovals
        centres = [0 -.35; -.3 .2; .3 .2];
        colours = [255 60 60 150; 60 255 60 150; 60 90 255 150]';
        rects = [cx + (centres(:, 1) - .6) * r, cy + (centres(:, 2) - .6) * r, ...
                 cx + (centres(:, 1) + .6) * r, cy + (centres(:, 2) + .6) * r]';
        PsychMetal('FillOval', w, colours, rects);
end
end

function [size_, width] = fitted(w, text, size_, room)
bounds = PsychMetal('TextBounds', w, text, size_);
width = bounds(3);
if width > room
    size_ = size_ * room / width;
    bounds = PsychMetal('TextBounds', w, text, size_);
    width = bounds(3);
end
end

function p = turned(points, angle, cx, cy)
c = cos(angle); s = sin(angle);
p = [cx + c * points(:, 1) - s * points(:, 2), cy + s * points(:, 1) + c * points(:, 2)];
end

function p = star(n, outer, inner)
angle = (0:2 * n - 1)' * pi / n - pi / 2;
radius = repmat([outer; inner], n, 1);
p = [radius .* cos(angle), radius .* sin(angle)];
end

function p = regular(sides, radius)
angle = (0:sides - 1)' * 2 * pi / sides - pi / 2;
p = radius * [cos(angle), sin(angle)];
end

function closeWindow(w)
try, PsychMetal('ShowCursor'); catch, end
try, PsychMetal('Close', w); catch, end
end
