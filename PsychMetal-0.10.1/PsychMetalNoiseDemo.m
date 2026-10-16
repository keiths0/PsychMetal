function report = PsychMetalNoiseDemo(seconds, dist, chroma, spread)
% PsychMetalNoiseDemo  Full-screen dynamic white noise, nothing uploaded.
%
%   report = PsychMetalNoiseDemo(20)                       % cycles all four modes
%   report = PsychMetalNoiseDemo(20, 'uniform', 'mono')
%   report = PsychMetalNoiseDemo(20, 'normal', 'colour', 38)
%
% Click any mouse button to stop.
%
% A new independent value for every pixel on every frame, at the full panel
% resolution. With no arguments it spends a quarter of the run in each of the
% four combinations of uniform/normal and mono/colour, printing which is on.
%
% WHY THIS IS THE INTERESTING CASE. Dynamic full-field noise is the stimulus
% that a generate-and-upload approach cannot deliver. Producing one frame on the
% CPU measures, over this panel and single-threaded:
%
%   mono uniform      7.6 ms
%   colour uniform   15.9 ms
%   mono normal      50.3 ms      (three refreshes, for one frame)
%
% plus 21.5 MB of upload per frame, 1.3 GB/s at 60 Hz. Here a pixel's value is a
% hash of its position and the frame's seed, evaluated in the fragment shader,
% so the per-frame cost is one instanced quad and the transfer is four bytes.
% The rate below is the claim: it should be 60.000/s with zero skips in every
% mode, including the normal one that would take three refreshes on the CPU.
%
% AND IT IS STILL REPRODUCIBLE. Every frame's seed is recorded, and at the end
% one frame is reconstructed from its seed alone and checked against a second
% reconstruction. The demo prints what the seed log costs against what storing
% the frames would have: that ratio is the reverse-correlation argument, since
% an experiment needs the noise back to correlate it with responses.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds), seconds = 20; end
if nargin < 2, dist = []; end
if nargin < 3, chroma = []; end
if nargin < 4 || isempty(spread), spread = 128; end   % half of 0-255

% Empty means cycle: the point of the demo is that all four cost the same.
cycling = isempty(dist) && isempty(chroma);
if cycling
 modes = {'uniform','mono'; 'normal','mono'; 'uniform','colour'; 'normal','colour'};
else
 if isempty(dist), dist = 'uniform'; end
 if isempty(chroma), chroma = 'mono'; end
 modes = {dist, chroma};
end
w = [];

