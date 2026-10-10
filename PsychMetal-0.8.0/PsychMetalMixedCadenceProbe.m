function report = PsychMetalMixedCadenceProbe(frames, maxGap)
% PsychMetalMixedCadenceProbe  Is it the request, or the rhythm it sits in?
%
%   report = PsychMetalMixedCadenceProbe(600, 8)
%
% ANSWERED IN 0.3.1: NEITHER. The four-refresh failure this was built to
% characterise came from the library scheduling at all, and it is gone.
%
% The question was this. PsychMetalScheduleSweep holds the cadence constant
% within an arm, so it could not distinguish two very different things:
%
%   the REQUEST   asking for a boundary four refreshes ahead was what failed,
%                 whatever came before it
%   the RHYTHM    a loop running steadily at that cadence was what failed, and
%                 any individual request in it inherited the problem
%
% Here the gap is drawn at random for every frame, so a four-refresh request
% arrives inside a sequence of unrelated ones and never establishes a rhythm.
% Results are grouped by the requested gap.
%
% It answered REQUEST: gap 4 failed at the same rate inside a randomised
% sequence, which eliminated the rhythm and every property of the preceding
% request. That was a real result and it is why the search moved off the
% pipeline and onto our own scheduling code, where the cause turned out to be.
% See docs/05_results.md section 9e.
%
% Still useful as a regression test, and stronger than the constant-cadence
% sweep for the purpose: every gap should now be near zero late, and a
% randomised sequence is the harder case. If a gap is ever singled out again,
% run this before believing anything about the pipeline.
%
% Each frame also records the PREVIOUS gap, so the same data answers a second
% question: whether failure depends on what was asked for last time rather than
% this time. That is reported as a matrix when there are enough samples.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(frames), frames = 600; end
if nargin < 2 || isempty(maxGap), maxGap = 8; end
w = [];

try
 [w, rect, ifi] = PsychMetal('OpenWindow');
 PsychMetal('HideCursor');

 % Deterministic sequence, so a rerun asks for exactly the same thing. The
 % point is to remove RHYTHM, not to introduce randomness as a variable.
 rand('seed', 20260821);
 gapSeq = 1 + floor(rand(1, frames) * maxGap);

 for k = 1:120
  PsychMetal('FillRect', w, 51);
  vbl = PsychMetal('Flip', w);
 end

 dBefore = PsychMetal('Diagnostic', w);
 before = numel(dBefore.actualStatus);
 reqTimes = nan(frames,1);

 fprintf('\n%d frames, gaps drawn from 1 to %d. About %.0f seconds.\n', ...
     frames, maxGap, sum(gapSeq)*ifi);

 for k = 1:frames
  PsychMetal('FillRect', w, 51);
  PsychMetal('FillRect', w, 230, ...
      [rect(3)*0.4, rect(4)*0.4, rect(3)*0.6, rect(4)*0.6]);
  when = vbl + (gapSeq(k) - 0.5) * ifi;
  reqTimes(k) = when;
  vbl = PsychMetal('Flip', w, when);
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 rows = (before+1):numel(d.actualStatus);
 n = min(numel(rows), frames);
 rows = rows(1:n);
 ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
 tgt = reqTimes(1:n) + 0.5*ifi;
 err = (d.actualTimestamp(rows) - tgt) / ifi;
 g = gapSeq(1:n)';
 gPrev = [NaN; g(1:end-1)];

 gaps = 1:maxGap;
 cnt = zeros(1,maxGap); lateFrac = nan(1,maxGap); medErr = nan(1,maxGap);
 for gi = gaps
  sel = ok & g == gi;
  cnt(gi) = sum(sel);
  if cnt(gi) > 0
   lateFrac(gi) = mean(err(sel) > 0.5);
   medErr(gi) = median(err(sel));
  end
 end

 report = struct('ifi', ifi, 'frames', n, 'maxGap', maxGap, ...
     'gapSequence', gapSeq(1:n), 'errorRefreshes', err, 'confirmed', ok, ...
     'count', cnt, 'lateFraction', lateFrac, 'medianError', medErr);

 fprintf('\n===== gap requested, inside a randomised sequence =====\n');
 fprintf('%5s %8s %10s %9s\n', 'gap', 'n', 'median err', 'late');
 for gi = gaps
  fprintf('%5d %8d %10.3f %8.0f%%\n', gi, cnt(gi), medErr(gi), 100*lateFrac(gi));
 end

 % Second question: does the PREVIOUS request predict failure?
 fprintf('\nLate rate by (previous gap, this gap), blank where n < 5:\n');
 fprintf('%9s', 'prev\\this');
 for gi = gaps, fprintf('%6d', gi); end
 fprintf('\n');
 for gp = gaps
  fprintf('%9d', gp);
  for gi = gaps
   sel = ok & g == gi & gPrev == gp;
   if sum(sel) >= 5, fprintf('%5.0f%%', 100*mean(err(sel) > 0.5));
   else, fprintf('%6s', '.'); end
  end
  fprintf('\n');
 end

 fprintf(['\nEvery cell should now be near zero. Before 0.3.1 the gap-4 column\n' ...
     'read 97 to 99%% whatever preceded it, which is how the rhythm was ruled\n' ...
     'out and the search moved onto our own scheduling code. Any column that\n' ...
     'singles itself out again means a cadence is being treated specially, and\n' ...
     'this is the first thing to run: it removes the rhythm, so a failure here\n' ...
     'is a property of the request alone.\n']);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
