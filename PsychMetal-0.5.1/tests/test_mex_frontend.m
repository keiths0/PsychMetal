function test_mex_frontend(root, mexdir)
% End-to-end check of PsychMetal.m -> PsychMetalMex.cpp -> engine, using the
% scripted engine in tests/mock_engine.cpp (built by tests/test_frontends.py).
% Exercises every PsychMetal.m command family through the real MEX front end.
addpath(root); addpath(mexdir, '-begin');
clear PsychMetal PsychMetalCore
assert(strcmp(PsychMetal('Version'), '0.5.1'));
assert(strcmp(PsychMetalCore('Version'), '0.5.1'));

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
q = PsychMetalCore('Queue'); r = PsychMetalCore('WaitScheduled', q); assert(isequal(size(r), [1 7]) && r(5) == 1);
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
reject(@() PsychMetalCore('SetMode', 0, 640, 480) + 0, 'No display mode is 640 x 480 points on that display.', 'PsychMetal:Mode');
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
reject(@() openCore(0, 3, 0, 1, 1, [], 1, 1), ['Open needs screenIndex,drawableCount[,waitForConfirm[,displaySync[,captureDisplay[,refreshHz[,readback]]]]] ' ...
    'and returns width,height,ifi,pointWidth,pointHeight,sessionToken.']);
reject(@() PsychMetalCore('Now', 1), 'Now takes no arguments and one output.');
fprintf('PASS: PsychMetal.m through the real MEX front end: windows, all shapes, noise, textures (layout), presentation, grid, diagnostics, input, modes, readback, messages and identifiers.\n');
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
