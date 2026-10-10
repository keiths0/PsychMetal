function report = PTBTimingTest(measuredFrames, mode, skipSyncTests)
% PTBTimingTest  Standard Psychtoolbox timing, measured the same way as PsychMetal.
%
%   report = PTBTimingTest(300)                  % default Screen path
%   report = PTBTimingTest(300, 'vulkan')        % PTB's Vulkan display backend
%   report = PTBTimingTest(300, 'default', 2)    % skip PTB's startup sync tests
%
% Runs the same three workloads as the PsychMetal demos through ordinary
% Screen('Flip'), and reports the same statistics, so the two can be compared
% directly:
%
%   1  Unscheduled presentation. Rate, interval distribution, skipped refreshes.
%   2  Scheduled presentation at 1, 2, 3 and 4 refresh spacing, using the
%      standard vbl + (waitframes - 0.5) * ifi idiom.
%   3  Input-to-photons for a mouse-tracking stimulus.
%
% IMPORTANT - THE TIMESTAMPS ARE NOT THE SAME KIND OF MEASUREMENT
%
% PsychMetal reports MTLDrawable.presentedTime, which Apple derives from the
% display pipeline. Screen('Flip') returns PTB's own VBL estimate, which on a
% machine without working beamposition queries falls back to a less direct
% method - PTB says so at startup. Interval *statistics* are comparable because
% both measure the spacing between successive presentations. Absolute onset
% times are not comparable, and neither is validated against a photodiode.
%
% Report PTB's startup banner alongside these numbers: whether it skipped sync
% tests, what it measured the refresh interval to be, and whether it warned
% about the desktop compositor all bear on how the figures should be read.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(measuredFrames), measuredFrames = 300; end
if nargin < 2 || isempty(mode), mode = 'default'; end
if nargin < 3, skipSyncTests = []; end
assert(any(strcmpi(mode, {'default','vulkan'})), 'mode must be ''default'' or ''vulkan''.');
assert(isnumeric(measuredFrames) && isscalar(measuredFrames) && ...
    isfinite(measuredFrames) && measuredFrames >= 60 && measuredFrames == fix(measuredFrames), ...
    'measuredFrames must be an integer of at least 60.');

warmup = 120;
total  = warmup + measuredFrames;
w = []; oldSkip = [];

