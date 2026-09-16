function report = PsychMetalGaborDemo(seconds, nGabors, tf, freq)
% PsychMetalGaborDemo  Drifting Gabors, computed in the shader, never uploaded.
%
%   report = PsychMetalGaborDemo(20)            % 12 Gabors, 2 Hz drift
%   report = PsychMetalGaborDemo(20, 1)         % one large Gabor
%   report = PsychMetalGaborDemo(20, 48, 4)     % 48 of them, 4 Hz
%   report = PsychMetalGaborDemo(20, 12, 2, 0.04)
%
% Click any mouse button to stop.
%
% A field of Gabor patches on mid-grey, each at its own orientation, all
% drifting. Everything is drawn by Metal; nothing goes through Screen or OpenGL.
%
% ARGUMENTS
%   seconds   run length, default 20
%   nGabors   how many patches, default 12. Pass 1 for a single large one.
%   tf        temporal frequency in Hz, default 2. The phase advances with
%             PRESENTED TIME, not with the frame counter, so drift rate stays
%             correct across a dropped frame instead of quietly slowing down.
%   freq      carrier spatial frequency in cycles per pixel, default 0.02
%
% WHAT MAKES THIS DIFFERENT FROM THE USUAL APPROACH. A Gabor is normally either
% a texture uploaded once per phase, or a procedural shader compiled by
% Screen('CreateProceduralGabor'). Here both the Gaussian envelope and the
% sinusoidal carrier are evaluated per fragment inside PsychMetal's own shader:
%
%   nothing is uploaded    changing phase, orientation or frequency writes three
%                          floats into the instance buffer. There is no image,
%                          so there is nothing to re-upload and nothing to
%                          resample. Drifting costs the same as standing still.
%   no resolution          the envelope is exp(-r^2/2sigma^2) evaluated at the
%                          fragment, so it is exact at any patch size. A texture
%                          has a fixed sample grid and has to be filtered.
%   one draw call          each patch is one instance. Separate DrawGabor calls
%                          with different orientations still batch into a single
%                          instanced draw, so 48 patches submit exactly as much
%                          work as 1.
%
% The last point is the one worth checking in the output: the reported rate
% should not depend much on nGabors until fill rate rather than submission
% becomes the limit. Try 1, then 48, then 200.
%
% AT FREQUENCY 0 A GABOR IS A GAUSSIAN. Pass freq = 0 to see it: the carrier
% term is identically 1, so the same command and the same shader path produce
% the plain envelope. See PsychMetalBlobDemo for that case on its own.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds), seconds = 20; end
if nargin < 2 || isempty(nGabors), nGabors = 12; end
if nargin < 3 || isempty(tf),      tf = 2; end
if nargin < 4 || isempty(freq),    freq = 0.02; end

assert(isscalar(nGabors) && nGabors >= 1, 'nGabors must be at least 1.');
assert(isscalar(freq) && freq >= 0, 'Frequency must be zero or positive.');
w = [];

