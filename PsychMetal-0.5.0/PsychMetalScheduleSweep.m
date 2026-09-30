function report = PsychMetalScheduleSweep(framesPerGap, maxGap, drawables, confirm)
% PsychMetalScheduleSweep  Which requested cadences land on their boundary?
%
%   report = PsychMetalScheduleSweep(120, 8)
%
% Every requested cadence should land on the boundary it asked for. This checks
% that, and it is the test that found the scheduled-presentation defect fixed in
% 0.3.1: a request exactly four refreshes ahead was presented a refresh late on
% 97 to 99%% of frames while every other cadence was exact.
%
% The cause was that the library scheduled at all. Committing immediately and
% letting presentDrawable:atTime: place the frame gives 0 to 1%% late across
% cadences 1 to 12. See docs/05_results.md section 9e.
%
% Two tables. Where each cadence landed:
%
%   committed   how far ahead of the requested boundary the frame was committed
%   projected   what Flip told the caller
%   actual      where it landed, 0 on target and +1 a refresh late
%   late        fraction of frames a refresh or more late
%
% And the request's own position, as a check that the arms are comparable: the
% offset from the previous confirmed presentation minus the g-0.5 it was built
% with. Zero means the request is where it was meant to be. A non-zero value
% means the loop has been thrown off, and since `when` is computed from the
% timestamp Flip returned, a persistent offset there is self-sustaining.
%
% Optional third argument sets the drawable count, fourth turns on
% waitForConfirm so requests anchor on confirmed presentations rather than on
% predictions. Both were added to test hypotheses about the defect above; both
% turned out not to be the cause, and both are kept because they are cheap.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(framesPerGap), framesPerGap = 120; end
if nargin < 2 || isempty(maxGap), maxGap = 8; end
if nargin < 3 || isempty(drawables), drawables = []; end
if nargin < 4 || isempty(confirm), confirm = false; end

% CONFIRM BREAKS A SELF-REFERENCE, and that may be the whole story.
%
% The loop computes the next request from the timestamp Flip returned, which is
% a PREDICTION. For the gap-4 arm that prediction sits one refresh before the
% frame actually appeared, so the request lands 2.5 refreshes after the last
% real presentation - the same place as gap 3, which is exact - and yet
% resolves to a different boundary. Once the arm is in that state it sustains
% itself: every frame is offset by the same refresh, the cadence stays 4, and
% nothing pulls it back.
%
% With waitForConfirm the returned timestamp is the CONFIRMED presentation, so
% requests are anchored on what actually happened. If gap 4 behaves then, the
% anomaly was the loop feeding its own prediction back into its schedule, and
% the fix is to stop callers doing that. If gap 4 still fails, the self-
% reference is innocent and something in the pipeline really does treat a
% four-refresh request differently.
w = [];

% DRAWABLE COUNT IS A PARAMETER because of one specific prediction. With three
% drawables, a request exactly FOUR refreshes ahead lands a refresh late, and
% nothing else does. Four is drawableCount + 1. If that is the relationship,
% opening with two drawables should move the failure to gap 3. If gap 4 still
% fails at two drawables, the pool size is irrelevant and the coincidence was
% just a coincidence.

