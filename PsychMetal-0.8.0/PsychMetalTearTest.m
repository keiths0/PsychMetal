function report = PsychMetalTearTest(seconds, leadOffsetMs, twoPhase)
% PsychMetalTearTest  Software vsync: swap timed against the measured grid.
%
%   PsychMetalTearTest(20)              % sweep the lead offset automatically
%   PsychMetalTearTest(20, 3.0)         % hold one lead offset and inspect
%
% Apple's vsync requires a surface to be complete roughly one refresh before
% the boundary at which it appears, which costs about 1.65 refresh intervals of
% latency and cannot be removed through any documented setting. With
% displaySyncEnabled = NO the frame reaches the display about 2.6 ms after GPU
% completion instead, but swaps then land mid-scan and tear.
%
% This runs vsync off and times each swap against the refresh grid learned while
% vsync was on, i.e. it performs the vsync in software without the latch
% deadline. If the timing is right the swap lands in the vertical blank and there
% is no tear.
%
% WHAT TO LOOK FOR
%   The screen alternates full-field black and white. A correctly timed swap
%   looks like uniform flashing. A mistimed swap shows a horizontal split: the
%   part above the tear is the previous frame, below it the new one.
%
%   A ruler down the left edge is marked 0 at the top to 100 at the bottom. Read
%   the tear position as a percentage, then:
%
%       correction (ms) = position/100 * ifi_ms
%       new leadOffsetMs = current leadOffsetMs + correction
%
%   A tear near 0 or absent means the swap is landing in the blank.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds), seconds = 20; end
if nargin < 2, leadOffsetMs = []; end
% twoPhase = true does all the expensive work before the deadline and issues only
% [drawable present] at the target moment. That is the configuration in which the
% swap can be punctual; the single-phase path does several milliseconds of
% variable work after the deadline.
if nargin < 3 || isempty(twoPhase), twoPhase = true; end