try
 screen = [];   % [] is the last active display
 % Mid-grey background, set once at open. Each frame is cleared to it by the
 % render pass load action, which is free; a full-screen FillRect every frame
 % would work too but costs an instanced quad for no reason.
 [w, rect, ifi] = PsychMetal('OpenWindow', screen, 128);
 PsychMetal('HideCursor');

 W = rect(3); H = rect(4);
 sigma = 0.30;                    % envelope width, fraction of the half-size

 % Lay the patches out on as square a grid as the count allows, then size them
 % to the cell so a bigger count means smaller patches rather than overlap.
 if nGabors == 1
  cols = 1; rows = 1;
  half = min(W, H) * 0.35;
  cxs = W/2; cys = H/2;
 else
  cols = ceil(sqrt(nGabors * W / H));
  rows = ceil(nGabors / cols);
  cellW = W / cols; cellH = H / rows;
  half = min(cellW, cellH) * 0.45;
  [gi, gj] = meshgrid(1:cols, 1:rows);
  cxs = (gi(:)' - 0.5) * cellW;
  cys = (gj(:)' - 0.5) * cellH;
  cxs = cxs(1:nGabors); cys = cys(1:nGabors);
 end

 % One orientation per patch, spread over 180 degrees. A Gabor at theta and one
 % at theta+180 are the same stimulus, so the useful range is half a turn.
 angles = (0:nGabors-1) * 180 / nGabors;

 total = round(seconds / ifi);
 frames = 0;
 vbl = NaN; t0 = NaN;
 phaseLog = nan(total,1);

 fprintf('\n%d Gabor(s), %g Hz drift, %g cycles/pixel, sigma %g.\n', ...
     nGabors, tf, freq, sigma);
 fprintf('Grid %d x %d, patch half-size %.0f px. Click to stop.\n', cols, rows, half);

 for k = 1:total
  [~, ~, buttons] = PsychMetal('GetMouse', w);
  if any(buttons), break; end
  frames = k;

  % Phase from the time the NEXT frame is expected to appear, not from the
  % frame index. If a frame is dropped the phase jumps to where it should be
  % rather than falling behind, so the drift rate is a property of the
  % stimulus and not of whether the loop kept up.
  if isnan(vbl)
   tNext = PsychMetal('GetSecs') + ifi;
  else
   tNext = vbl + ifi;
  end
  if isnan(t0), t0 = tNext; end
  phase = mod(360 * tf * (tNext - t0), 360);
  phaseLog(k) = phase;

  % No background fill: the frame is already cleared to mid-grey.
  for g = 1:nGabors
   box = [cxs(g) - half, cys(g) - half, cxs(g) + half, cys(g) + half];
   % Separate calls, one per orientation, because orientation is per shape and
   % the argument is scalar. They still batch: consecutive shapes go out as one
   % instanced draw, so this loop costs instances, not draw calls.
   PsychMetal('DrawGabor', w, 255, box, sigma, freq, angles(g), phase);
  end
  vbl = PsychMetal('Flip', w);
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 warmup = min(120, round(frames/3));
 stAll = PsychMetalFrameStats(d, ifi);
 st = PsychMetalFrameStats(d, ifi, warmup);

 report = struct('ifi', ifi, 'frames', frames, 'nGabors', nGabors, ...
     'temporalHz', tf, 'spatialFreq', freq, 'sigma', sigma, ...
     'halfSize', half, 'cols', cols, 'rows', rows, ...
     'orientations', angles, ...
     'achievedHz', st.achievedHz, 'skipped', st.skipped, ...
     'achievedHzWithSettling', stAll.achievedHz, ...
     'cyclesAcrossPatch', 2 * half * freq, ...
     'phaseLog', phaseLog(1:frames), ...
     'summary', d.summary);

 % The phase is derived from predicted presentation time, so if the prediction
 % were wrong the drift would be uneven even at a perfect frame rate. Median
 % step per frame should equal 360*tf*ifi; a spread much wider than that means
 % the timestamps, not the loop, are what is jittering.
 dPhase = diff(unwrapDeg(phaseLog(1:frames)));
 report.phaseStepMedianDeg = median(dPhase);
 report.phaseStepExpectedDeg = 360 * tf * ifi;

 fprintf('\n===== drifting Gabors, computed in the shader =====\n');
 fprintf('Patches %d; frames %d; skipped %d\n', nGabors, frames, report.skipped);
 fprintf('RATE: %.3f presentations/s\n', report.achievedHz);
 fprintf('       %.3f/s if the first %d settling frames are kept (skipped %d)\n', ...
     stAll.achievedHz, warmup, stAll.skipped);
 fprintf('Carrier: %.1f cycles across a patch %.0f px wide\n', ...
     report.cyclesAcrossPatch, 2*half);
 fprintf('Phase step: %.3f deg/frame measured, %.3f expected\n', ...
     report.phaseStepMedianDeg, report.phaseStepExpectedDeg);
 fprintf(['Every patch is one instance in a single draw call, and the drift is\n' ...
     'one float per patch per frame. Nothing was uploaded: run this again with\n' ...
     '%d patches and the rate should barely move until fill rate, not\n' ...
     'submission, becomes the limit.\n'], min(200, 4*nGabors));

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

function u = unwrapDeg(p)
% Undo the mod(...,360) so consecutive differences are the real step rather
% than a 360-degree drop every cycle. Octave's unwrap works in radians.
u = unwrap(p(:) * pi / 180) * 180 / pi;
end