try
 [w, rect, ifi] = PsychMetal('OpenWindow', [], [], drawables, confirm);
 PsychMetal('HideCursor');
 if isempty(drawables), dtxt = 'default (3)'; else, dtxt = sprintf('%d', drawables); end
 if confirm, ctxt = 'confirmed'; else, ctxt = 'predicted'; end

 gaps = 1:maxGap;
 nG = numel(gaps);
 committed = nan(1,nG); projected = nan(1,nG); actual = nan(1,nG);
 lateFrac = nan(1,nG); spread = nan(1,nG);
 % Margin against the REAL grid. The request is built as vbl + (g-0.5)*ifi
 % from the projected timestamp, i.e. half a refresh past a boundary of the
 % FITTED grid. Measured instead against the previous CONFIRMED presentation,
 % it should still sit at g-0.5. If the fitted grid has drifted, this moves,
 % and once it reaches 0 or 1 the request crosses into a different boundary.
 % That is the only hypothesis left for why the affected cadences change
 % between runs, and it is either visible here or it is wrong.
 marginMed = nan(1,nG); marginMin = nan(1,nG); marginMax = nan(1,nG);

 % Warm up so the refresh grid is fitted before anything is scheduled.
 for k = 1:120
  PsychMetal('FillRect', w, 51);
  vbl = PsychMetal('Flip', w);
 end

 fprintf(['\n%d frames per gap, gaps 1 to %d, %s drawables. ' ...
     'Anchor %s. About %.0f seconds.\n'], ...
     framesPerGap, maxGap, dtxt, ctxt, sum(gaps)*framesPerGap*ifi);

 for gi = 1:nG
  g = gaps(gi);
  dBefore = PsychMetal('Diagnostic', w);
  before = numel(dBefore.actualStatus);
  reqTimes = nan(framesPerGap,1);

  for k = 1:framesPerGap
   PsychMetal('FillRect', w, 51);
   PsychMetal('FillRect', w, 230, ...
       [rect(3)*0.4, rect(4)*0.4, rect(3)*0.6, rect(4)*0.6]);
   % Half-refresh offset, exactly as PsychMetalWhenTest does, so the boundary
   % the request implies is unambiguous.
   when = vbl + (g - 0.5) * ifi;
   reqTimes(k) = when;
   vbl = PsychMetal('Flip', w, when);
  end

  d = PsychMetal('Diagnostic', w);
  rows = (before+1):numel(d.actualStatus);
  n = min(numel(rows), framesPerGap);
  rows = rows(1:n);
  ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows)) & ...
       isfinite(d.committedTime(rows)) & d.committedTime(rows) > 0;
  if ~any(ok), continue; end

  tgt = reqTimes(1:n) + 0.5*ifi;          % boundary the request implies
  ar = (d.actualTimestamp(rows) - tgt) / ifi;
  % Requested offset from the previous confirmed presentation, minus the
  % g-0.5 it was supposed to be. Zero means the fitted grid still agrees with
  % the display; +-0.5 means the request has drifted onto a boundary.
  prevActual = d.actualTimestamp(rows - 1);
  mg = (reqTimes(1:n) - prevActual) / ifi - (g - 0.5);
  mg = mg(ok & isfinite(prevActual) & prevActual > 0);
  if ~isempty(mg)
   marginMed(gi) = median(mg); marginMin(gi) = min(mg); marginMax(gi) = max(mg);
  end
  committed(gi) = median((d.committedTime(rows(ok)) - tgt(ok)) / ifi);
  projected(gi) = median((d.projectedTimestamp(rows(ok)) - tgt(ok)) / ifi);
  actual(gi)    = median(ar(ok));
  lateFrac(gi)  = mean(ar(ok) > 0.5);
  spread(gi)    = max(ar(ok)) - min(ar(ok));
 end

 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 report = struct('ifi', ifi, 'gaps', gaps, 'framesPerGap', framesPerGap, ...
     'committedRef', committed, 'projectedRef', projected, ...
     'actualRef', actual, 'lateFraction', lateFrac, 'spreadRef', spread, ...
     'drawables', drawables, 'confirm', confirm, ...
     'marginMedian', marginMed, 'marginMin', marginMin, 'marginMax', marginMax);

 fprintf('\n===== requested cadence versus where the frame landed =====\n');
 fprintf('%5s %11s %11s %9s %8s %8s\n', ...
     'gap', 'committed', 'projected', 'actual', 'late', 'spread');
 for gi = 1:nG
  fprintf('%5d %11.3f %11.3f %9.3f %7.0f%% %8.3f\n', gaps(gi), ...
      committed(gi), projected(gi), actual(gi), 100*lateFrac(gi), spread(gi));
 end

 fprintf('\nRequest offset from the previous CONFIRMED presentation, minus the\n');
 fprintf('intended g-0.5. Zero means the fitted grid still agrees with the\n');
 fprintf('display; approaching -0.5 or +0.5 means the request has drifted onto\n');
 fprintf('a boundary and will cross it.\n');
 fprintf('%5s %10s %10s %10s %8s\n', 'gap', 'median', 'min', 'max', 'late');
 for gi = 1:nG
  fprintf('%5d %10.3f %10.3f %10.3f %7.0f%%\n', gaps(gi), ...
      marginMed(gi), marginMin(gi), marginMax(gi), 100*lateFrac(gi));
 end

 fprintf(['\nAll figures are refreshes relative to the boundary the request\n' ...
     'implies. actual 0 means the frame landed where it was asked to;\n' ...
     '+1 means a refresh late. committed is the same for every gap if the\n' ...
     'submission path is behaving identically, which is what makes any\n' ...
     'difference in actual attributable to the cadence rather than to when\n' ...
     'the frame was handed over.\n']);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
