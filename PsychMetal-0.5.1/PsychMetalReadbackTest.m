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
%   * a texture updated on every frame, which must show that frame's image.
%
% What this establishes is the rendered frame: the pixels the GPU handed to the
% display. It says nothing about what the compositor or the panel did with them.
%
% About two seconds. Every check is independent; a failure is recorded and the
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
 fprintf('\nPsychMetal readback test. About two seconds.\n\n');
 [w, rect] = PsychMetal('OpenWindow', struct('backgroundColor', background, 'readback', true));
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

 PsychMetal('ShowCursor');
 PsychMetal('Close', w); w = [];

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
