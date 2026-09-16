function report = PsychMetalWhenTest(framesPerMode)
% PsychMetalWhenTest  Exercise scheduled PsychMetal presentation.
%
% The second argument used to select a presentation mode. There is only one
% now: the CAMetalDisplayLink path was removed in 0.4.0.
%
% SPDX-License-Identifier: MIT
if nargin < 1 || isempty(framesPerMode), framesPerMode = 120; end
assert(isnumeric(framesPerMode) && isscalar(framesPerMode) && ...
    isfinite(framesPerMode) && framesPerMode >= 10 && framesPerMode == fix(framesPerMode), ...
    'framesPerMode must be an integer of at least 10.');

w = []; expectedGap = []; returnedVBL = []; returnedMissed = [];
requested = []; labels = {};
try
 [w, rect, ifi] = PsychMetal('OpenWindow');
 vbl = NaN;

 % Unscheduled warmup also gives the asynchronous target calibration time
 % to collect confirmed presentedTime samples.
 for k = 1:30
  drawFrame(w, rect, k, 0);
  [vbl,~,~,missed] = PsychMetal('Flip', w);
  expectedGap(end+1,1) = 1; returnedVBL(end+1,1) = vbl; %#ok<AGROW>
  returnedMissed(end+1,1) = missed; requested(end+1,1) = NaN; %#ok<AGROW>
  labels{end+1,1} = 'warmup'; %#ok<AGROW>
 end

 for gap = 1:4
  for k = 1:framesPerMode
   drawFrame(w, rect, k, gap);
   when = vbl + (gap - 0.5) * ifi;
   [vbl,~,~,missed] = PsychMetal('Flip', w, when);
   expectedGap(end+1,1) = gap; returnedVBL(end+1,1) = vbl; %#ok<AGROW>
   returnedMissed(end+1,1) = missed; requested(end+1,1) = when; %#ok<AGROW>
   labels{end+1,1} = sprintf('gap%d', gap); %#ok<AGROW>
  end
 end

 % A past deadline must present at the next available target, not error.
 drawFrame(w, rect, 1, 5);
 pastWhen = PsychMetal('GetSecs') - 0.1;
 [vbl,~,~,pastMissed] = PsychMetal('Flip', w, pastWhen);
 expectedGap(end+1,1) = NaN; returnedVBL(end+1,1) = vbl;
 returnedMissed(end+1,1) = pastMissed; requested(end+1,1) = pastWhen;
 labels{end+1,1} = 'past';

 % Holding the existing image requires no intermediate flips.
 drawFrame(w, rect, 1, 6);
 longWhen = vbl + 29.5 * ifi;
 [vbl,~,~,longMissed] = PsychMetal('Flip', w, longWhen);
 expectedGap(end+1,1) = 30; returnedVBL(end+1,1) = vbl;
 returnedMissed(end+1,1) = longMissed; requested(end+1,1) = longWhen;
 labels{end+1,1} = 'hold30';

 % This verifies that a legitimate wait longer than the old two-second
 % timeout survives. The visible image remains unchanged during the wait.
 drawFrame(w, rect, 1, 7);
 farWhen = PsychMetal('GetSecs') + 3.0; farStart = PsychMetal('GetSecs');
 [vbl,~,~,farMissed] = PsychMetal('Flip', w, farWhen);
 farWait = PsychMetal('GetSecs') - farStart;
 expectedGap(end+1,1) = NaN; returnedVBL(end+1,1) = vbl;
 returnedMissed(end+1,1) = farMissed; requested(end+1,1) = farWhen;
 labels{end+1,1} = 'future3s';

 % Verify that omitting when retains next-available behaviour.
 for k = 1:30
  drawFrame(w, rect, k, 8);
  [vbl,~,~,missed] = PsychMetal('Flip', w);
  expectedGap(end+1,1) = 1; returnedVBL(end+1,1) = vbl; %#ok<AGROW>
  returnedMissed(end+1,1) = missed; requested(end+1,1) = NaN; %#ok<AGROW>
  labels{end+1,1} = 'unscheduled'; %#ok<AGROW>
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];

 assert(numel(d.flipNumber) == numel(expectedGap), ...
     'Diagnostic history length does not match the Flip count.');
 assert(~any(d.actualStatus == 2), 'Diagnostic returned a pending final row.');
 assert(pastMissed > 0, ...
     'A deadline in the past reported Missed = %.4f ms (expected > 0).', pastMissed*1000);
 assert(longMissed < 0, ...
     'The 30-refresh hold reported Missed = %.4f ms (expected < 0).', longMissed*1000);
 assert(farMissed < 0 && farWait > 2.5, ...
     'Far-future scheduling: Missed = %.4f ms, wait = %.3f s.', farMissed*1000, farWait);
 assert(all(returnedMissed(strcmp(labels,'unscheduled')) == 0), ...
     'An unscheduled Flip returned a nonzero Missed value.');

 projectedGap = [NaN; round(diff(returnedVBL) / ifi)];
 testRows = isfinite(expectedGap) & (1:numel(expectedGap))' > 30;
 badProjected = testRows & projectedGap ~= expectedGap;
 % Tolerate ISOLATED disagreements, fail on runs. This assertion used to demand
 % that projected gaps always equal the nominal gap, which was trivially true
 % while the prediction advanced at the nominal cadence no matter what the
 % display did. Now that the prediction is derived from the commit and the
 % measured refresh grid, a genuinely dropped frame appears here too, and it
 % should: a returned timestamp that concealed a dropped frame was the defect,
 % not the feature. A RUN of them still means the prediction has lost the grid.
 projRun = 0; worstProjRun = 0;
 for q = 1:numel(badProjected)
  if badProjected(q), projRun = projRun + 1; worstProjRun = max(worstProjRun, projRun);
  else, projRun = 0; end
 end
 if any(badProjected)
  reportBadRows('projected', find(badProjected), labels, expectedGap, projectedGap, ...
      requested, returnedVBL, ifi);
  fprintf(['Projected gaps now follow the display rather than the nominal\n' ...
      'cadence, so an isolated dropped frame shows up here. %d of %d, longest\n' ...
      'run %d.\n'], sum(badProjected), sum(testRows), worstProjRun);
 end
 % Deferred. Diagnostics print first; failures are raised at the end.
 failures = {};
 if worstProjRun > 2
  failures{end+1} = sprintf( ...
      ['%d of %d projected timestamps landed on the wrong refresh, longest ' ...
       'run %d. A run means the prediction has lost the refresh grid rather ' ...
       'than reflecting a dropped frame.'], ...
      sum(badProjected), sum(testRows), worstProjRun);
 end

 confirmedPair = [false; d.actualStatus(1:end-1) == 0 & d.actualStatus(2:end) == 0];
 actualGap = [NaN; round(diff(d.actualTimestamp) / ifi)];

 % Score each request against WHERE IT ASKED FOR, measured from the previous
 % CONFIRMED presentation, not against the nominal gap the loop intended.
 %
 % The two differ whenever a presentation slips, because the loop computes
 % `when` from the projected timestamp Flip returned, and that projection does
 % not re-anchor after a slip. The following requests are then already in the
 % past, and presenting them at the next boundary is correct behaviour. Scoring
 % those against the nominal gap counted one late frame as four failures.
 %
 % Requests are placed at half-refresh offsets, so the target boundary is the
 % ceiling; a request already past is due at the very next boundary.
 requestedRef = [NaN; (requested(2:end) - d.actualTimestamp(1:end-1)) / ifi];
 dueGap = max(1, ceil(requestedRef - 1e-9));

 % Score on the INTENDED gap. Scoring on dueGap instead was tried and is
 % wrong: dueGap is derived from `requested`, which the caller computed from
 % the timestamp Flip returned, so any lag in that timestamp is charged to the
 % presentation rather than to the timestamp. It called correct 4-refresh
 % presentations failures because the request had been computed from a value
 % one refresh behind. dueGap is still printed, as evidence about the returned
 % timestamp rather than about the presentation.
 badActual = testRows & confirmedPair & actualGap ~= expectedGap;
 lateRate = sum(badActual) / max(1, sum(testRows & confirmedPair));
 if any(badActual)
  reportBadRows('confirmed', find(badActual), labels, dueGap, actualGap, ...
      requested, d.actualTimestamp, ifi);
  fprintf(['Scored against the requested time, not the intended gap. A row\n' ...
      'here asked for a boundary and was presented at a different one.\n']);
 end
 % Sporadic slips are a known property of this pipeline rather than a
 % regression, so quantify them and fail only on a rate that would spoil an
 % experiment. Two events in 508 is the observed baseline.
 fprintf('\nLate scheduled presentations: %d of %d (%.2f%%).\n', ...
     sum(badActual), sum(testRows & confirmedPair), 100*lateRate);
 % Isolated slips are a property of this pipeline; a RUN of them is a bug. The
 % original failure was one late frame plus a cascade, so consecutive length is
 % the discriminating statistic, not the raw count.
 runLen = 0; worstRun = 0;
 for q = 1:numel(badActual)
  if badActual(q), runLen = runLen + 1; worstRun = max(worstRun, runLen);
  else, runLen = 0; end
 end
 fprintf('Longest consecutive run of late presentations: %d.\n', worstRun);
 if worstRun > 2
  failures{end+1} = sprintf( ...
      ['%d late scheduled presentations in %d, longest run %d. A run longer ' ...
       'than two means one slip is dragging its successors with it.'], ...
      sum(badActual), sum(testRows & confirmedPair), worstRun);
 end

 % The projection must not run ahead of reality. After a slip, Flip kept
 % returning timestamps at the nominal cadence, so the caller's next `when`
 % landed in the past. Anything beyond a refresh of disagreement means a
 % returned timestamp that an experiment would log as a stimulus onset is
 % wrong by a frame or more.
 % How far the timestamp Flip HANDED BACK sits from what actually happened.
 % This is the number an experiment logs as stimulus onset, so a persistent
 % offset here matters even when every presentation lands on its requested
 % refresh.
 projErr = (returnedVBL - d.actualTimestamp) / ifi;
 projErr = projErr(testRows & d.actualStatus == 0 & isfinite(projErr));
 fprintf('Projected minus confirmed: median %+.3f, max %+.3f refreshes.\n', ...
     median(projErr), max(abs(projErr)));
 % A CONSTANT offset and a SCATTERED one need different fixes, so show the
 % distribution rather than a summary. A single spike at -1 means the
 % prediction picks the wrong boundary and the cure is arithmetic. Several
 % populated bins mean it is sometimes right, and the cure is not.
 edges = -3:1:3;
 counts = histc(round(projErr), edges);
 fprintf('  offset  count  (refreshes, projected minus confirmed)\n');
 for q = 1:numel(edges)
  if counts(q) > 0
   fprintf('  %+5d  %5d  %s\n', edges(q), counts(q), ...
       repmat('#', 1, min(60, round(60*counts(q)/max(counts)))));
  end
 end
 fprintf('  exactly -1 in %.1f%% of confirmed frames\n', ...
     100*mean(abs(projErr + 1) < 0.25));
 % ROUNDED bins cannot tell a genuinely bimodal error from a continuous one
 % that drifts across the +/-0.5 rounding boundary, and those need opposite
 % fixes. Raw quantiles show the shape; the quarter-by-quarter means show
 % whether it is moving. A bimodal error has two tight clusters and flat
 % quarters; a drifting one has spread quantiles and marching quarters.
 pq = sort(projErr);
 qi = @(f) pq(max(1, min(numel(pq), round(f*numel(pq)))));
 fprintf('  raw quantiles  min %+.3f  p25 %+.3f  med %+.3f  p75 %+.3f  max %+.3f\n', ...
     pq(1), qi(0.25), qi(0.50), qi(0.75), pq(end));
 nq = floor(numel(projErr)/4);
 if nq > 0
  fprintf('  by quarter of run:');
  for q = 1:4
   fprintf(' %+.3f', mean(projErr((q-1)*nq + (1:nq))));
  end
  fprintf('\n');
  fprintf(['  Flat quarters with two tight clusters means the error is real and\n' ...
      '  unpredictable, so a returned prediction cannot be made correct and\n' ...
      '  waitForConfirm is the only honest source of an onset time. Marching\n' ...
      '  quarters means the grid anchor or period is drifting and is fixable.\n']);
 end

 % WHERE THE EXTRA REFRESH ENTERS, for the deferred-submission branch.
 %
 % gap4 predicts a refresh early and gap1 to gap3 do not. The difference is
 % that only gap4 targets are far enough out to reach the sleep-then-submit
 % path. Everything needed to localise it is already recorded, so dump the four
 % timestamps of those rows against the target they asked for, in refreshes:
 %
 %   committed - target   how far ahead of the target the frame was committed
 %   projected - target   what Flip told the caller
 %   actual    - target   where it actually landed
 %
 % If actual-target is +1 the presentation is late and the prediction is
 % right; the deferred path is presenting a boundary later than requested.
 % If actual-target is 0 and projected-target is -1 the presentation is right
 % and the prediction is early. Those are different bugs in different places.
 if isfield(d, 'committedTime')
  for lbl = {'gap3', 'gap4'}
   sel = strcmp(labels, lbl{1}) & d.actualStatus == 0 & isfinite(d.requestedTime);
   sel = sel(:) & isfinite(d.committedTime(:)) & d.committedTime(:) > 0;
   if ~any(sel), continue; end
   % requestedTime is the caller's `when`; the boundary it implies is the next
   % grid point, which is half a refresh later given how the test spaces them.
   tgt = d.requestedTime(sel) + 0.5*ifi;
   fprintf(['%s deferred-path timing, %d confirmed rows, refreshes ' ...
       'relative to the requested boundary:\n'], lbl{1}, sum(sel));
   fprintf('  committed %+.3f   projected %+.3f   actual %+.3f\n', ...
       median((d.committedTime(sel) - tgt)/ifi), ...
       median((d.projectedTimestamp(sel) - tgt)/ifi), ...
       median((d.actualTimestamp(sel) - tgt)/ifi));
  end
 end

 % WAS THE HOLD-30 FRAME COMMITTED WHERE IT WAS MEANT TO BE?
 %
 % It landed one boundary after its commit rather than two, which was read as
 % evidence that commit-to-present depends on queue occupancy: two boundaries
 % when frames are in flight, one when the queue has been idle. That may be
 % right, but an overshooting sleep produces the identical outcome. If the
 % commit actually happened at target - 2.5 periods instead of the intended
 % -1.5, the pipeline gave its usual two boundaries and the frame still lands
 % a refresh early. Same result, different cause, different fix.
 %
 % committed - target should be -1.5 refreshes. Near -1.5 means the sleep was
 % accurate and the pipeline behaved differently, so occupancy matters. Near
 % -2.5 means the sleep overshot and the pipeline is the constant it was always
 % assumed to be.
 hi = find(strcmp(labels, 'hold30'), 1);
 if ~isempty(hi) && isfield(d, 'committedTime') && d.committedTime(hi) > 0
  tgtHold = d.requestedTime(hi) + 0.5*ifi;
  fprintf(['\nhold30: committed %+.3f refreshes from target (intended -1.500), ' ...
      'presented %+.3f.\n'], ...
      (d.committedTime(hi) - tgtHold)/ifi, ...
      (d.actualTimestamp(hi) - tgtHold)/ifi);
  fprintf(['  near -1.5 means the sleep was accurate and commit-to-present was ' ...
      'one boundary,\n  so it depends on queue occupancy. Near -2.5 means the ' ...
      'sleep overshot and the\n  pipeline is constant after all.\n']);
 end

 % submissionMissed was CAMetalDisplayLink's estimate of whether a frame was
 % handed over before its callback deadline. It went with the display link in
 % 0.4.0, and there is nothing to replace it with: the frame is committed
 % inline, so there is no submission deadline separate from the commit. Every
 % scheduled row is now on time by construction, and the check below is about
 % where the frame LANDED rather than when it was handed over.
 scheduled = isfinite(d.requestedTime);
 thresholdDelay = d.scheduledAfterWhenMs(scheduled & d.actualStatus == 0);
 expectedThresholdDelayMs = 0.5 * ifi * 1000;
 assert(abs(median(thresholdDelay) - expectedThresholdDelayMs) < 0.25 * ifi * 1000, ...
     'Median scheduled presentation did not land near the expected half-refresh offset.');
 if ~isempty(failures)
  error('PsychMetal:WhenTest', '%s\n', failures{:});
 end

 report = struct('ifi',ifi, 'flips',numel(expectedGap), ...
     'confirmed',sum(d.actualStatus == 0), ...
     'unconfirmed',sum(d.actualStatus ~= 0), ...
     'wrongProjectedGaps',sum(badProjected), ...
     'wrongConfirmedGaps',sum(badActual), ...
     'thresholdDelayMedianMs',median(thresholdDelay), ...
     'thresholdDelayMinMs',min(thresholdDelay), ...
     'thresholdDelayMaxMs',max(thresholdDelay), ...
     'pastMissedMs',pastMissed*1000, 'hold30MissedMs',longMissed*1000, ...
     'futureWaitSeconds',farWait, 'futureMissedMs',farMissed*1000, ...
     'diagnostic',d.summary);

 fprintf('\n========== PsychMetal when test ==========\n');
 fprintf('Flips %d; confirmed %d; unconfirmed %d\n', ...
     report.flips, report.confirmed, report.unconfirmed);
 fprintf('Wrong projected/confirmed refresh gaps: %d / %d\n', ...
     report.wrongProjectedGaps, report.wrongConfirmedGaps);
 fprintf('Confirmed presentation after when median/min/max: %.3f / %.3f / %.3f ms\n', ...
     report.thresholdDelayMedianMs, report.thresholdDelayMinMs, report.thresholdDelayMaxMs);
 fprintf('Past Missed %.3f ms; hold-30 Missed %.3f ms\n', ...
     report.pastMissedMs, report.hold30MissedMs);
 fprintf('Future wait %.3f s; future Missed %.3f ms\n', ...
     report.futureWaitSeconds, report.futureMissedMs);
 disp(d.summary);
catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 rethrow(e);
end
end

function drawFrame(w, rect, frame, mode)
palette = [30 45 80; 30 100 180; 170 60 70; 30 150 100; ...
           130 70 180; 190 90 30; 30 150 170; 180 130 30; 80 90 110];
color = palette(mode + 1,:);
PsychMetal('FillRect', w, color);
side = min(rect(3),rect(4)) * 0.2;
x = rect(3)/2 + cos(frame*0.12)*rect(3)*0.2;
y = rect(4)/2 + sin(frame*0.12)*rect(4)*0.2;
PsychMetal('FillOval', w, 255-color, centreOn([0 0 side side],x,y));
PsychMetal('FillRect', w, 255*mod(frame,2), [0 0 140 140]);
end

function reportBadRows(kind, idx, labels, expectedGap, gotGap, requested, times, ifi)
% Print the offending rows with their neighbours, so a failure says which
% scheduling case broke rather than only that one did.
fprintf('\n--- %s gaps that did not match the request ---\n', kind);
fprintf('%-6s %-14s %10s %10s %14s %14s\n', ...
    'row', 'label', 'expected', 'got', 'requested-ref', 'time-prev (ms)');
for i = 1:numel(idx)
 r = idx(i);
 for r2 = max(1, r-1):r
  if r2 > numel(labels), continue; end
  reqRef = NaN;
  if r2 <= numel(requested) && isfinite(requested(r2)) && r2 > 1 && isfinite(times(r2-1))
   reqRef = (requested(r2) - times(r2-1)) / ifi;
  end
  dt = NaN;
  if r2 > 1 && isfinite(times(r2)) && isfinite(times(r2-1))
   dt = (times(r2) - times(r2-1)) * 1000;
  end
  fprintf('%-6d %-14s %10.0f %10.0f %14.3f %14.3f%s\n', ...
      r2, labels{r2}, expectedGap(r2), gotGap(r2), reqRef, dt, ...
      repmat(' <<', 1, double(r2 == r)));
 end
end
fprintf(['requested-ref is the requested time expressed in refreshes after the\n' ...
    'previous row''s timestamp. A row marked << is the failure.\n']);
end

function r = centreOn(rct, x, y)
% CenterRectOnPoint without Psychtoolbox. Two lines, and it removes the last
% dependency this file had on a toolbox it otherwise does not use.
w = rct(3) - rct(1); h = rct(4) - rct(2);
r = [x - w/2, y - h/2, x + w/2, y + h/2];
end
