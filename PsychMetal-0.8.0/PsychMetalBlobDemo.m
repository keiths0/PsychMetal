function report = PsychMetalBlobDemo(seconds, hz, contrast)
% PsychMetalBlobDemo  A counterphasing Gaussian blob that follows the mouse.
%
%   report = PsychMetalBlobDemo(20)         % 1 Hz, full contrast
%   report = PsychMetalBlobDemo(20, 2, 0.5) % 2 Hz, half contrast
%
% Click any mouse button to stop.
%
% A Gaussian luminance envelope on a mid-grey field, oscillating sinusoidally
% between darker and brighter than the background, positioned by the mouse.
% Everything is drawn by Metal; nothing goes through Screen.
%
% NOT A TEXTURE. The envelope is exp(-r^2/2sigma^2) evaluated per fragment, so
% there is no image to upload and no resampling: it is exact at any size and
% costs one instanced quad. Changing contrast every frame is a colour change,
% not a re-upload, which is what makes 60 Hz counterphase free.
%
% How the sinusoid is produced, since it is not obvious:
%
%   The shader puts the Gaussian in ALPHA. Sign and amplitude come from the
%   colour. For a signed contrast s = C*sin(2*pi*f*t) on a 0.5 background, draw
%   white when s > 0 and black when s < 0, with alpha = 2*|s|*gauss. Blending
%   over the grey gives 0.5 + s*gauss exactly, which is the counterphase.
%
% Reports achieved rate and mouse-to-presentation latency.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds),  seconds = 20; end
if nargin < 2 || isempty(hz),       hz = 1; end
if nargin < 3 || isempty(contrast), contrast = 0.5; end
assert(contrast > 0 && contrast <= 0.5, ...
    'Contrast is the amplitude about mid-grey, so it must be in (0, 0.5].');
w = [];

try
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen);
 PsychMetal('HideCursor');

 sigma = 0.30;                       % fraction of the half-size
 halfSize = min(rect(3), rect(4)) * 0.12;   % about 3.3 sigma to the edge
 total = round(seconds / ifi);
 sampleTime = nan(total,1);
 lum = nan(total,1);
 frames = 0;
 t0 = PsychMetal('GetSecs');

 fprintf('\nGaussian blob, %g Hz counterphase, contrast %g.\n', hz, contrast);
 fprintf('Move the mouse to reposition it. Click to stop.\n');

 for k = 1:total
  sampleTime(k) = PsychMetal('GetSecs');
  [mx, my, buttons] = PsychMetal('GetMouse', w);
  if any(buttons), break; end
  frames = k;

  s = contrast * sin(2*pi*hz * (sampleTime(k) - t0));
  lum(k) = 0.5 + s;

  x = min(max(mx, 0), rect(3));
  y = min(max(my, 0), rect(4));
  box = [x - halfSize, y - halfSize, x + halfSize, y + halfSize];

  % Mid-grey field.
  PsychMetal('FillRect', w, 128);
  % Signed contrast: white above the background, black below. Alpha carries
  % twice the amplitude because blending halves it against the grey.
  if s >= 0
   PsychMetal('DrawGabor', w, [255 255 255 min(255, 510*s)],  box, sigma);
  else
   PsychMetal('DrawGabor', w, [0 0 0 min(255, -510*s)], box, sigma);
  end
  PsychMetal('Flip', w);
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 n = min(frames, numel(d.flipNumber));
 % Report both with and without a settling allowance. The demos used to quote
 % the whole run, which folds window startup into the rate; PsychMetalPrimitives
 % Demo already discarded 120 frames, so the demos were not comparable with each
 % other. If these two numbers differ much, the run had not settled.
 warmup = min(120, round(n/3));
 stAll = PsychMetalFrameStats(d, ifi);
 st = PsychMetalFrameStats(d, ifi, warmup);
 rows = 1:n;
 ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
 inputMs = (d.actualTimestamp(rows(ok)) - sampleTime(rows(ok))) * 1000;

 report = struct('ifi', ifi, 'frames', n, 'hz', hz, 'contrast', contrast, ...
     'sigma', sigma, 'achievedHz', st.achievedHz, 'skipped', st.skipped, ...
     'luminanceMin', min(lum), 'luminanceMax', max(lum), ...
     'inputToPhotonsMedianMs', median(inputMs), ...
     'inputToPhotonsRefreshes', median(inputMs)/(ifi*1000), ...
     'summary', d.summary);

 fprintf('\n===== Gaussian blob, drawn in Metal =====\n');
 fprintf('Frames %d; confirmed %d; skipped %d\n', n, sum(ok), report.skipped);
 fprintf('RATE: %.3f presentations/s\n', report.achievedHz);
 fprintf('       %.3f/s if the first %d settling frames are kept (skipped %d)\n', ...
     stAll.achievedHz, warmup, stAll.skipped);
 fprintf('Luminance swept %.3f to %.3f about 0.5\n', ...
     report.luminanceMin, report.luminanceMax);
 fprintf('MOUSE -> PRESENTED median %.3f ms (%.3f refreshes)\n', ...
     report.inputToPhotonsMedianMs, report.inputToPhotonsRefreshes);
 fprintf(['One instanced quad per frame for the blob; the envelope is evaluated\n' ...
     'in the fragment shader, so nothing is uploaded per frame.\n']);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
