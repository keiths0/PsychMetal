function report = PsychMetalShapesDemo(seconds)
% PsychMetalShapesDemo  Every kind of shape PsychMetal draws, in colour and in motion.
%
%   PsychMetalShapesDemo          % 20 seconds
%   PsychMetalShapesDemo(60)
%
% Python: python3 shapes_demo.py [seconds].
%
% Twelve panels, each labelled with the call that draws it: filled and framed
% rectangles and ovals, filled and framed polygons, lines, dots, arcs and wedges,
% text, a Gabor patch, and translucent ovals blending. Nearly everything turns:
% by each command's trailing angle (each rect, oval, arc and Gabor about its own
% centre, the lines and dots about their center, text about its top left), or by
% Translate, Rotate and Scale, which move, turn and scale whatever is drawn
% between PushMatrix and PopMatrix as one, as the polygons, the blending ovals
% and two of the words are. Turning costs nothing extra: the GPU's vertex shaders
% apply it. The panels stack three across on a screen taller than wide and four
% across otherwise.
%
% Escape or a click ends it.
%
% SPDX-License-Identifier: MIT
if nargin < 1 || isempty(seconds), seconds = 20; end
assert(isscalar(seconds) && isfinite(seconds) && seconds > 0, 'seconds must be positive.');
[w, rect] = PsychMetal('OpenWindow');
windowGuard = onCleanup(@() closeWindow(w)); %#ok<NASGU>
PsychMetal('HideCursor');
% The panels fill the safe area: on a phone, clear of the camera housing, the
% rounded corners and the home indicator; on a Mac, the whole window.
area = safeArea(w, rect);
width = area(3) - area(1); height = area(4) - area(2);
if width >= height, across = 4; down = 3; else, across = 3; down = 4; end
cellW = width / across; cellH = height / down;
label = min(cellW, cellH) * .085;
radius = min(cellW, cellH - 2.2 * label) * .36;
names = {'FillRect', 'FrameRect', 'FillOval', 'FrameOval', 'FillPoly, Rotate', 'FramePoly, Rotate', ...
         'DrawLines', 'DrawDots', 'FillArc, FrameArc, DrawArc', 'DrawText, Rotate, Scale', 'DrawGabor', ...
         'alpha blending, Rotate'};
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
        left = area(1) + mod(k - 1, across) * cellW; top = area(2) + floor((k - 1) / across) * cellH;
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
% Angles are degrees, clockwise; most things turn.
palette = [230 75 60; 240 170 50; 90 190 110; 70 150 230; 150 100 220; 230 100 170];
spin = t * 180 / pi;                          % one radian a second
switch k
    case 1    % FillRect: three rectangles in one call, each turning about its own centre
        rects = [cx - r, cy - .7 * r, cx + .2 * r, cy + .2 * r; ...
                 cx - .5 * r, cy - .3 * r, cx + .6 * r, cy + .6 * r; ...
                 cx - .1 * r, cy - r, cx + r, cy - .1 * r]';
        PsychMetal('FillRect', w, palette(1:3, :)', rects, [], [.5 -.8 0] * spin);
    case 2    % FrameRect: four pen widths, turning alternate ways
        pens = [1 2 4 6];
        for j = 0:3
            s = r * (1 - .22 * j);
            PsychMetal('FrameRect', w, palette(j + 2, :), [cx - s, cy - .55 * s, cx + s, cy + .55 * s], pens(j + 1), ...
                       (-1) ^ j * .3 * (j + 1) * spin);
        end
    case 3    % FillOval: three ellipses in one call
        aspect = [1 .45; .45 1; .7 .7];
        rects = [cx - aspect(:, 1) * r, cy - aspect(:, 2) * r, cx + aspect(:, 1) * r, cy + aspect(:, 2) * r]';
        PsychMetal('FillOval', w, palette([4 6 2], :)', rects, [], [.6 .6 0] * spin);
    case 4    % FrameOval: breathing ellipses, rocking
        for j = 0:4
            a = r * (1 - .17 * j); b = r * (.6 - .1 * j) * (1 + .4 * sin(t + j));
            PsychMetal('FrameOval', w, palette(j + 1, :), [cx - a, cy - b, cx + a, cy + b], 3, [], [], 15 * j * sin(.5 * t));
        end
    case 5    % FillPoly: a star's own points, about [0 0], turned by the transform
        aboutPush(w, cx, cy, .6 * spin, 1);
        PsychMetal('FillPoly', w, palette(2, :), star(5, r, .45 * r));
        PsychMetal('PopMatrix', w);
    case 6    % FramePoly: a hexagon and a triangle turning opposite ways
        aboutPush(w, cx, cy, -.4 * spin, 1);
        PsychMetal('FramePoly', w, palette(3, :), regular(6, r), 6);
        PsychMetal('PopMatrix', w);
        aboutPush(w, cx, cy, .8 * spin, 1);
        PsychMetal('FramePoly', w, palette(5, :), regular(3, .5 * r), 3);
        PsychMetal('PopMatrix', w);
    case 7    % DrawLines: spokes through the centre, one colour each, turned about center
        n = 12;
        angle = (0:n - 1) * pi / n;
        ends = [cos(angle); sin(angle)] * r;
        xy = reshape([ends; -ends], 2, []);
        PsychMetal('DrawLines', w, xy, 3, palette(mod(0:n - 1, 6) + 1, :)', [cx cy], [], [], .3 * spin);
    case 8    % DrawDots: round dots running along a three-lobed contour, and the contour turning
        n = 18;
        angle = -.5 * t + (0:n - 1) * 2 * pi / n;
        xy = [cos(angle); sin(angle)] .* (r * (.75 + .2 * sin(3 * angle)));
        PsychMetal('DrawDots', w, xy, .22 * r, palette(mod(0:n - 1, 6) + 1, :)', [cx cy], 2, [], .2 * spin);
    case 9    % arcs: a wedge that opens and closes, and arcs that turn (degrees, clockwise from the top)
        sweep = 180 * (1 + sin(t)) + 10;
        PsychMetal('FillArc', w, palette(1, :), [cx - .6 * r, cy - .6 * r, cx + .6 * r, cy + .6 * r], 0, sweep);
        PsychMetal('FrameArc', w, palette(4, :), [cx - .95 * r, cy - .95 * r, cx + .95 * r, cy + .95 * r], 0, 270, 5, [], [], spin);
        PsychMetal('DrawArc', w, palette(3, :), [cx - .78 * r, cy - .78 * r, cx + .78 * r, cy + .78 * r], 0, 200, -spin);
    case 10   % DrawText: spinning about its middle, swinging about its top left, growing and shrinking
        aboutPush(w, cx, cy - .45 * r, .5 * spin, 1);
        PsychMetal('DrawText', w, words{1}, -wordLayout(1, 2) / 2, -wordLayout(1, 1) / 2, ...
                   palette(mod(floor(t), 6) + 1, :), wordLayout(1, 1));
        PsychMetal('PopMatrix', w);
        PsychMetal('DrawText', w, words{2}, cx - wordLayout(2, 2) / 2, cy + .05 * r, ...
                   palette(mod(floor(t) + 2, 6) + 1, :), wordLayout(2, 1), [], [], 25 * sin(2 * t));
        aboutPush(w, cx, cy + .65 * r, 0, .75 + .35 * sin(1.5 * t));
        PsychMetal('DrawText', w, words{3}, -wordLayout(3, 2) / 2, -wordLayout(3, 1) / 2, ...
                   palette(mod(floor(t) + 4, 6) + 1, :), wordLayout(3, 1));
        PsychMetal('PopMatrix', w);
    case 11   % DrawGabor: drifting, and the patch turning
        g = 1.25 * r;   % a larger patch and a narrower envelope (sigma .3 of its half-size): it fades out
                        % before the patch's edge, with no square showing
        PsychMetal('DrawGabor', w, [], [cx - g, cy - g, cx + g, cy + g], .3, 4 / r, 30, 180 * t, .4 * spin);
    case 12   % alpha blending: three translucent ovals, turned as one group
        centres = [0 -.35; -.3 .2; .3 .2];
        colours = [255 60 60 150; 60 255 60 150; 60 90 255 150]';
        rects = [(centres(:, 1) - .6) * r, (centres(:, 2) - .6) * r, ...
                 (centres(:, 1) + .6) * r, (centres(:, 2) + .6) * r]';
        aboutPush(w, cx, cy, -.5 * spin, 1);
        PsychMetal('FillOval', w, colours, rects);
        PsychMetal('PopMatrix', w);
end
end

function aboutPush(w, cx, cy, degrees, scale)
% Saves the transform; what is drawn next, about [0 0], is scaled, turned and
% moved to (cx, cy). PopMatrix restores it.
PsychMetal('PushMatrix', w);
PsychMetal('Translate', w, cx, cy);
PsychMetal('Rotate', w, degrees);
PsychMetal('Scale', w, scale, scale);
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

function p = star(n, outer, inner)
angle = (0:2 * n - 1)' * pi / n - pi / 2;
radius = repmat([outer; inner], n, 1);
p = [radius .* cos(angle), radius .* sin(angle)];
end

function p = regular(sides, radius)
angle = (0:sides - 1)' * 2 * pi / sides - pi / 2;
p = radius * [cos(angle), sin(angle)];
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

function closeWindow(w)
try, PsychMetal('ShowCursor'); catch, end
try, PsychMetal('Close', w); catch, end
end