try
 PsychDefaultSetup(2);
 screen = max(Screen('Screens'));
 if ~isempty(skipSyncTests)
  oldSkip = Screen('Preference', 'SkipSyncTests', skipSyncTests);
 end

 PsychImaging('PrepareConfiguration');
 usedVulkan = false;
 if strcmpi(mode, 'vulkan')
  try
   PsychImaging('AddTask', 'General', 'UseVulkanDisplay');
   usedVulkan = true;
  catch
   fprintf('WARNING: could not add the Vulkan display task; using the default path.\n');
  end
 end
 [w, rect] = PsychImaging('OpenWindow', screen, 0);
 ifi = Screen('GetFlipInterval', w);
 f = ifi * 1000;
 HideCursor(screen);

 nominal = 1 / Screen('NominalFrameRate', screen);
 effSkip = Screen('Preference', 'SkipSyncTests');
 fprintf('\n================ PTB timing test ================\n');
 fprintf('Mode: %s%s\n', mode, tern(usedVulkan, ' (Vulkan active)', ''));
 fprintf('Measured IFI %.6f ms (%.5f Hz); nominal %.6f ms\n', ...
     f, 1/ifi, nominal*1000);
 fprintf('SkipSyncTests in effect: %d\n', effSkip);

 % The 'mode' argument requests a backend; it does not guarantee one. PTB may
 % engage Vulkan on its own when it needs better timestamps. Record what
 % actually happened rather than what was asked for.
 winfo = [];
 try
  winfo = Screen('GetWindowInfo', w);
 catch
 end
 backend = 'unknown';
 if isstruct(winfo)
  for fn = {'VBLTimestampingMode','GLDisplayBackend','DisplayCoreId'}
   if isfield(winfo, fn{1})
    val = winfo.(fn{1});
    if isnumeric(val) && isscalar(val)
     fprintf('  winfo.%s = %g\n', fn{1}, val);
    elseif ischar(val)
     fprintf('  winfo.%s = %s\n', fn{1}, val);
    end
   end
  end
  if isfield(winfo, 'VulkanHandle') || isfield(winfo, 'vulkan')
   backend = 'vulkan';
  end
 end
 fprintf(['Requested backend: %s. Check the banner above: if it says "external\n' ...
     'display backend for accurate Flip timestamping" and shows MoltenVK output,\n' ...
     'the Vulkan path is active regardless of what was requested.\n'], mode);
 if effSkip > 0
  fprintf(['*** PTB skipped its calibration, so the IFI above is the NOMINAL\n' ...
      '*** value from the OS, not a measured one. Every scheduled flip in\n' ...
      '*** test 2 is therefore placed on a nominal grid. Re-run with\n' ...
      '*** Screen(''Preference'',''SkipSyncTests'',0) before quoting these\n' ...
      '*** numbers, or the comparison is not on equal footing.\n']);
 end

 % ---------------------------------------------------------------- test 1
 vbls = nan(total,1); missed = nan(total,1); drawMs = nan(total,1);
 flipMs = nan(total,1);
 vbl = Screen('Flip', w);
 for k = 1:total
  t0 = GetSecs;
  drawFrame(w, rect, k);
  drawMs(k) = (GetSecs - t0) * 1000;
  t1 = GetSecs;
  [vbl, ~, ~, miss] = Screen('Flip', w);
  flipMs(k) = (GetSecs - t1) * 1000;
  vbls(k) = vbl; missed(k) = miss;
 end
 r1 = summarise(vbls(warmup+1:end), ifi);
 r1.drawMedianMs = median(drawMs(warmup+1:end));
 r1.flipMedianMs = median(flipMs(warmup+1:end));
 r1.missedMedian = median(missed(warmup+1:end));
 r1.missedPositive = sum(missed(warmup+1:end) > 0);

 fprintf('\n--- 1. Unscheduled presentation, %d frames ---\n', measuredFrames);
 fprintf('RATE: %.3f presentations/s = one per %.2f refreshes (skipped %d)\n', ...
     r1.achievedHz, r1.meanGap, r1.skipped);
 fprintf('Interval min/p1/p25/median/p75/p99/max\n');
 fprintf('  %.4f / %.4f / %.4f / %.4f / %.4f / %.4f / %.4f ms\n', ...
     r1.minMs, r1.p01Ms, r1.p25Ms, r1.medianMs, r1.p75Ms, r1.p99Ms, r1.maxMs);
 fprintf('Interval mean %.6f ms; median %.6f ms; mean - median %.6f ms\n', ...
     r1.meanMs, r1.medianMs, r1.meanMs - r1.medianMs);
 fprintf('Interval spread (p99 - p1) %.6f ms\n', r1.p99Ms - r1.p01Ms);
 if abs(r1.meanMs - r1.medianMs) > 0.05
  fprintf(['NOTE: mean and median differ by more than 0.05 ms while no refresh\n' ...
      'was skipped. The presentations are landing one per refresh; it is the\n' ...
      'timestamps that are scattered. Read the percentile row, not the median.\n']);
 end
 fprintf('Draw / Flip medians %.3f / %.3f ms\n', r1.drawMedianMs, r1.flipMedianMs);
 fprintf('Missed median %.4f; frames with Missed > 0: %d\n', ...
     r1.missedMedian, r1.missedPositive);

 % ---------------------------------------------------------------- test 2
 fprintf('\n--- 2. Scheduled presentation (the when argument) ---\n');
 fprintf('%-10s %10s %10s %12s %10s %10s\n', ...
     'waitframes', 'achieved', 'correct', 'interval ms', 'missed>0', 'n');
 sched = struct('waitframes', {}, 'medianGap', {}, 'correctGaps', {}, ...
     'medianIntervalMs', {}, 'missedPositive', {}, 'n', {}, ...
     'gapHistogram', {}, 'gapsAbove8', {});
 per = max(60, round(measuredFrames/2));
 for wf = 1:4
  v = nan(per,1); m = nan(per,1);
  vbl = Screen('Flip', w);
  for k = 1:per
   drawFrame(w, rect, k);
   [vbl, ~, ~, miss] = Screen('Flip', w, vbl + (wf - 0.5) * ifi);
   v(k) = vbl; m(k) = miss;
  end
  gaps = round(diff(v) / ifi);
  s = struct();
  s.waitframes = wf;
  s.medianGap = median(gaps);
  s.correctGaps = sum(gaps == wf);
  s.medianIntervalMs = median(diff(v)) * 1000;
  s.missedPositive = sum(m > 0);
  s.n = numel(gaps);
  s.gapHistogram = [(0:8)', arrayfun(@(g) sum(gaps == g), (0:8)')];
  s.gapsAbove8 = sum(gaps > 8);
  sched(end+1) = s; %#ok<AGROW>
  fprintf('%-10d %10.2f %10d %12.4f %10d %10d\n', ...
      wf, s.medianGap, s.correctGaps, s.medianIntervalMs, s.missedPositive, s.n);
 end
 fprintf(['A correct row has achieved == waitframes and correct == n.\n' ...
     'Anything else means the when argument did not place the frame where\n' ...
     'it was asked to.\n']);

 % How a failure fails matters more than that it failed. Consistently one
 % refresh late is a different bug from randomly scattered.
 fprintf('\nGap distribution (refreshes between successive presentations):\n');
 fprintf('%-10s', 'waitframes');
 fprintf('%6d', 0:8); fprintf('%8s\n', '>8');
 for i = 1:numel(sched)
  fprintf('%-10d', sched(i).waitframes);
  fprintf('%6d', sched(i).gapHistogram(:,2));
  fprintf('%8d\n', sched(i).gapsAbove8);
 end

 % ---------------------------------------------------------------- test 3
 logicalRect = Screen('Rect', screen);
 scale = rect(3) / max(1, logicalRect(3) - logicalRect(1));
 discSide = min(rect(3), rect(4)) * 0.06;
 sampleTime = nan(total,1); v3 = nan(total,1);
 vbl = Screen('Flip', w);
 for k = 1:total
  t0 = GetSecs;
  sampleTime(k) = t0;
  [mx, my] = GetMouse(screen);
  x = min(max(mx*scale, 0), rect(3));
  y = min(max(my*scale, 0), rect(4));
  Screen('FillRect', w, [25 30 45]);
  Screen('FillOval', w, [235 215 120], ...
      CenterRectOnPoint([0 0 discSide discSide], x, y));
  Screen('FillRect', w, 255*mod(k,2), [0 0 140 140]);
  v3(k) = Screen('Flip', w);
 end
 idx = (warmup+1):total;
 inputMs = (v3(idx) - sampleTime(idx)) * 1000;
 r3 = summarise(v3(idx), ifi);

 fprintf('\n--- 3. Mouse tracking, input to reported VBL ---\n');
 fprintf('RATE: %.3f presentations/s = one per %.2f refreshes (skipped %d)\n', ...
     r3.achievedHz, r3.meanGap, r3.skipped);
 fprintf('INPUT -> VBL median %.3f ms (%.3f refreshes); p95 %.3f ms\n', ...
     median(inputMs), median(inputMs)/f, pct(inputMs,95));

 Screen('CloseAll'); w = []; ShowCursor;
 if ~isempty(oldSkip), Screen('Preference','SkipSyncTests', oldSkip); end

 report = struct('mode', mode, 'usedVulkan', usedVulkan, ...
     'skipSyncTests', skipSyncTests, 'ifi', ifi, 'nominalIfi', nominal, ...
     'unscheduled', r1, 'scheduled', sched, 'mouse', r3, ...
     'inputToVblMedianMs', median(inputMs), 'inputToVblP95Ms', pct(inputMs,95), ...
     'effectiveSkipSyncTests', effSkip, 'windowInfo', winfo, ...
     'detectedBackend', backend, 'ptbVersion', PsychtoolboxVersion);

 fprintf('\n--- Comparison notes ---\n');
 fprintf(['Screen(''Flip'') returns PTB''s own VBL estimate. PsychMetal reports\n' ...
     'Apple''s MTLDrawable.presentedTime. Interval statistics are comparable;\n' ...
     'absolute onset times are not, and neither is photodiode-validated.\n' ...
     'Quote PTB''s startup banner with these numbers.\n']);

