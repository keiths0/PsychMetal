function report = PsychMetalReadbackTest(verbose)
% PsychMetalReadbackTest  Check what the GPU renders, pixel for pixel.
%
%   report = PsychMetalReadbackTest        % run everything
%   report = PsychMetalReadbackTest(true)  % print each check as it passes
%
% The window is opened with readback, so every frame's drawable is copied
% before it is presented and GetImage returns those pixels. Each check draws
% something whose result is known exactly, flips, reads the frame and compares:
%
%   * the background, an opaque rectangle and its edges;
%   * a uint8 texture at native size, which must come back bit for bit;
%   * a float texture, within one grey level;
%   * a masked texture over another: the overlay inside the mask and the
%     original outside it, both exact;
%   * a texture drawn with global alpha over another, against
%     alpha * top + (1 - alpha) * bottom;
%   * a texture updated on every frame, which must show that frame's image;
%   * part of a texture replaced in place, the rest unchanged;
%   * additive blending, which must sum and saturate;
%   * linearization by a gamma and by a table, including that a half-alpha
%     white over black comes out as half the light and not half the value;
%   * a line of text: inside its rectangle, the right way up, in its colour;
%   * an offscreen window: what is drawn into it comes back exactly when it is
%     drawn to the window, draws into it accumulate, and its transparent part
%     shows what is under it;
%   * a partly transparent offscreen window: overlapping, soft-edged draws made
%     through it match the same draws made on the window, half-alpha white is
%     half white, and global alpha, a second offscreen window, a copied colour
%     and the colour it was opened with all keep its transparency;
%   * a clip rect, which must confine a draw to the pixel;
%   * a filled polygon and a polygon's outline;
%   * frames queued ahead: each is the frame that was drawn for it, and all
%     are shown;
%   * a second window at ten bits per channel, read back as 0..1023, with
%     levels that fall between the 8-bit ones.
%
% What this establishes is the rendered frame: the pixels the GPU handed to the
% display. It says nothing about what the compositor or the panel did with them.
%
% About six seconds. Every check is independent; a failure is recorded and the
% run continues.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(verbose), verbose = false; end

w = [];
results = struct('name', {}, 'ok', {}, 'detail', {});
background = [51 102 153];
textureH = 48; textureW = 64;

  function record(name, ok, detail)
   results(end+1) = struct('name', name, 'ok', logical(ok), 'detail', detail);
   if verbose
    if ok && isempty(detail), fprintf('  ok    %s\n', name);
    elseif ok, fprintf('  ok    %s (%s)\n', name, detail);
    else, fprintf('  FAIL  %s: %s\n', name, detail); end
   end
  end