w = [];
try
 screen = [];   % [] is the last active display
 % Open with vsync ON so the grid can be learned from confirmed presentations.
 [w, rect, ifi] = PsychMetal('OpenWindow', screen, [], 2, false, true);
 PsychMetal('HideCursor');
 f = ifi * 1000;

 fprintf('\nLearning the refresh grid with vsync on...\n');
 for k = 1:150
  PsychMetal('FillRect', w, [20 20 20]);
  PsychMetal('FillRect', w, 255 * mod(k,2), [0 0 140 140]);
  PsychMetal('Flip', w);
 end
 g = PsychMetal('GridAnchor', w);
 fprintf('Grid: anchor %.6f, period %.6f ms, %d samples\n', g(1), g(2)*1000, g(3));
 assert(isfinite(g(1)) && g(3) >= 16, 'The refresh grid was not established.');

 % Freeze the grid and remove Apple's latch deadline.
 PsychMetal('SetDisplaySync', w, false);
 fprintf('Display sync off. Software vsync from the frozen grid.\n');
 fprintf('Presentation path: %s\n\n', ...
     merge(twoPhase, 'two-phase (present only at the deadline)', 'single-phase Flip'));

 if isempty(leadOffsetMs)
  offsets = [0 1 2 3 4 5 6 8 10 12];
  perOffset = max(1, round(seconds / numel(offsets) * 60));
  fprintf('Sweeping lead offset. Each setting runs about %.1f s.\n', perOffset/60);
  fprintf('Watch for the setting where the tear disappears.\n\n');
 else
  offsets = leadOffsetMs;
  perOffset = round(seconds * 60);
 end

 rulerW = 90;
 tickY = round(linspace(0, rect(4), 11));
 allTargets = [];
 allOffsets = [];
 allCallMs = [];

 for oi = 1:numel(offsets)
  lead = offsets(oi) / 1000;
  for k = 1:perOffset
   target = PsychMetal('NextRefresh', w, PsychMetal('GetSecs') + 1.5*ifi);
   if ~isfinite(target), target = PsychMetal('GetSecs') + ifi; end

   % Draw first, then wait, then swap: the swap moment is what is being timed.
   level = 255 * mod(k,2);
   PsychMetal('FillRect', w, level);
   PsychMetal('FillRect', w, 255-level, [0 0 rulerW rect(4)]);
   for t = 1:numel(tickY)
    len = rulerW * (0.4 + 0.6*(mod(t-1,5)==0));
    y = min(max(tickY(t)-3, 0), rect(4)-6);
    PsychMetal('FillRect', w, level, [0 y len y+6]);
   end
   PsychMetal('FillRect', w, 255-level, [rect(3)-140 0 rect(3) 140]);

   if twoPhase
    PsychMetal('PrepareFlip', w);
    PsychMetal('WaitSecs', 'UntilTime', target - lead);
    [~, callMs] = PsychMetal('PresentNow', w);
    allCallMs(end+1,1) = callMs; %#ok<AGROW>
   else
    PsychMetal('WaitSecs', 'UntilTime', target - lead);
    PsychMetal('Flip', w);
    allCallMs(end+1,1) = NaN; %#ok<AGROW>
   end
   allTargets(end+1,1) = target; %#ok<AGROW>
   allOffsets(end+1,1) = offsets(oi); %#ok<AGROW>
  end
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 % Phase of each swap within the refresh cycle. This is the measurement:
 % mod(actual - anchor, period) is where in the scan the swap landed, and
 % therefore where the tear appears. Centred so that ~0 means "at the boundary".
 n = min(numel(d.flipNumber), numel(allTargets));
 base = numel(d.flipNumber) - n;          % skip the vsync-on learning frames
 rows = (1:n) + base;
 ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
 period = g(2);
 ph = mod(d.actualTimestamp(rows(ok)) - g(1) + period/2, period) - period/2;
 offUsed = allOffsets(ok);

 fprintf('\n%-12s %10s %10s %10s %10s\n', ...
     'lead (ms)', 'phase(ms)', 'spread(ms)', 'tear(%)', 'suggest(ms)');
 uo = unique(offUsed);
 phaseMs = nan(numel(uo),1); spreadMs = nan(numel(uo),1);
 for oi = 1:numel(uo)
  sel = ph(offUsed == uo(oi));
  if isempty(sel), continue; end
  phaseMs(oi) = median(sel) * 1000;
  spreadMs(oi) = (pct(sel,90) - pct(sel,10)) * 1000;
  tearPct = mod(median(sel), period) / period * 100;
  fprintf('%-12.1f %10.3f %10.3f %10.1f %10.1f\n', ...
      uo(oi), phaseMs(oi), spreadMs(oi), tearPct, uo(oi) + phaseMs(oi));
 end

 cm = allCallMs(ok);
 cm = cm(isfinite(cm));
 if ~isempty(cm)
  fprintf('\n[drawable present] call itself: median %.3f ms, p90 %.3f ms, max %.3f ms\n', ...
      median(cm), pct(cm,90), max(cm));
 end

 [~, best] = min(abs(phaseMs));
 fprintf(['\nBest phase %.3f ms at lead offset %.1f ms; 10-90%% spread %.3f ms.\n'], ...
     phaseMs(best), uo(best), spreadMs(best));
 fprintf('Suggested lead offset: %.2f ms\n', uo(best) + phaseMs(best));
 fprintf(['A phase near zero means the swap lands at the refresh boundary.\n' ...
     'The spread is the limit: it must be well under one refresh (%.2f ms)\n' ...
     'for software vsync to hold, since it is the width of the window in\n' ...
     'which the swap can land.\n'], period*1000);

 report = struct('ifi', ifi, 'gridAnchor', g(1), 'gridPeriod', g(2), ...
     'leadOffsetsMs', uo, 'phaseMs', phaseMs, 'spreadMs', spreadMs, ...
     'suggestedLeadMs', uo(best) + phaseMs(best), 'twoPhase', twoPhase, ...
     'presentCallMs', {cm}, 'summary', d.summary);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

function y = pct(x, p)
x = sort(x(isfinite(x))); n = numel(x);
if n == 0, y = NaN; return; end
q = 1 + (n-1)*p/100; lo = floor(q); hi = ceil(q);
y = x(lo) + (q-lo)*(x(hi)-x(lo));
end

function out = merge(tf, a, b)
if tf, out = a; else, out = b; end
end
