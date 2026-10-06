function report = PsychMetalCallerSleepProbe(framesPerGap, maxGap)
% PsychMetalCallerSleepProbe  Schedule by sleeping, not by asking.
%
%   report = PsychMetalCallerSleepProbe(120, 8)
%
% ANSWERED IN 0.3.1. THE MECHANISM THIS PROBE PROPOSED WAS MEASURED AND
% REJECTED. Read the recommendation below as a record of a wrong turn, not as
% advice.
%
% The question was this. A request exactly four refreshes ahead was presented
% one refresh late on 97 to 99% of frames, while every other cadence from 1 to 8
% was exact. Five candidate causes had been measured and eliminated. `Flip`
% then resolved `when` to a boundary itself, slept until 1.5 refreshes before
% it, committed, and passed atTime as a floor — two scheduling mechanisms
% stacked, ours and Apple's. This probe removed Apple's: the CALLER sleeps to
% the same moment and issues an ORDINARY unscheduled flip, leaving only ours.
%
% The reasoning was that the grid is exact, so there is nothing to negotiate,
% and knowing the boundary is enough to know when to submit. That reasoning is
% wrong, and this probe is where it was tested most directly:
%
%   our commit timing decides the boundary, plain present       99% late
%   Apple decides, but we sleep to within four refreshes        96% late
%   Apple alone; commit immediately, no sleep at all             1% late
%
% Caller-side sleeping is the first arm. The fix was to delete our scheduling
% entirely and let presentDrawable:atTime: place the frame, because it knows
% the display's schedule and every frame already queued against it, and we were
% computing an approximation of something the system already knew.
%
% Kept because the arm it measures is the one a caller would most naturally
% write for themselves, and this is the evidence for why not to. See
% docs/05_results.md section 9e.
%
% Frames are compared against the SAME boundary definition as
% PsychMetalScheduleSweep, so the two are directly comparable.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(framesPerGap), framesPerGap = 120; end
if nargin < 2 || isempty(maxGap), maxGap = 8; end
w = [];

try
 [w, rect, ifi] = PsychMetal('OpenWindow');
 PsychMetal('HideCursor');

 gaps = 1:maxGap;
 nG = numel(gaps);
 lateFrac = nan(1,nG); medErr = nan(1,nG); spread = nan(1,nG);
 committed = nan(1,nG);

 for k = 1:120
  PsychMetal('FillRect', w, 51);
  vbl = PsychMetal('Flip', w);
 end

 fprintf('\n%d frames per gap, gaps 1 to %d, caller-side sleep. About %.0f s.\n', ...
     framesPerGap, maxGap, sum(gaps)*framesPerGap*ifi);

 for gi = 1:nG
  g = gaps(gi);
  dBefore = PsychMetal('Diagnostic', w);
  before = numel(dBefore.actualStatus);
  tgts = nan(framesPerGap,1);

  for k = 1:framesPerGap
   % The boundary we want, g refreshes after the last presentation.
   target = vbl + g * ifi;
   tgts(k) = target;
   % Sleep to the same moment the library would have committed at: 1.5
   % refreshes before the boundary, which is the middle of cycle N-2.
   PsychMetal('WaitSecs', 'UntilTime', target - 1.5 * ifi);
   PsychMetal('FillRect', w, 51);
   PsychMetal('FillRect', w, 230, ...
       [rect(3)*0.4, rect(4)*0.4, rect(3)*0.6, rect(4)*0.6]);
   % ORDINARY flip. No `when`, so none of the scheduling path runs.
   vbl = PsychMetal('Flip', w);
  end

  d = PsychMetal('Diagnostic', w);
  rows = (before+1):numel(d.actualStatus);
  n = min(numel(rows), framesPerGap);
  rows = rows(1:n);
  ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
  if ~any(ok), continue; end

  err = (d.actualTimestamp(rows) - tgts(1:n)) / ifi;
  medErr(gi) = median(err(ok));
  lateFrac(gi) = mean(err(ok) > 0.5);
  spread(gi) = max(err(ok)) - min(err(ok));
  if isfield(d, 'committedTime')
   c = d.committedTime(rows);
   sel = ok & isfinite(c) & c > 0;
   if any(sel), committed(gi) = median((c(sel) - tgts(sel)) / ifi); end
  end
 end

 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 report = struct('ifi', ifi, 'gaps', gaps, 'framesPerGap', framesPerGap, ...
     'committedRef', committed, 'medianError', medErr, ...
     'lateFraction', lateFrac, 'spreadRef', spread);

 fprintf('\n===== caller sleeps, then flips with no `when` =====\n');
 fprintf('%5s %11s %11s %8s %9s\n', 'gap', 'committed', 'median err', 'late', 'spread');
 for gi = 1:nG
  fprintf('%5d %11.3f %11.3f %7.0f%% %9.3f\n', gaps(gi), ...
      committed(gi), medErr(gi), 100*lateFrac(gi), spread(gi));
 end

 fprintf(['\nCaller-side sleeping was measured at 96%% late for a four-refresh\n' ...
     'cadence, against 1%% for committing immediately and letting\n' ...
     'presentDrawable:atTime: place the frame. Expect this table to look\n' ...
     'worse than PsychMetalScheduleSweep; that is the result, not a fault.\n' ...
     'Computing the boundary yourself and sleeping to it is the natural\n' ...
     'thing to write and it is slower than asking. See 05_results.md 9e.\n']);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
