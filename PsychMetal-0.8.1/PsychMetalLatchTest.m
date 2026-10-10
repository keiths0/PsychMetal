function report = PsychMetalLatchTest(repeats, drawables)
% PsychMetalLatchTest  Locate the presentation deadline within the refresh cycle.
%
%   report = PsychMetalLatchTest(40)      % 3 drawables (default)
%   report = PsychMetalLatchTest(40, 2)   % 2 drawables
%
% drawables sets maximumDrawableCount. In a continuous loop each drawable costs
% one refresh of latency, but this test drains the queue before every present,
% so it asks a different question: does the buffer count change what a drained
% pipeline can achieve? If the floor is a compositor property it will not move.
%
% Runs with vsync ON and the two-phase path, so the only variable is the moment
% the [drawable present] call is issued. Everything else — fence, drawable
% acquisition, encode, commit, waitUntilScheduled — happens beforehand, and the
% present call itself takes about 40 microseconds.
%
% Each call is anchored to a freshly confirmed presentation rather than to a
% predicted grid point, so the reference cannot drift as the sweep proceeds. The
% frame's presentation is then reported as a whole number of refresh boundaries
% after that anchor, which is unambiguous.
%
%   A step in the boundary count at some phase X
%       Real cutoff. Present before X and the frame makes the earlier boundary.
%       X is the deadline.
%
%   Flat regardless of phase
%       No cutoff; a fixed queue depth that nothing the application does can
%       avoid.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(repeats), repeats = 40; end
if nargin < 2 || isempty(drawables), drawables = 3; end
assert(isnumeric(repeats) && isscalar(repeats) && isfinite(repeats) && ...
    repeats >= 5 && repeats == fix(repeats), 'repeats must be an integer of at least 5.');
assert(isnumeric(drawables) && isscalar(drawables) && any(drawables == [2 3]), ...
    'drawables must be 2 or 3.');

w = [];
try
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen, [], drawables, false, true);
 PsychMetal('HideCursor');
 fprintf('\nDrawables: %d\n', drawables);

 fprintf('\nLearning the refresh grid...\n');
 for k = 1:150
  PsychMetal('FillRect', w, [20 20 20]);
  PsychMetal('FillRect', w, 255 * mod(k,2), [0 0 140 140]);
  PsychMetal('Flip', w);
 end
 g0 = PsychMetal('GridAnchor', w);
 period = g0(2);
 assert(isfinite(g0(1)) && g0(3) >= 16, 'The refresh grid was not established.');
 fprintf('Grid period %.6f ms, %d samples\n\n', period*1000, g0(3));

 phases = 0.025:0.025:0.975;
 anchorUsed = []; callTime = []; callPhase = [];

 fprintf('Sweeping the present-call phase, anchored to confirmed presentations...\n');
 for pi = 1:numel(phases)
  for k = 1:repeats
   % Re-anchor every frame on the most recent confirmed presentation.
   g = PsychMetal('GridAnchor', w);
   anchor = g(1);
   if ~isfinite(anchor), continue; end
   when = anchor + 2*period + phases(pi)*period;
   if when < PsychMetal('GetSecs') + 0.004, when = when + period; end

   level = 255 * mod(k,2);
   PsychMetal('FillRect', w, level);
   PsychMetal('FillRect', w, 255-level, [0 0 140 140]);

   PsychMetal('PrepareFlip', w);
   PsychMetal('WaitSecs', 'UntilTime', when);
   t = PsychMetal('PresentNow', w);

   anchorUsed(end+1,1) = anchor;   %#ok<AGROW>
   callTime(end+1,1)   = t;        %#ok<AGROW>
   callPhase(end+1,1)  = phases(pi); %#ok<AGROW>
  end
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 n = min(numel(d.flipNumber), numel(callTime));
 rows = (numel(d.flipNumber) - n + 1):numel(d.flipNumber);
 ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
 pres   = d.actualTimestamp(rows(ok));
 anch   = anchorUsed(ok);
 ct     = callTime(ok);
 cp     = callPhase(ok);

 % Boundaries from the anchor to the presentation, and to the call. Both are
 % measured against the same confirmed reference, so neither can drift.
 presB = (pres - anch) / period;
 callB = (ct   - anch) / period;

 fprintf('\n%-10s %12s %12s %12s %10s\n', ...
     'phase', 'call(refr)', 'pres(refr)', 'call->pres', 'n');
 up = unique(cp);
 medPres = nan(numel(up),1); medCall = nan(numel(up),1); medMs = nan(numel(up),1);
 for pi = 1:numel(up)
  sel = cp == up(pi);
  if ~any(sel), continue; end
  medCall(pi) = median(callB(sel));
  medPres(pi) = median(presB(sel));
  medMs(pi)   = median(pres(sel) - ct(sel)) * 1000;
  fprintf('%-10.3f %12.3f %12.3f %12.3f %10d\n', ...
      up(pi), medCall(pi), medPres(pi), medMs(pi), sum(sel));
 end

 valid = isfinite(medPres);
 [bestMs, bi] = min(medMs(valid));
 upv = up(valid);
 steps = find(diff(round(medPres(valid))) ~= 0);

 fprintf('\nFastest: phase %.3f gives call->presentation %.3f ms (%.3f refreshes).\n', ...
     upv(bi), bestMs, bestMs/(period*1000));
 if isempty(steps)
  fprintf(['Presentation boundary does not change with phase: a fixed queue\n' ...
      'depth, not a deadline the application can meet.\n']);
  cutoff = NaN; safePhase = upv(bi);
 else
  cutoff = upv(steps(1));
  % Back off from the cliff by ~10%% of a refresh for jitter margin.
  safePhase = max(0.05, cutoff - 0.10);
  fprintf(['Boundary changes at phase %.3f (%.3f ms into the refresh).\n' ...
      'That is the deadline. Recommended working phase %.3f, which keeps\n' ...
      '%.2f ms of margin before the cliff.\n'], ...
      cutoff, cutoff*period*1000, safePhase, (cutoff-safePhase)*period*1000);
 end

 report = struct('ifi', ifi, 'gridPeriod', period, 'phases', up, ...
     'drawables', drawables, ...
     'callRefreshes', medCall, 'presRefreshes', medPres, ...
     'callToPresentMs', medMs, 'cutoffPhase', cutoff, ...
     'recommendedPhase', safePhase, 'bestCallToPresentMs', bestMs, ...
     'bestCallToPresentRefreshes', bestMs/(period*1000), ...
     'summary', d.summary);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