catch e
 try, if ~isempty(w), Screen('CloseAll'); end; catch, end
 try, ShowCursor; catch, end
 try, if ~isempty(oldSkip), Screen('Preference','SkipSyncTests', oldSkip); end; catch, end
 rethrow(e);
end
end

% -------------------------------------------------------------------------
function drawFrame(w, rect, k)
Screen('FillRect', w, [30 35 50]);
side = min(rect(3), rect(4)) * 0.2;
x = rect(3)/2 + cos(k*0.11) * rect(3) * 0.2;
y = rect(4)/2 + sin(k*0.11) * rect(4) * 0.2;
Screen('FillOval', w, [220 210 190], CenterRectOnPoint([0 0 side side], x, y));
% Photodiode patch, same as the PsychMetal demos.
Screen('FillRect', w, 255 * mod(k,2), [0 0 140 140]);
end

function s = summarise(vbl, ifi)
iv = diff(vbl) * 1000;
iv = iv(isfinite(iv));
gaps = round(iv / (ifi*1000));
s = struct();
s.n = numel(iv);
s.meanMs = mean(iv);
s.medianMs = median(iv);
s.p01Ms = pct(iv, 1);
s.p25Ms = pct(iv, 25);
s.p75Ms = pct(iv, 75);
s.p99Ms = pct(iv, 99);
s.minMs = min(iv);
s.maxMs = max(iv);
s.meanGap = mean(iv) / (ifi*1000);
s.achievedHz = 1000 / mean(iv);      % mean, not median: a median hides drops
s.onePerRefresh = sum(gaps == 1);
s.skipped = sum(gaps > 1);
end

function y = pct(x, p)
x = sort(x(isfinite(x))); n = numel(x);
if n == 0, y = NaN; return; end
q = 1 + (n-1)*p/100; lo = floor(q); hi = ceil(q);
y = x(lo) + (q-lo)*(x(hi)-x(lo));
end

function out = tern(tf, a, b)
if tf, out = a; else, out = b; end
end