try
 fprintf('\nPsychMetal readback test. About six seconds.\n\n');
 [w, rect, ifi] = PsychMetal('OpenWindow', struct('backgroundColor', background, 'readback', true));
 PsychMetal('HideCursor');
 width = rect(3); height = rect(4);
 dst = [16 24 16 + textureW 24 + textureH];      % native size, whole pixels
 rows = dst(2) + 1 : dst(4); cols = dst(1) + 1 : dst(3);
 bottom = pattern(73, 151, 199, 7, textureH, textureW);
 top = pattern(31, 17, 101, 3, textureH, textureW);

 % ---- the frame itself ------------------------------------------------------
 PsychMetal('Flip', w);
 shot = PsychMetal('GetImage', w);
 record('GetImage returns [height width 3] uint8', ...
     isequal(size(shot), [height width 3]) && isa(shot, 'uint8'), ...
     sprintf('%s %s', mat2str(size(shot)), class(shot)));
 record('an empty frame is the background everywhere', differing(shot, background) == 0, ...
     sprintf('%d pixels differ', differing(shot, background)));
 d = PsychMetal('Diagnostic', w);
 record('Diagnostic reports readback', islogical(d.summary.readbackEnabled) && d.summary.readbackEnabled, '');

 % ---- an opaque rectangle, and where it stops ---------------------------------
 colour = [255 128 0];
 PsychMetal('FillRect', w, colour, [10 20 110 70]);
 PsychMetal('Flip', w);
 shot = PsychMetal('GetImage', w);
 record('an opaque rectangle has exactly its colour', differing(shot(21:70, 11:110, :), colour) == 0, ...
     sprintf('centre is %s', mat2str(double(reshape(shot(46, 61, :), 1, 3)))));
 outside = shot;
 outside(21:70, 11:110, :) = repmat(reshape(uint8(background), 1, 1, 3), 50, 100);
 record('pixels outside the rectangle are untouched', differing(outside, background) == 0, ...
     sprintf('%d pixels differ', differing(outside, background)));
 part = PsychMetal('GetImage', w, [5 15 120 80]);
 record('GetImage with a rect is that part of the frame', ...
     isequal(size(part), [65 115 3]) && isequal(part, shot(16:80, 6:120, :)), mat2str(size(part)));

 % ---- textures at native size ---------------------------------------------------
 tBottom = PsychMetal('MakeTexture', w, bottom);
 tTop = PsychMetal('MakeTexture', w, top);
 PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
 PsychMetal('Flip', w);
 worst = errors(PsychMetal('GetImage', w, dst), double(bottom));
 record('a uint8 texture comes back bit for bit', worst == 0, sprintf('largest error %g of 255', worst));

 level = single(pattern(11, 29, 53, 5, textureH, textureW)) / 255 * 0.999 + 0.0004;   % not on the 8-bit grid
 tFloat = PsychMetal('MakeTexture', w, level);
 PsychMetal('DrawTexture', w, tFloat, [], dst, 0, 0);
 PsychMetal('Flip', w);
 [worst, meanError] = errors(PsychMetal('GetImage', w, dst), double(level) * 255);
 record('a float texture is within one grey level', worst <= 1, ...
     sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));

 % ---- a masked texture over another -----------------------------------------------
 [yy, xx] = ndgrid(0:textureH - 1, 0:textureW - 1);
 mask = (yy - textureH / 2) .^ 2 + (xx - textureW / 2) .^ 2 < 20 ^ 2;
 mask3 = repmat(mask, [1 1 3]);
 tMasked = PsychMetal('MakeTexture', w, cat(3, top, uint8(mask) * 255));
 PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
 PsychMetal('DrawTexture', w, tMasked, [], dst, 0, 0);
 PsychMetal('Flip', w);
 got = PsychMetal('GetImage', w, dst);
 record('inside the mask is the overlay, exactly', isequal(got(mask3), top(mask3)), ...
     sprintf('largest error %g of 255', errors(got(mask3), double(top(mask3)))));
 record('outside the mask is the texture underneath, exactly', isequal(got(~mask3), bottom(~mask3)), ...
     sprintf('largest error %g of 255', errors(got(~mask3), double(bottom(~mask3)))));

 % ---- global alpha blends over what is underneath ------------------------------------
 for alpha = [64 128 191]
  PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
  PsychMetal('DrawTexture', w, tTop, [], dst, 0, 0, alpha);
  PsychMetal('Flip', w);
  a = alpha / 255;
  [worst, meanError] = errors(PsychMetal('GetImage', w, dst), a * double(top) + (1 - a) * double(bottom));
  record(sprintf('global alpha %d/255 is alpha * top + (1 - alpha) * bottom', alpha), worst <= 1, ...
      sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));
 end

 % ---- a texture updated on every frame ---------------------------------------------------
 tLive = PsychMetal('MakeTexture', w, zeros(textureH, textureW, 3, 'uint8'));
 wrong = [];
 for frame = 1:12
  PsychMetal('UpdateTexture', w, tLive, repmat(uint8(frame * 20), [textureH textureW 3]));
  PsychMetal('DrawTexture', w, tLive, [], dst, 0, 0);
  PsychMetal('Flip', w);
  got = PsychMetal('GetImage', w, dst);
  if ~all(got(:) == frame * 20), wrong(end+1) = frame; end %#ok<AGROW>
 end
 if isempty(wrong), detail = '12 frames';
 else, detail = sprintf('frames %s showed another image', mat2str(wrong)); end
 record('a texture updated every frame shows that frame''s image', isempty(wrong), detail);
 surround = PsychMetal('GetImage', w);
 surround(rows, cols, :) = repmat(reshape(uint8(background), 1, 1, 3), textureH, textureW);
 record('outside the texture, the frame is still the background', differing(surround, background) == 0, ...
     sprintf('%d pixels differ', differing(surround, background)));

 % ---- part of a texture replaced in place -------------------------------------------------
 expected = repmat(uint8(240), [textureH textureW 3]);        % as the loop left it
 expected(5:16, 9:24, :) = top(5:16, 9:24, :);
 PsychMetal('UpdateTexture', w, tLive, top(5:16, 9:24, :), [8 4 24 16]);
 PsychMetal('DrawTexture', w, tLive, [], dst, 0, 0);
 PsychMetal('Flip', w);
 worst = errors(PsychMetal('GetImage', w, dst), double(expected));
 record('a partial update changes its rect and nothing else', worst == 0, sprintf('largest error %g of 255', worst));

 % ---- additive blending ----------------------------------------------------------------------
 PsychMetal('FillRect', w, [100 50 200], dst);
 record('BlendFunction returns the old mode', strcmp(PsychMetal('BlendFunction', w, 'add'), 'alpha'), '');
 PsychMetal('FillRect', w, [20 30 100], dst);
 PsychMetal('Flip', w);
 got = PsychMetal('GetImage', w, dst);
 record('additive blending sums and saturates', differing(got, [120 80 255]) == 0, ...
     sprintf('centre is %s', mat2str(double(reshape(got(25, 33, :), 1, 3)))));
 PsychMetal('BlendFunction', w, 'alpha');
 PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
 PsychMetal('BlendFunction', w, 'add');
 PsychMetal('DrawTexture', w, tTop, [], dst, 0, 0, 128);
 PsychMetal('BlendFunction', w, 'alpha');
 PsychMetal('Flip', w);
 [worst, meanError] = errors(PsychMetal('GetImage', w, dst), min(double(bottom) + double(top) * (128 / 255), 255));
 record('an added texture at alpha 128/255 is bottom + alpha * top', worst <= 1, ...
     sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));

 % ---- linearization ----------------------------------------------------------------------------
 gamma = 2.2;
 PsychMetal('Linearize', w, gamma);
 PsychMetal('DrawTexture', w, tFloat, [], dst, 0, 0);
 PsychMetal('FillRect', w, 0, [200 24 232 56]);
 PsychMetal('FillRect', w, [255 255 255 128], [200 24 232 56]);
 PsychMetal('Flip', w);
 shot = PsychMetal('GetImage', w);
 [worst, meanError] = errors(shot(rows, cols, :), double(level) .^ (1 / gamma) * 255);
 record('with a gamma, a linear value v is written as v ^ (1 / gamma)', worst <= 1, ...
     sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));
 corner = double(reshape(shot(3, 3, :), 1, 3));
 record('and so is the background', max(abs(corner - (background / 255) .^ (1 / gamma) * 255)) <= 1, mat2str(corner));
 half = (128 / 255) ^ (1 / gamma) * 255;
 worst = errors(shot(25:56, 201:232, :), repmat(half, 32 * 32 * 3, 1));
 record('half-alpha white over black is half the light', worst <= 1, ...
     sprintf('%s, expected %.1f; unlinearized it would be 128', mat2str(double(reshape(shot(41, 217, :), 1, 3))), half));
 steps = linspace(0, 1, 256)';
 table = [sqrt(steps), steps, steps .^ 2];
 PsychMetal('Linearize', w, table);
 PsychMetal('DrawTexture', w, tFloat, [], dst, 0, 0);
 PsychMetal('Flip', w);
 want = zeros(textureH, textureW, 3);
 for c = 1:3, want(:, :, c) = interp1(steps, table(:, c), double(level(:, :, c))) * 255; end
 [worst, meanError] = errors(PsychMetal('GetImage', w, dst), want);
 record('with a table, each channel follows its own column', worst <= 1, ...
     sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));
 PsychMetal('Linearize', w, []);
 PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
 PsychMetal('Flip', w);
 shot = PsychMetal('GetImage', w);
 record('with linearization off again, frames are exact again', ...
     isequal(shot(rows, cols, :), bottom) && isequal(double(reshape(shot(3, 3, :), 1, 3)), background), '');

 % ---- text ------------------------------------------------------------------------------------------
 textSize = 64;
 [bounds, ascent] = PsychMetal('TextBounds', w, '^_', textSize);
 where = PsychMetal('DrawText', w, '^_', 200, 100, [255 255 0], textSize);
 PsychMetal('Flip', w);
 shot = PsychMetal('GetImage', w);
 record('DrawText returns the rect that TextBounds measures', ...
     isequal(where, [200 100 200 + bounds(3) 100 + bounds(4)]) && ascent > 0 && ascent < bounds(4), ...
     sprintf('%s, ascent %g', mat2str(where), ascent));
 box = shot(where(2) + 1 : where(4), where(1) + 1 : where(3), :);
 ink = box(:, :, 1) ~= background(1) | box(:, :, 2) ~= background(2) | box(:, :, 3) ~= background(3);
 outside = shot;
 outside(where(2) + 1 : where(4), where(1) + 1 : where(3), :) = ...
     repmat(reshape(uint8(background), 1, 1, 3), size(ink, 1), size(ink, 2));
 record('text marks pixels inside its rect and none outside', any(ink(:)) && differing(outside, background) == 0, ...
     sprintf('%d inside, %d outside', sum(ink(:)), differing(outside, background)));
 mid = floor(size(ink, 1) / 2);
 [~, upper] = find(ink(1:mid, :)); [~, lower] = find(ink(mid + 1 : end, :));
 record('"^_" has its caret above and to the left of its underscore', ...
     ~isempty(upper) && ~isempty(lower) && mean(upper) < mean(lower), ...
     sprintf('%d pixels above the middle, %d below', numel(upper), numel(lower)));
 record('fully covered text pixels are exactly the text colour', differing(box, [255 255 0]) < size(ink, 1) * size(ink, 2), '');

 % ---- an offscreen window ---------------------------------------------------------------------------
 off = PsychMetal('OpenOffscreenWindow', w, [0 0 0 0], [0 0 textureW textureH]);
 PsychMetal('DrawTexture', off, tBottom, [], [0 0 textureW textureH], 0, 0);
 PsychMetal('DrawTexture', w, off, [], dst, 0, 0);
 PsychMetal('Flip', w);
 worst = errors(PsychMetal('GetImage', w, dst), double(bottom));
 record('a texture drawn into an offscreen window comes back exactly', worst == 0, sprintf('largest error %g of 255', worst));
 patch = uint8([255 128 0]);
 PsychMetal('FillRect', off, patch, [8 4 24 16]);
 expected = bottom;
 expected(5:16, 9:24, :) = repmat(reshape(patch, 1, 1, 3), 12, 16);
 PsychMetal('DrawTexture', w, off, [], dst, 0, 0);
 PsychMetal('Flip', w);
 worst = errors(PsychMetal('GetImage', w, dst), double(expected));
 record('draws into an offscreen window accumulate', worst == 0, sprintf('largest error %g of 255', worst));
 PsychMetal('BlendFunction', off, 'copy');
 PsychMetal('FillRect', off, [0 0 0 0]);
 PsychMetal('BlendFunction', off, 'alpha');
 PsychMetal('FillRect', off, patch, [8 4 24 16]);
 PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
 PsychMetal('DrawTexture', w, off, [], dst, 0, 0);
 PsychMetal('Flip', w);
 worst = errors(PsychMetal('GetImage', w, dst), double(expected));
 record('a transparent offscreen window shows what is under it', worst == 0, sprintf('largest error %g of 255', worst));

 % ---- a partly transparent offscreen window ----------------------------------------------------------
 % What is drawn through an offscreen window must be what the same draws give
 % when made on the window itself, soft edges and overlaps included. The window
 % rounds to 8 bits after every draw and the offscreen window only when it is
 % drawn, so where layers overlap the two may differ by rounding.
 whole = [0 0 textureW textureH];
 PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
 layers(w, dst(1), dst(2));
 PsychMetal('Flip', w);
 direct = PsychMetal('GetImage', w, dst);
 clearTo(off, [0 0 0 0]);
 layers(off, 0, 0);
 through = overBottom(w, tBottom, off, dst, []);
 [worst, meanError] = errors(through, double(direct));
 record('partly transparent and soft-edged draws through an offscreen window match the same draws made directly', ...
     worst <= 2, sprintf('largest difference %g, mean %+.3f of 255', worst, meanError));
 a = 128 / 255;
 under = double(bottom);
 [worst, meanError] = errors(through(7:14, 7:22, :), a * 255 + (1 - a) * under(7:14, 7:22, :));   % under the white rectangle alone
 record('half-alpha white through an offscreen window is half white over what is under it', worst <= 1, ...
     sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));

 clearTo(off, [0 0 0 0]);
 PsychMetal('FillRect', off, [255 255 255 128], [0 0 32 textureH]);
 expected = under;
 expected(:, 1:32, :) = a * a * 255 + (1 - a * a) * under(:, 1:32, :);
 [worst, meanError] = errors(overBottom(w, tBottom, off, dst, 128), expected);
 record('an offscreen window drawn with global alpha is everything in it at that alpha', worst <= 1, ...
     sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));

 off2 = PsychMetal('OpenOffscreenWindow', w, [0 0 0 0], whole);
 PsychMetal('DrawTexture', off2, off, [], whole, 0, 0);
 expected(:, 1:32, :) = a * 255 + (1 - a) * under(:, 1:32, :);
 [worst, meanError] = errors(overBottom(w, tBottom, off2, dst, []), expected);
 record('an offscreen window drawn into another keeps its transparency', worst <= 1, ...
     sprintf('largest error %.2f, mean error %+.3f of 255', worst, meanError));
 PsychMetal('Close', off2);

 clearTo(off, [255 128 0 128]);
 tinted = PsychMetal('OpenOffscreenWindow', w, [255 128 0 128], whole);
 expected = a * repmat(reshape(double(patch), 1, 1, 3), textureH, textureW) + (1 - a) * under;
 worst = max(errors(overBottom(w, tBottom, off, dst, []), expected), errors(overBottom(w, tBottom, tinted, dst, []), expected));
 record('a partly transparent colour copied into an offscreen window, or given when it is opened, is that colour at its alpha', ...
     worst <= 1, sprintf('largest error %.2f of 255', worst));
 PsychMetal('Close', tinted);
 PsychMetal('Close', off);

 % ---- the clip rect ----------------------------------------------------------------------------------
 inner = [dst(1) + 10, dst(2) + 6, dst(1) + 40, dst(2) + 30];
 PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
 PsychMetal('Clip', w, inner);
 PsychMetal('DrawTexture', w, tTop, [], dst, 0, 0);
 PsychMetal('FillRect', w, [255 0 255], [0 0 8 8]);              % wholly outside the clip
 PsychMetal('Clip', w, []);
 PsychMetal('Flip', w);
 expected = bottom;
 expected(7:30, 11:40, :) = top(7:30, 11:40, :);
 shot = PsychMetal('GetImage', w);
 worst = errors(shot(rows, cols, :), double(expected));
 corner = double(reshape(shot(5, 5, :), 1, 3));
 record('a clip rect confines a draw to the pixel', worst == 0 && isequal(corner, background), ...
     sprintf('largest error %g of 255; a draw outside the clip left %s', worst, mat2str(corner)));

 % ---- polygons -----------------------------------------------------------------------------------------
 PsychMetal('FillPoly', w, [255 128 0], [100 300; 200 300; 100 400]);            % a right triangle
 PsychMetal('FramePoly', w, [0 255 0], [300 300; 400 300; 400 400; 300 400], 5);
 PsychMetal('Flip', w);
 shot = PsychMetal('GetImage', w);
 record('a filled polygon is its colour inside and untouched outside', ...
     differing(shot(321:330, 111:120, :), [255 128 0]) == 0 && differing(shot(386:395, 186:195, :), background) == 0, ...
     sprintf('inside %s, outside %s', mat2str(double(reshape(shot(326, 116, :), 1, 3))), mat2str(double(reshape(shot(391, 191, :), 1, 3)))));
 record('a polygon''s outline is drawn, and its inside left alone', ...
     differing(shot(301, 311:390, :), [0 255 0]) == 0 && differing(shot(311:390, 301, :), [0 255 0]) == 0 && ...
     differing(shot(321:380, 321:380, :), background) == 0, ...
     sprintf('edge %s, inside %s', mat2str(double(reshape(shot(301, 351, :), 1, 3))), mat2str(double(reshape(shot(351, 351, :), 1, 3)))));

 % ---- frames queued ahead ---------------------------------------------------------------------------------
 t0 = PsychMetal('GetSecs') + 0.25;
 for k = 0:3
  PsychMetal('FillRect', w, 50 * (k + 1), dst);
  PsychMetal('QueueFlip', w, t0 + 2 * k * ifi);
 end
 frames = PsychMetal('QueueResults', w);
 got = PsychMetal('GetImage', w, dst);
 record('queued frames are all shown', isequal(size(frames), [4 4]) && all(frames(:, 3) == 0), ...
     sprintf('status %s', mat2str(frames(:, 3)')));
 record('the last queued frame is the one drawn for it', all(got(:) == 200), ...
     sprintf('centre is %s', mat2str(double(reshape(got(25, 33, :), 1, 3)))));
 PsychMetal('Flip', w);
 record('and a flip after them shows a new frame', differing(PsychMetal('GetImage', w, dst), background) == 0, '');

 PsychMetal('ShowCursor');
 PsychMetal('Close', w); w = [];

 % ---- ten bits per channel: a window of its own ---------------------------------------------------------
 opened = true;
 try
  [w, rect] = PsychMetal('OpenWindow', struct('backgroundColor', background, 'readback', true, 'bitDepth', 10));
 catch openError
  opened = false;
  record('a 10-bit window opens', false, openError.message);
 end
 if opened
  PsychMetal('HideCursor');
  PsychMetal('FillRect', w, [255 0 0], [10 20 110 70]);
  % Levels 384..639 of 1023: between the 8-bit levels, so 8 bits cannot hold them.
  ramp = repmat(single(384:639) / 1023, 4, 1);
  tRamp = PsychMetal('MakeTexture', w, ramp);
  PsychMetal('DrawTexture', w, tRamp, [], [16 100 272 104], 0, 0);
  PsychMetal('Flip', w);
  shot = PsychMetal('GetImage', w);
  record('a 10-bit frame is [height width 3] uint16', ...
      isequal(size(shot), [rect(4) rect(3) 3]) && isa(shot, 'uint16'), sprintf('%s %s', mat2str(size(shot)), class(shot)));
  want = round(background / 255 * 1023);
  corner = double(reshape(shot(3, 3, :), 1, 3));
  record('its background is the 0..1023 level of each channel', isequal(corner, want), ...
      sprintf('%s, expected %s', mat2str(corner), mat2str(want)));
  record('red is in the first channel at 1023', differing(shot(21:70, 11:110, :), [1023 0 0]) == 0, ...
      mat2str(double(reshape(shot(46, 61, :), 1, 3))));
  got = double(shot(101:104, 17:272, 1));
  worst = max(max(abs(got - repmat(384:639, 4, 1))));
  record('256 consecutive 10-bit levels come back exactly', worst == 0, ...
      sprintf('largest error %d of 1023; %d distinct levels', worst, numel(unique(got(:)))));
  PsychMetal('ShowCursor');
  PsychMetal('Close', w); w = [];
 end

 % ---- report -------------------------------------------------------------
 okAll = [results.ok];
 report = struct('checks', numel(results), 'passed', sum(okAll), 'failed', sum(~okAll));
 report.results = results;
 fprintf('===== readback =====\n');
 fprintf('%d checks: %d passed, %d failed.\n', numel(results), sum(okAll), sum(~okAll));
 if any(~okAll)
  fprintf('\nFailures:\n');
  for k = find(~okAll)
   fprintf('  %-58s %s\n', results(k).name, results(k).detail);
  end
 else
  fprintf('Every frame read back as drawn.\n');
 end

catch e
 try, PsychMetal('ShowCursor'); catch, end
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 rethrow(e);
end
end

% -------------------------------------------------------------------------
function image = pattern(a, b, c, d, h, w)
% A fixed pseudo-random uint8 image, the same in MATLAB and Python.
[y, x, k] = ndgrid(0:h - 1, 0:w - 1, 0:2);
image = uint8(mod(y * a + x * b + k * c + y .* x * d, 256));
end

function clearTo(target, colour)
% Replace everything an offscreen window holds with one colour, alpha included.
PsychMetal('BlendFunction', target, 'copy');
PsychMetal('FillRect', target, colour);
PsychMetal('BlendFunction', target, 'alpha');
end

function layers(target, x, y)
% Partly transparent, overlapping and soft-edged draws, with their corner at (x, y).
PsychMetal('FillRect', target, [255 255 255 128], [x + 4, y + 4, x + 40, y + 28]);
PsychMetal('FillRect', target, [255 128 0 64], [x + 24, y + 16, x + 60, y + 44]);
PsychMetal('FillOval', target, [0 255 0 200], [x + 2, y + 26, x + 30, y + 46]);
PsychMetal('DrawText', target, 'Ag', x + 34, y + 2, [255 255 0 160], 14);
end

function got = overBottom(w, tBottom, texture, dst, alpha)
% The frame where a texture is drawn over the bottom texture, optionally at a global alpha.
PsychMetal('DrawTexture', w, tBottom, [], dst, 0, 0);
PsychMetal('DrawTexture', w, texture, [], dst, 0, 0, alpha);
PsychMetal('Flip', w);
got = PsychMetal('GetImage', w, dst);
end

function n = differing(image, rgb)
% Pixels of an HxWx3 image that are not exactly this colour.
same = image(:, :, 1) == rgb(1) & image(:, :, 2) == rgb(2) & image(:, :, 3) == rgb(3);
n = sum(~same(:));
end

function [worst, meanError] = errors(got, expected)
% Largest absolute error and mean signed error, in grey levels of 255.
e = double(got(:)) - expected(:);
worst = max(abs(e));
meanError = mean(e);
end
