function test_mex_frontend(root, mexdir)
% End-to-end check of PsychMetal.m -> PsychMetalMex.cpp -> engine, using the
% scripted engine in tests/mock_engine.cpp (built by tests/test_frontends.py).
% Exercises every PsychMetal.m command family through the real MEX front end.
addpath(root); addpath(mexdir, '-begin');
clear PsychMetal PsychMetalCore
assert(strcmp(PsychMetal('Version'), '0.7.1'));
assert(strcmp(PsychMetalCore('Version'), '0.7.1'));

% --- window, rects, timing basics
[w, rect, ifi] = PsychMetal('OpenWindow', 0, [0 0 0]);
assert(isequal(rect, [0 0 800 600]) && abs(ifi - 1/60) < 1e-12);
assert(isequal(PsychMetal('Rect', w), rect));
[ww, wh] = PsychMetal('WindowSize', w); assert(ww == 800 && wh == 600);
assert(abs(PsychMetal('GetFlipInterval', w) - ifi) < 1e-12);
t0 = PsychMetal('GetSecs'); t1 = PsychMetal('WaitSecs', 0.01); assert(t1 - t0 >= 0.01);
old = PsychMetal('ColorRange', w, 1); assert(old == 255); PsychMetal('ColorRange', w, 255);
PsychMetal('BackgroundColor', w, [10 20 30]);