try
 screen = [];   % [] is the last active display
 % Mid-grey background. It is never visible here, since the noise covers the
 % whole window, but it is what the noise would sit on if the rect were smaller.
 [w, rect, ifi] = PsychMetal('OpenWindow', screen, 128);
 PsychMetal('HideCursor');

 total = round(seconds / ifi);
 nMode = size(modes, 1);
 perMode = max(1, floor(total / nMode));
 seeds = nan(total, 1);
 modeOf = nan(total, 1);
 frames = 0;
 lastLabel = '';

 fprintf('\nFull-screen dynamic noise, %d x %d, spread %g.\n', ...
     rect(3), rect(4), spread);
 if cycling
  fprintf('Cycling uniform/normal x mono/colour, %.1f s each.\n', perMode*ifi);
 else
  fprintf('%s, %s.\n', modes{1,1}, modes{1,2});
 end
 fprintf('Click to stop.\n\n');

 for k = 1:total
  [~, ~, buttons] = PsychMetal('GetMouse', w);
  if any(buttons), break; end
  frames = k;

  m = min(nMode, floor((k-1) / perMode) + 1);
  modeOf(k) = m;
  label = sprintf('%s, %s', modes{m,1}, modes{m,2});
  if ~strcmp(label, lastLabel)
   fprintf('  %s\n', label);
   lastLabel = label;
  end

  % Seed omitted, so one is drawn and handed back. Recording it is the whole
  % reproducibility story: four bytes instead of the frame.
  seeds(k) = PsychMetal('DrawNoise', w, rect, [], modes{m,1}, modes{m,2}, [], spread);
  PsychMetal('Flip', w);
 end

 d = PsychMetal('Diagnostic', w);

 % Reconstruct one frame from its seed alone, well after it was shown. Done
 % before Close because NoiseValues needs the window; it is CPU work and
 % deliberately outside the loop, which is the point being made.
 pick = max(1, round(frames * 0.5));
 pm = modeOf(pick);
 t0 = PsychMetal('GetSecs');
 rebuilt = PsychMetal('NoiseValues', w, rect, seeds(pick), ...
     modes{pm,1}, modes{pm,2}, [], spread);
 rebuildMs = (PsychMetal('GetSecs') - t0) * 1000;
 % Determinism is a property of the hash, not of the size, so it is checked on a
 % corner rather than by allocating a second full-screen array: at colour
 % resolution that pair would be a quarter of a gigabyte for no extra evidence.
 corner = [0 0 256 256];
 stable = isequal( ...
     PsychMetal('NoiseValues', w, corner, seeds(pick), modes{pm,1}, modes{pm,2}, [], spread), ...
     PsychMetal('NoiseValues', w, corner, seeds(pick), modes{pm,1}, modes{pm,2}, [], spread));

 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 warmup = min(120, round(frames/3));
 stAll = PsychMetalFrameStats(d, ifi);
 st = PsychMetalFrameStats(d, ifi, warmup);

 px = numel(rebuilt);
 seedBytes = frames * 8;
 frameBytes = frames * px * 8;

 report = struct('ifi', ifi, 'frames', frames, 'seeds', seeds(1:frames), ...
     'modeOf', modeOf(1:frames), 'modes', {modes}, 'spread', spread, ...
     'achievedHz', st.achievedHz, 'skipped', st.skipped, ...
     'achievedHzWithSettling', stAll.achievedHz, ...
     'rebuiltFrame', pick, 'rebuildMs', rebuildMs, ...
     'rebuildStable', stable, ...
     'rebuiltMin', min(rebuilt(:)), 'rebuiltMax', max(rebuilt(:)), ...
     'rebuiltMean', mean(rebuilt(:)), ...
     'seedLogBytes', seedBytes, 'frameLogBytes', frameBytes, ...
     'summary', d.summary);

 fprintf('\n===== dynamic white noise, computed in the shader =====\n');
 fprintf('Frames %d; skipped %d\n', frames, report.skipped);
 fprintf('RATE: %.3f presentations/s\n', report.achievedHz);
 fprintf('       %.3f/s if the first %d settling frames are kept (skipped %d)\n', ...
     stAll.achievedHz, warmup, stAll.skipped);
 if cycling
  fprintf('\nPer mode:\n');
  for m = 1:nMode
   rows = find(modeOf(1:frames) == m);
   if numel(rows) < 5, continue; end
   sub = PsychMetalFrameStats(d, ifi, rows(1) + 5);
   fprintf('  %-18s %8.3f/s\n', sprintf('%s, %s', modes{m,1}, modes{m,2}), ...
       sub.achievedHz);
  end
  fprintf(['  (each runs from that mode''s start to the end of the run, so a row\n' ...
      '   includes the modes after it; read them as "no mode broke the rate")\n']);
 end

 fprintf('\nRECONSTRUCTION. Frame %d rebuilt from seed %d alone, %.1f ms.\n', ...
     pick, seeds(pick), rebuildMs);
 fprintf('  repeatable: %s\n', tf(stable));
 fprintf('  range %.4f to %.4f, mean %.4f\n', ...
     report.rebuiltMin, report.rebuiltMax, report.rebuiltMean);
 fprintf('  %.1f ms is why this is not done per frame, and %.1f ms x %d frames\n', ...
     rebuildMs, rebuildMs, frames);
 fprintf('  is why the CPU cannot generate this stimulus in the first place.\n');

 fprintf('\nSTORAGE. Seed log %.1f kB against %.1f MB for the frames themselves,\n', ...
     seedBytes/1e3, frameBytes/1e6);
 fprintf('  a factor of %.0f, and the frames are recoverable from the seeds.\n', ...
     frameBytes/max(1,seedBytes));

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

function s = tf(v)
if v, s = 'yes'; else, s = 'NO - the generator is not deterministic'; end
end
