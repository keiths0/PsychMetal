function report = PsychMetalWarmupLength(frames, repeats, targetMsPerHour)
% PsychMetalWarmupLength  How few frames does the refresh estimate actually need?
%
%   report = PsychMetalWarmupLength(600, 3)        % 1 ms/hour target
%   report = PsychMetalWarmupLength(600, 3, 5)     % 5 ms/hour target
%
% The only thing the warm-up has to measure is the refresh grid: its period and
% its phase anchor. The anchor needs one confirmed presentation. The period is a
% least-squares fit, and this finds the shortest fit that is as good as a long
% one.
%
% Method: acquire one long run, then fit the period using only the first N
% samples for a range of N, and compare each against the full-run fit. No extra
% acquisition per candidate length - it is all post hoc on the same data.
%
% Two different limits are reported and they matter differently:
%
%   WITHIN-RUN convergence   how N-sample and full-run fits differ on the same
%                            data. Falls as N^1.5 and gets small quickly.
%   BETWEEN-RUN scatter      how the full-run fits differ across repeats. This
%                            is the real floor: two independent oscillators
%                            drifting, most likely with temperature.
%
% The recommendation is driven by a TARGET ERROR, not by reaching the floor.
% The floor here is around 0.15 ms/hour, which no experiment needs; chasing it
% costs seconds of warm-up for nothing. State what you can tolerate and take the
% shortest fit that meets it.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(frames), frames = 600; end
if nargin < 2 || isempty(repeats), repeats = 3; end
if nargin < 3 || isempty(targetMsPerHour), targetMsPerHour = 1.0; end
targetPpm = targetMsPerHour / 3600 / 1000 * 1e6;

candidates = [15 20 30 45 60 90 120 180 240 300 400];
candidates = candidates(candidates <= frames);

fullHz = nan(repeats,1);
conv = nan(repeats, numel(candidates));

for rep = 1:repeats
 fprintf('\n########## run %d of %d ##########\n', rep, repeats);
 [t, period] = acquire(frames);
 fprintf('longest clean sequence: %d frames\n', numel(t));

 fullHz(rep) = 1 / fitPeriod(t);
 for i = 1:numel(candidates)
  n = candidates(i);
  if n > numel(t), continue; end
  conv(rep,i) = (1/fitPeriod(t(1:n)) - fullHz(rep)) / fullHz(rep) * 1e6;  % ppm
 end
 fprintf('full-run estimate from %d frames: %.6f Hz\n', numel(t), fullHz(rep));
 clear period
end

betweenPpm = (max(fullHz) - min(fullHz)) / mean(fullHz) * 1e6;

fprintf('\n================ how long must the warm-up be? ================\n');
fprintf('Nominal 60 Hz. Full-run estimates: ');
fprintf('%.6f ', fullHz); fprintf('Hz\n');
fprintf('Offset from nominal: %.3f ppm\n', (mean(fullHz) - 60)/60 * 1e6);
fprintf('BETWEEN-RUN scatter: %.3f ppm  <-- the floor\n\n', betweenPpm);

fprintf('Target: %.2f ms/hour (%.3f ppm)\n\n', targetMsPerHour, targetPpm);
fprintf('%-10s %10s %16s %16s\n', 'frames', 'seconds', 'error ppm', 'ms per hour');
ok = false(1, numel(candidates));
for i = 1:numel(candidates)
 v = abs(conv(:,i));
 v = v(isfinite(v));
 if isempty(v), continue; end
 msPerHour = max(v) / 1e6 * 3600 * 1000;
 ok(i) = max(v) <= targetPpm;
 fprintf('%-10d %10.2f %16.3f %16.2f%s\n', candidates(i), candidates(i)/60, ...
     max(v), msPerHour, tern(ok(i), '  <- meets target', ''));
end

first = find(ok, 1);
fprintf('\n');
if isempty(first)
 fprintf(['No candidate length met %.2f ms/hour. Either lengthen the run or\n' ...
     'accept a larger target.\n'], targetMsPerHour);
 recommended = candidates(end);
else
 recommended = candidates(first);
 fprintf('RECOMMENDATION: %d frames (%.2f s at 60 Hz) for %.2f ms/hour.\n', ...
     recommended, recommended/60, targetMsPerHour);
 fprintf(['The between-run floor is %.3f ppm (%.2f ms/hour). Sampling past the\n' ...
     'point where within-run error approaches it averages over real drift\n' ...
     'rather than reducing noise.\n'], betweenPpm, betweenPpm/1e6*3600*1000);
end

fprintf(['\nThe grid ANCHOR needs only one confirmed presentation, so the period\n' ...
    'fit above is what sets the warm-up length. At %.3f ppm the accumulated\n' ...
    'error is about %.1f ms per hour.\n'], ...
    abs((mean(fullHz)-60)/60*1e6), abs((mean(fullHz)-60)/60) * 3600 * 1000);

report = struct('candidates', candidates, 'withinRunPpm', conv, ...
    'fullRunHz', fullHz, 'betweenRunPpm', betweenPpm, ...
    'targetMsPerHour', targetMsPerHour, 'recommendedFrames', recommended);
end

% -------------------------------------------------------------------------
function [t, period] = acquire(frames)
w = [];
try
 screen = [];   % [] is the last active display
 [w, ~, period] = PsychMetal('OpenWindow', screen);
 PsychMetal('HideCursor');
 for k = 1:frames
  PsychMetal('FillRect', w, [20 20 20]);
  PsychMetal('FillRect', w, 255 * mod(k,2), [0 0 140 140]);
  PsychMetal('Flip', w);
 end
 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 % Longest run of consecutive confirmed presentations exactly one refresh
 % apart. A skip breaks the frame-number mapping and would bias the slope.
 ts = d.actualTimestamp(:);
 okRow = d.actualStatus(:) == 0 & isfinite(ts);
 gap = [NaN; round(diff(ts) / period)];
 good = okRow & [false; okRow(1:end-1)] & gap == 1;
 best = [0 0]; runStart = NaN;
 for i = 1:numel(good)
  if good(i)
   if isnan(runStart), runStart = i-1; end
   if (i - runStart + 1) > best(2) - best(1) + 1, best = [runStart i]; end
  else
   runStart = NaN;
  end
 end
 assert(best(2) > best(1), 'No clean one-per-refresh sequence found.');
 t = ts(best(1):best(2));
catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

function p = fitPeriod(t)
% Least-squares slope of timestamp against frame index.
n = numel(t);
k = (0:n-1)';
p = ((n * sum(k .* t) - sum(k) * sum(t)) / (n * sum(k.^2) - sum(k)^2));
end

function out = tern(c, a, b)
if c, out = a; else, out = b; end
end