% --- shapes of every kind
PsychMetal('FillRect', w, [255 0 0], [10 10 50 50]);
PsychMetal('FrameRect', w, 128, [10 10 50 50; 60 60 90 90]', 2);
PsychMetal('FillOval', w, [0 255 0 128], [100 100 150 150]);
PsychMetal('FrameOval', w, [], [100 100 150 150]);
PsychMetal('DrawDots', w, [10 20 30; 40 50 60], 4, 255, [0 0], 1);
PsychMetal('DrawLines', w, [0 100 0 100; 0 0 100 100], 2, 255);
PsychMetal('DrawGabor', w, 255, [200 200 300 300], 0.2, 0.05, 45, 90);
seed = PsychMetal('DrawNoise', w, [300 300 340 330], 7, 'normal', 'colour', [128 128 128], 40);
assert(seed == 7);

% --- noise values: shape, range, determinism, colour
n1 = PsychMetal('NoiseValues', w, [0 0 5 3], 11, 'uniform', 'mono', 128, 50);
n2 = PsychMetal('NoiseValues', w, [0 0 5 3], 11, 'uniform', 'mono', 128, 50);
assert(isequal(size(n1), [3 5]) && isequal(n1, n2) && all(n1(:) >= 0 & n1(:) <= 255));
n3 = PsychMetal('NoiseValues', w, [0 0 4 2], 11, 'normal', 'colour', [128 128 128], 50);
assert(isequal(size(n3), [2 4 3]));
nc = PsychMetalCore('NoiseValues', 5, 3, 11, 0, 0, [128 128 128]/255, 50/255);
assert(max(abs(nc(:) * 255 - n1(:))) < 1e-9);

% --- textures: column-major images reach the engine untransposed
img = zeros(2, 3, 3); img(2, 1, :) = [0.25 0.5 0.75]; img(1, 2, :) = [1 0 0.5];
t = PsychMetal('MakeTexture', w, img);
[~, d] = PsychMetalCore('Diagnostic');
assert(max(abs(d.lastShapeRect - [0.25 0.5 0.75 1])) < 1e-3, 'texel (row 2, col 1) was transposed');
assert(max(abs(d.lastShapeColor - [1 0 0.5 1])) < 1e-3, 'texel (row 1, col 2) was transposed');
PsychMetal('UpdateTexture', w, t, uint8(cat(3, [0 255; 51 0], zeros(2), zeros(2))));
[~, d] = PsychMetalCore('Diagnostic');
assert(abs(d.lastShapeRect(1) - 0.2) < 1e-3 && abs(d.lastShapeColor(1) - 1) < 1e-3);
g = PsychMetal('MakeTexture', w, single(rand(4, 5)));
PsychMetal('DrawTexture', w, t); PsychMetal('DrawTexture', w, g, [0 0 5 4], [0 0 50 40], 30, 0, 128, [255 255 255]);
PsychMetal('DrawTextures', w, [t g], [], [0 0 50 40; 60 0 110 40]', [0 30], [0 1], [255 128], [255 255 255; 255 0 0]');
PsychMetal('DrawTextures', w, g, [0 0 5 4], [0 0 50 40; 60 0 110 40]');
reject(@() PsychMetalCore('DrawTextures', [t 99], zeros(4, 2), zeros(4, 2), [0 0], ones(4, 2), [1 1]), 'Invalid or expired texture handle.');
reject(@() PsychMetalCore('DrawTextures', [t 1.5], zeros(4, 2), zeros(4, 2), [0 0], ones(4, 2), [1 1]), 'texture handle must be a nonnegative integer in range.');
reject(@() PsychMetalCore('DrawTextures', t, zeros(4, 1), zeros(4, 1), 0, 2 * ones(4, 1), 1), 'Invalid texture rectangle or tint.');
reject(@() PsychMetalCore('DrawTextures', t, zeros(3, 1), zeros(4, 1), 0, ones(4, 1), 1), 'DrawTextures expects handles, angles and filter modes as 1xN and srcRects, dstRects and tints as 4xN.');
reject(@() PsychMetalCore('DrawTextures', single(t), zeros(4, 1), zeros(4, 1), 0, ones(4, 1), 1), 'DrawTextures arguments must be real double arrays.');
reject(@() PsychMetalCore('DrawTextures', t, zeros(4, 1), zeros(4, 1), 0, ones(4, 1)), 'DrawTextures needs handles, srcRects, dstRects, angles, tints and filterModes.');
PsychMetal('CloseTexture', w, g);
reject(@() PsychMetal('DrawTexture', w, g));
reject(@() PsychMetalCore('MakeTexture', int16(ones(2))) + 0, 'Image must be dense real uint8, single, double, or logical HxWxC.');
reject(@() PsychMetalCore('MakeTexture', ones(2, 2, 2)) + 0, 'Image dimensions must be 1..16384 and have 1, 3, or 4 channels.');
reject(@() PsychMetalCore('MakeTexture', [1 NaN]) + 0, 'Texture pixels must be finite.');

% --- AddShapes argument checking
reject(@() PsychMetalCore('AddShapes', 0, 1, zeros(3, 1), ones(4, 1), zeros(4, 1)), 'AddShapes expects kind and param as 1xN and rect, color and extra as 4xN.');
reject(@() PsychMetalCore('AddShapes', single(0), 1, zeros(4, 1), ones(4, 1), zeros(4, 1)), 'AddShapes arguments must be real double arrays.');
reject(@() PsychMetalCore('AddShapes', 9, 1, zeros(4, 1), ones(4, 1), zeros(4, 1)), 'Invalid shape kind.');
reject(@() PsychMetalCore('AddShapes', 0, 1, zeros(4, 1), 2 * ones(4, 1), zeros(4, 1)), 'Shape arrays contain invalid values.');

% --- presentation
[vbl, onset, ret, missed, slipped] = PsychMetal('Flip', w);
assert(onset == vbl && ret >= vbl && missed == 0 && slipped == 0);
[vbl2, ~, ~, missed2] = PsychMetal('Flip', w, vbl + 2 * ifi);
assert(abs(vbl2 - (vbl + 2 * ifi)) < 1e-6 && missed2 < 0);   % PTB convention: negative = deadline met
tok = PsychMetal('PrepareFlip', w); assert(tok > 0);
[when, callMs] = PsychMetal('PresentNow', w); assert(when > 0 && callMs >= 0);
PsychMetal('SetDisplaySync', w, true);
g3 = PsychMetal('GridAnchor', w); assert(numel(g3) == 3 && abs(g3(1) - vbl2) < 1e-9);
nr = PsychMetal('NextRefresh', w, vbl2 + 0.1 * ifi); assert(abs(nr - (vbl2 + ifi)) < 1e-9);
np = PsychMetal('NextPhase', w, vbl2, 0.5); assert(abs(np - (vbl2 + 0.5 * ifi)) < 1e-9);
[woke, lead, deadline] = PsychMetal('WaitToDraw', w, vbl2 + 3 * ifi); assert(woke > 0 && lead > 0 && deadline < vbl2 + 3 * ifi);
PsychMetal('PrefetchDrawable', w, false);
r = PsychMetalCore('Flip'); assert(isequal(size(r), [1 8]) && r(2) == 0 && r(4) == ifi);
assert(isequal(PsychMetalCore('FlipStatus'), [0 0 0]));    % the display has not reported on the frame yet
PsychMetal('WaitSecs', ifi); assert(isequal(PsychMetalCore('FlipStatus'), [1 0 0]));
info = PsychMetal('FlipInfo', w); assert(isstruct(info) && info.confirmed && ~info.dropped && info.droppedFrames == 0 && info.flips > 0);
reject(@() PsychMetalCore('FlipStatus', 1) + 0, 'FlipStatus takes no arguments and returns one row.');
reject(@() PsychMetalCore('Flip', -1) + 0, 'Target must be nonnegative.');
reject(@() PsychMetalCore('Flip', NaN) + 0, 'target must be finite.');
reject(@() PsychMetalCore('Flip', 'x') + 0, 'target must be a real numeric scalar.');

% --- diagnostics: history columns and summary fields
D = PsychMetal('Diagnostic', w);
[h, s] = PsychMetalCore('Diagnostic');
assert(size(h, 2) == 16 && numel(fieldnames(s)) == 60);
assert(islogical(s.readbackEnabled) && ~s.readbackEnabled);
reject(@() PsychMetal('GetImage', w));
reject(@() PsychMetalCore('GetImage') + 0, 'GetImage requires a window opened with readback.');
assert(strcmp(class(s.hostBundleIdentifier), 'char') && islogical(s.displaySyncEnabled));
assert(isfield(D, 'summary') && isfield(D, 'startup'));

% --- input
[mx, my, buttons] = PsychMetal('GetMouse', w); assert(isscalar(mx) && isscalar(my) && islogical(buttons) && numel(buttons) == 3);
PsychMetal('SetMouse', w, 320, 240); [mx, my] = PsychMetal('GetMouse', w); assert(mx == 320 && my == 240);
reject(@() PsychMetal('SetMouse', w, 9999, 0), 'SetMouse position must be inside the window, in pixels.');
reject(@() PsychMetalCore('SetMouse', 1), 'SetMouse takes x and y and has no outputs.');
[down, secs, keyCode] = PsychMetal('KbCheck'); assert(~down && secs > 0 && islogical(keyCode) && numel(keyCode) == 256);
assert(PsychMetal('KbName', 'ESCAPE') == 41 && strcmp(PsychMetal('KbName', 41), 'ESCAPE'));
PsychMetal('HideCursor'); PsychMetal('ShowCursor');
PsychMetal('KbQueueCreate'); PsychMetal('KbQueueStart'); pause(0.02);
st = PsychMetal('KbQueueStatus'); assert(st.running && st.scans > 0);
[pressed, fp] = PsychMetal('KbQueueCheck'); assert(~pressed && numel(fp) == 256);
PsychMetal('KbQueueStop'); PsychMetal('KbQueueRelease');

% --- display modes (window closed)
PsychMetal('Close', w);
m = PsychMetal('Resolutions', 0); assert(numel(m) == 2 && m(1).width == 800);
PsychMetal('Resolution', 0, 1024, 768);
reject(@() PsychMetalCore('SetMode', 0, 640, 480), 'No display mode is 640 x 480 points on that display.', 'PsychMetal:Mode');
reject(@() openCore(3, 3), 'Screen index 3 is out of range; 1 display(s) are active.', 'PsychMetal:Screen');
reject(@() openCore(0, 1), 'Drawable count must be 2 or 3.');
reject(@() openCore(0, 4), 'maximum drawable count must be a nonnegative integer in range.');
reject(@() openCore(0.5, 3), 'screen index must be a non-negative integer, or -1 for the last display.');
reject(@() PsychMetalCore('Flip') + 0, 'PsychMetal is not open.');

% --- readback: the frame comes back as drawn, in MATLAB's layout
reject(@() PsychMetal('OpenWindow', struct('readback', 2)));
wr = PsychMetal('OpenWindow', struct('screen', 0, 'backgroundColor', [51 102 153], 'readback', true));
[~, s] = PsychMetalCore('Diagnostic'); assert(s.readbackEnabled);
shot = PsychMetal('GetImage', wr);
assert(isa(shot, 'uint8') && isequal(size(shot), [600 800 3]));
assert(all(all(shot(:, :, 1) == 51 & shot(:, :, 2) == 102 & shot(:, :, 3) == 153)), 'background, RGB order');
PsychMetal('FillRect', wr, [255 128 0], [10 20 110 70]);   % wider than tall, off the diagonal
PsychMetal('Flip', wr);
shot = PsychMetal('GetImage', wr);
box = shot(21:70, 11:110, :);
assert(all(all(box(:, :, 1) == 255 & box(:, :, 2) == 128 & box(:, :, 3) == 0)), 'the rectangle is where it was drawn: rows, then columns');
assert(all(shot(20, 11:110, 1) == 51) && all(shot(71, 11:110, 1) == 51) && all(shot(21:70, 10, 1) == 51) && all(shot(21:70, 111, 1) == 51), 'and stops at its edges');
part = PsychMetal('GetImage', wr, [5 15 120 80]);
assert(isequal(size(part), [65 115 3]) && isequal(part, shot(16:80, 6:120, :)), 'a rect returns that part of the frame');
assert(isequal(PsychMetal('GetImage', wr, [5; 15; 120; 80]), part) && isequal(PsychMetal('GetImage', wr, []), shot));
rgb = zeros(2, 3, 3, 'uint8'); rgb(1, 2, :) = [10 20 30]; rgb(2, 1, :) = [40 50 60];
tr = PsychMetal('MakeTexture', wr, rgb);
PsychMetal('DrawTexture', wr, tr, [], [200 100 203 102], 0, 0);
PsychMetal('Flip', wr);
assert(isequal(PsychMetal('GetImage', wr, [200 100 203 102]), rgb), 'a texture reads back untransposed, channels in order');
bad = 'GetImage rect must be [left top right bottom] in whole pixels inside the window.';
reject(@() PsychMetalCore('GetImage', [0 0 801 10]) + 0, bad);
reject(@() PsychMetalCore('GetImage', [0 0 10 601]) + 0, bad);
reject(@() PsychMetalCore('GetImage', [-1 0 10 10]) + 0, bad);
reject(@() PsychMetalCore('GetImage', [0.5 0 10 10]) + 0, bad);
reject(@() PsychMetalCore('GetImage', [10 10 10 20]) + 0, bad);
reject(@() PsychMetalCore('GetImage', [0 0 NaN 10]) + 0, bad);
reject(@() PsychMetalCore('GetImage', [0 0 10]) + 0, bad);
reject(@() PsychMetalCore('GetImage', single([0 0 10 10])) + 0, bad);
reject(@() PsychMetalCore('GetImage', [0 0 10 10], 1) + 0, 'GetImage accepts an optional rect and returns one image.');
PsychMetal('Close', wr);
wr = PsychMetal('OpenWindow', struct('screen', 0, 'refreshHz', 60, 'readback', true));
[~, s] = PsychMetalCore('Diagnostic'); assert(s.readbackEnabled && abs(PsychMetal('GetFlipInterval', wr) - 1/60) < 1e-12);
PsychMetal('Close', wr);
reject(@() openCore(0, 3, 0, 1, 1, [], 2), 'readback must be a nonnegative integer in range.');
reject(@() openCore(0, 3, 0, 1, 1, [], 1, 12), 'bit depth must be a nonnegative integer in range.');
reject(@() openCore(0, 3, 0, 1, 1, [], 1, 9), 'Bit depth must be 8 or 10.');
reject(@() openCore(0, 3, 0, 1, 1, [], 1, 8, 1, 1), ['Open needs screenIndex,drawableCount[,waitForConfirm[,displaySync[,captureDisplay[,refreshHz[,readback[,bitDepth[,displayLink]]]]]]] ' ...
    'and returns width,height,ifi,pointWidth,pointHeight,sessionToken.']);

% Both wrappers reach the same optional engine backend.
reject(@() PsychMetal('OpenWindow',struct('presentation','bad')));
wr=PsychMetal('OpenWindow',struct('presentation','displaylink'));
PsychMetal('FillRect',wr,127); PsychMetal('Flip',wr);
reject(@() PsychMetal('PrefetchDrawable',wr,true));
reject(@() PsychMetal('PrepareFlip',wr));
reject(@() PsychMetal('SetDisplaySync',wr,false));
PsychMetal('Close',wr);

% --- partial updates, blending, linearization, text and the link, in MATLAB's layout
wn = PsychMetal('OpenWindow', struct('screen', 0, 'backgroundColor', 0, 'readback', true));
img = zeros(4, 6, 3, 'uint8');
tn = PsychMetal('MakeTexture', wn, img);
patch = zeros(2, 3, 3, 'uint8'); patch(1, 2, :) = [10 20 30]; patch(2, 3, :) = [40 50 60];   % wider than tall
PsychMetal('UpdateTexture', wn, tn, patch, [2 1 5 3]);
img(2:3, 3:5, :) = patch;
PsychMetal('DrawTexture', wn, tn, [], [100 50 106 54], 0, 0); PsychMetal('Flip', wn);
assert(isequal(PsychMetal('GetImage', wn, [100 50 106 54]), img), 'a partial update lands at [left top], rows then columns');
reject(@() PsychMetalCore('UpdateTexture', tn, patch, 4, 1), 'A partial update must lie inside the texture, at whole pixels.');
reject(@() PsychMetalCore('UpdateTexture', tn, patch, 0.5, 1), 'A partial update must lie inside the texture, at whole pixels.');
reject(@() PsychMetalCore('UpdateTexture', tn, double(patch), 2, 1), ...
    'A partial update must have the texture''s type (uint8 or logical, or float) and channel count.');
reject(@() PsychMetalCore('UpdateTexture', tn, patch(:, :, 1), 2, 1), ...
    'A partial update must have the texture''s type (uint8 or logical, or float) and channel count.');
reject(@() PsychMetalCore('UpdateTexture', tn, patch, 2), 'UpdateTexture takes a texture handle and image, and optionally the left and top of a part.');
PsychMetal('FillRect', wn, [100 50 200], [10 10 20 20]);
PsychMetal('BlendFunction', wn, 'add'); PsychMetal('FillRect', wn, [20 30 100], [10 10 20 20]);
PsychMetal('BlendFunction', wn, 'alpha'); PsychMetal('FillRect', wn, [1 2 3], [30 10 40 20]);
PsychMetal('Flip', wn); shot = PsychMetal('GetImage', wn);
assert(isequal(reshape(shot(15, 15, :), 1, 3), uint8([120 80 255])) && isequal(reshape(shot(15, 35, :), 1, 3), uint8([1 2 3])), ...
    'the blend mode belongs to each draw as it is queued');
reject(@() PsychMetalCore('BlendMode', 3), 'blend mode must be a nonnegative integer in range.');
reject(@() PsychMetalCore('BlendMode'), 'BlendMode takes one mode and has no outputs.');
PsychMetal('Linearize', wn, [2 1 0.5]); PsychMetal('FillRect', wn, [64 64 64], [10 10 20 20]); PsychMetal('Flip', wn);
shot = PsychMetal('GetImage', wn, [10 10 20 20]); v = 64 / 255;
assert(isequal(reshape(shot(5, 5, :), 1, 3), uint8(round(255 * [v ^ 0.5, v, v ^ 2]))), 'a gamma per channel, in R G B order');
table = [linspace(0, 1, 5)', linspace(1, 0, 5)', [0 0 1 1 1]'];             % 5x3: rows are entries, columns channels
PsychMetal('Linearize', wn, table); PsychMetal('FillRect', wn, [51 51 51], [10 10 20 20]); PsychMetal('Flip', wn);
shot = PsychMetal('GetImage', wn, [10 10 20 20]);
assert(isequal(reshape(shot(5, 5, :), 1, 3), uint8([51 204 0])), 'a table is Nx3: one row per entry, one column per channel');
reject(@() PsychMetalCore('GammaTable', table'), 'The gamma table must be Nx3 real doubles, N from 2 to 4096.');
reject(@() PsychMetalCore('GammaTable', single(table)), 'The gamma table must be Nx3 real doubles, N from 2 to 4096.');
reject(@() PsychMetalCore('GammaTable', table * 2), 'Gamma table values run 0 to 1.');
reject(@() PsychMetalCore('Gamma', 0, 1, 1), 'Gamma exponents must be 0.05 to 20.');
reject(@() PsychMetalCore('Gamma', 1, 1), 'Gamma takes three exponents and has no outputs.');
PsychMetal('Linearize', wn, []);
[r, ascent] = PsychMetal('TextBounds', wn, 'abcd', 20);
assert(isequal(r, [0 0 50 26]) && ascent == 19, 'TextBounds through the MEX');
where = PsychMetal('DrawText', wn, '^_', 300, 200, [255 255 0], 50); PsychMetal('Flip', wn);
assert(isequal(where, [300 200 362 262]));
shot = PsychMetal('GetImage', wn, where); ink = shot(:, :, 1) == 255 & shot(:, :, 2) == 255 & shot(:, :, 3) == 0;
[rowsUp, colsUp] = find(ink(1:31, :)); [rowsDown, colsDown] = find(ink(32:end, :));
assert(~isempty(rowsUp) && ~isempty(rowsDown) && max(colsUp) < min(colsDown), 'text reads back upright, in its colour');
wide = PsychMetal('TextBounds', wn, native2unicode(uint8([195 188 228 189 160]), 'UTF-8'), 20);
assert(wide(3) == 26, 'two characters of UTF-8 are two characters wide');
reject(@() PsychMetalCore('DrawText', 'a', '', 20, 0, 0, [1 1 1]) + 0, 'Text colour must be four real doubles, RGBA.');
reject(@() PsychMetalCore('DrawText', 'a', '', 20, 0, 0, [2 1 1 1]) + 0, 'Text colour components run 0 to 1.');
reject(@() PsychMetalCore('DrawText', 'a', '', 2, 0, 0, [1 1 1 1]) + 0, 'Text size must be 4 to 2048 pixels.');
reject(@() PsychMetalCore('DrawText', '', '', 20, 0, 0, [1 1 1 1]) + 0, 'Text must not be empty.');
reject(@() PsychMetalCore('DrawText', 5, '', 20, 0, 0, [1 1 1 1]) + 0, 'Text must be a character row.');
reject(@() PsychMetalCore('TextBounds', 'a', 7, 20) + 0, 'Font must be a character row.');
reject(@() PsychMetalCore('TextBounds', 'a', '') + 0, 'TextBounds takes text, font and size, and returns one row.');
k = PsychMetal('LinkInfo', wn);
assert(isnan(k.lanes) && isnan(k.compressed) && abs(k.pixelGbps - 800 * 600 * 24 * 60 / 1e9) < 1e-9, 'an unidentified link is NaN');
reject(@() PsychMetalCore('LinkInfo', 1) + 0, 'LinkInfo takes no arguments and returns one row.');
PsychMetal('Close', wn);
setenv('PM_MOCK_LINK', '4,5.4');
said = evalc('wn = PsychMetal(''OpenWindow'', struct(''screen'', 0));');
assert(isempty(strfind(said, 'DSC')), '800x600 fits an HBR2 link: no banner');
k = PsychMetal('LinkInfo', wn); assert(k.lanes == 4 && abs(k.payloadGbps - 17.28) < 1e-9 && k.compressed == 0);
setenv('PM_MOCK_LINK', '');
PsychMetal('Close', wn);
setenv('PM_MOCK_LINK', '4,5.4'); setenv('PM_MOCK_DISPLAY', '6016x3384@60');
said = evalc('wn = PsychMetal(''OpenWindow'', struct(''screen'', 0));'); setenv('PM_MOCK_LINK', ''); setenv('PM_MOCK_DISPLAY', '');
assert(~isempty(strfind(said, 'needs 29.3 Gbit/s and the display link carries 17.3')), 'a 6K picture on an HBR2 link is reported as compressed');
PsychMetal('Close', wn);

% --- offscreen windows, polygons, the clip rect, queued frames and input events, in MATLAB's layout
wo = PsychMetal('OpenWindow', struct('screen', 0, 'backgroundColor', 0, 'readback', true));
PsychMetal('FillPoly', wo, [255 0 0], [100 100; 200 100; 100 200]);           % Nx2: a right triangle, apex down the left
PsychMetal('Flip', wo); shot = PsychMetal('GetImage', wo);
assert(isequal(reshape(shot(181, 111, :), 1, 3), uint8([255 0 0])) && isequal(reshape(shot(111, 181, :), 1, 3), uint8([255 0 0])) ...
    && isequal(reshape(shot(191, 191, :), 1, 3), uint8([0 0 0])), 'polygon points cross as [x y] pairs');
PsychMetal('FillPoly', wo, 255, [300 400 300; 100 100 150]);                   % 2xN: wide and flat
PsychMetal('Flip', wo); shot = PsychMetal('GetImage', wo);
assert(shot(111, 351, 1) == 255 && shot(141, 391, 1) == 0, '2xN points are x in the first row');
reject(@() PsychMetalCore('DrawPolygon', zeros(3, 3), [1 1 1 1], 0), 'A polygon is 3 to 4096 points, as Nx2 real doubles.');
reject(@() PsychMetalCore('DrawPolygon', zeros(2, 2), [1 1 1 1], 0), 'A polygon is 3 to 4096 points, as Nx2 real doubles.');
reject(@() PsychMetalCore('DrawPolygon', zeros(2, 3), [1 1 1], 0), 'Polygon colour must be four real doubles, RGBA.');
reject(@() PsychMetalCore('DrawPolygon', zeros(2, 3), [1 1 1 1], 2000), 'The polygon pen width must be 0 (filled) to 1024 pixels.');
[off, r] = PsychMetal('OpenOffscreenWindow', wo, [0 0 0 0], [0 0 40 20]);
assert(off ~= wo && isequal(r, [0 0 40 20]));
PsychMetal('FillRect', off, [0 255 0], [10 5 30 15]);                          % wider than tall
PsychMetal('FillRect', wo, [0 0 255], [100 100 200 200]);
PsychMetal('DrawTexture', wo, off, [], [120 140 160 160], 0, 0);
PsychMetal('Flip', wo); shot = PsychMetal('GetImage', wo);
assert(isequal(reshape(shot(151, 141, :), 1, 3), uint8([0 255 0])) && isequal(reshape(shot(143, 123, :), 1, 3), uint8([0 0 255])) ...
    && isequal(reshape(shot(147, 131, :), 1, 3), uint8([0 255 0])) && isequal(reshape(shot(157, 141, :), 1, 3), uint8([0 0 255])), ...
    'an offscreen window is drawn into in its own pixels and drawn as a texture, rows then columns');
reject(@() PsychMetal('DrawTexture', off, off), 'An offscreen window cannot be drawn into itself.');
PsychMetal('DrawTexture', wo, off, [], [120 140 160 160], 0, 0);
reject(@() PsychMetal('FillRect', off, 255), 'The window has draws of that offscreen window waiting; Flip before drawing into it again.');
PsychMetal('Flip', wo); PsychMetal('FillRect', off, [0 255 0], [10 5 30 15]); PsychMetal('FillRect', wo, 0, [0 0 1 1]);
reject(@() PsychMetalCore('SetTarget', 12345), 'Invalid or expired texture handle.');
reject(@() PsychMetalCore('OpenOffscreen', 0, 10, [0 0 0 1]) + 0, 'An offscreen window is 1 to 16384 whole pixels each way.');
reject(@() PsychMetalCore('OpenOffscreen', 10, 10, [0 0 0]) + 0, 'Offscreen window colour must be four real doubles, RGBA.');
reject(@() PsychMetalCore('OpenOffscreen', 10, 10, [0 0 0 2]) + 0, 'Offscreen window colour components run 0 to 1.');
PsychMetal('Close', off);
PsychMetal('Clip', wo, [110 120 150 160]); PsychMetal('FillRect', wo, [255 255 0]); PsychMetal('Clip', wo, []);
PsychMetal('Flip', wo); shot = PsychMetal('GetImage', wo);
assert(isequal(reshape(shot(121, 111, :), 1, 3), uint8([255 255 0])) && isequal(reshape(shot(160, 150, :), 1, 3), uint8([255 255 0])) ...
    && shot(120, 111, 1) == 0 && shot(121, 110, 1) == 0 && shot(161, 150, 1) == 0 && shot(160, 151, 1) == 0, 'a clip rect is [left top right bottom]');
reject(@() PsychMetalCore('Clip', [1 2 3]), 'The clip rect must be [left top right bottom] in whole pixels.');
reject(@() PsychMetalCore('Clip', [10 10 10 20]), 'The clip rect must be [left top right bottom] in whole pixels.');
ifi = PsychMetal('GetFlipInterval', wo); t0 = PsychMetal('GetSecs') + 0.1;
for k = 0:2, [token, pending, capacity] = PsychMetal('QueueFlip', wo, t0 + k * ifi); end
assert(pending == 3 && capacity == 64);
frames = PsychMetal('QueueResults', wo);
assert(isequal(size(frames), [3 4]) && all(frames(:, 3) == 0) && frames(3, 4) == token && all(frames(:, 2) >= frames(:, 1) - 1e-9) ...
    && max(abs(diff(frames(:, 2)) - ifi)) < 1e-9, 'queued frames: [requested presented status token] per row');
assert(isequal(size(PsychMetal('QueueResults', wo, false)), [0 4]) && PsychMetal('QueueCancel', wo) == 0);
reject(@() PsychMetalCore('QueueFlip', 0) + 0, 'A queued frame needs a presentation time.');
reject(@() PsychMetalCore('QueueFlip') + 0, 'QueueFlip takes a time and returns one row.');
reject(@() PsychMetalCore('QueueResults') + 0, 'QueueResults takes a wait flag and returns one matrix.');
[events, dropped] = PsychMetal('MouseEvents', wo); assert(isequal(size(events), [0 5]) && dropped == 0);
[events, dropped] = PsychMetal('TouchEvents', wo); assert(isequal(size(events), [0 5]) && dropped == 0);
reject(@() PsychMetalCore('TouchEvents') + 0, 'TouchEvents returns events and dropped count.');
PsychMetal('KbQueueCreate'); PsychMetal('KbQueueStart'); st = PsychMetal('KbQueueStatus'); PsychMetal('KbQueueRelease');
assert(st.eventTimestamps == 0 && st.eventStamped == 0 && st.pollStamped == 0 && st.maxEventDelayMs == 0);
PsychMetal('Close', wo);

% --- ten bits per channel
wt = PsychMetal('OpenWindow', struct('screen', 0, 'backgroundColor', [51 102 153], 'readback', true, 'bitDepth', 10));
PsychMetal('FillRect', wt, [255 0 0], [10 20 110 70]); PsychMetal('Flip', wt);
shot = PsychMetal('GetImage', wt);
assert(isa(shot, 'uint16') && isequal(size(shot), [600 800 3]) && isequal(reshape(shot(1, 1, :), 1, 3), uint16([205 409 614])) ...
    && isequal(reshape(shot(46, 61, :), 1, 3), uint16([1023 0 0])), 'a 10-bit frame is uint16 0..1023, RGB');
part = PsychMetal('GetImage', wt, [5 15 120 80]);
assert(isequal(part, shot(16:80, 6:120, :)));
k = PsychMetal('LinkInfo', wt); assert(abs(k.pixelGbps - 800 * 600 * 30 * 60 / 1e9) < 1e-9);
d = PsychMetal('Diagnostic', wt); assert(d.summary.bitDepth == 10 && strcmp(d.summary.blendFunction, 'alpha'));
PsychMetal('Close', wt);
reject(@() PsychMetalCore('Now', 1), 'Now takes no arguments and one output.');
fprintf('PASS: PsychMetal.m through the real MEX front end: windows, all shapes, noise, textures (layout), presentation, grid, diagnostics, input, modes, readback, partial updates, blending, linearization, text, the link report, offscreen windows, polygons, the clip rect, queued frames, input events, 10-bit frames, messages and identifiers.\n');
end

function reject(fn, message, id)
raised = false;
try
  fn();
catch e
  raised = true;
  if nargin >= 2
    got = regexprep(e.message, '^PsychMetalCore: ', '');
    assert(strcmp(got, message), 'Expected "%s", got "%s"', message, got);
  end
  if nargin >= 3
    assert(strcmp(e.identifier, id), 'Expected identifier %s, got %s', id, e.identifier);
  end
end
assert(raised, 'Invalid input was accepted');
end

function openCore(varargin)
PsychMetalCore('PrepareApp');
[a, b, c, d, e, f] = PsychMetalCore('Open', varargin{:}); %#ok<ASGLU>
end
