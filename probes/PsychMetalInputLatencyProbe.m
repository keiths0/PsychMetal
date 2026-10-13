function report = PsychMetalInputLatencyProbe(frames, drawables)
% PsychMetalInputLatencyProbe  Where the drawable wait sits in the frame.
%
%   report = PsychMetalInputLatencyProbe(300)
%   report = PsychMetalInputLatencyProbe(300, 2)
%
% The presentation pipeline is not what makes a mouse-tracked stimulus feel
% late. Commit-to-presented is about one refresh at two drawables and two at
% three, and the frame always makes the boundary it is aimed at. The latency is
% added BEFORE the commit:
%
%   sample -> draw (3 ms) -> Flip [nextDrawable blocks ~12 ms] -> commit
%
% nextDrawable blocks until the pool frees a drawable. Called at the start of
% Flip, that wait falls between the sample and the commit, so the pointer
% position is about a refresh old on arrival. Measured: 0.942 refreshes from
% sample to commit against 0.975 from commit to photons, so half the total was
% the loop standing still holding a stale sample.
%
% GetMouse costs 0.7 ms and is not the problem.
%
% The wait cannot be removed; two frames cannot share one drawable. Its POSITION
% can move. Three arms:
%
%   early     sample at the top of the loop
%   late      sample after WaitToDraw, which sleeps on a PREDICTED time without
%             taking a drawable. That is why it barely helps: the pool is still
%             empty when Flip runs.
%   prefetch  acquire the next frame's drawable at the END of Flip, so the block
%             lands before the next sample instead of after it.
%
% Measured, 3 drawables: prefetch took dwait from 12.35 ms to 0.11 and
% sample-to-presented from 2.948 refreshes to 1.960, at 60.000/s with no skips.
% At 2 drawables prefetch starves the pool instead, holding one of two so that
% nothing is left to pipeline against: 30.000/s with 299 of 300 intervals
% skipped. Prefetch needs a third drawable, which is why the two are tied
% together in PsychMetal('OpenWindow').
%
% Reported per arm:
%
%   PIPELINE          commit -> presented, the compositor's own latency
%   dwait             time blocked in nextDrawable inside Flip
%   sample->pres      what an observer actually experiences
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(frames), frames = 300; end
if nargin < 2 || isempty(drawables), drawables = []; end
w = [];

names = {'early sample', 'late sample (WaitToDraw)', 'prefetched drawable'};
useLate = [false true  false];
usePre  = [false false true ];
order = [1 2 3 3 2 1];

try
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen, [], drawables);
 PsychMetal('HideCursor');
 W = rect(3); H = rect(4);
 half = min(W, H) * 0.06;

 nArm = numel(names);
 hz = nan(nArm,2); skip = nan(nArm,2);
 leadRef = nan(nArm,2); inputRef = nan(nArm,2); msFlip = nan(nArm,2);
 pipeRef = nan(nArm,2); waitMs = nan(nArm,2);
 pass = zeros(1,nArm);

 if isempty(drawables), dtxt = 'default'; else, dtxt = sprintf('%d', drawables); end
 fprintf('\n%d frames per arm, %d arms, %s drawables. Move the mouse.\n', ...
     frames, numel(order), dtxt);

 for a = order
  pass(a) = pass(a) + 1; p = pass(a);
  tSample = nan(frames,1); tFlip = zeros(frames,1);

  PsychMetal('PrefetchDrawable', w, usePre(a));
  dBefore = PsychMetal('Diagnostic', w);
  before = numel(dBefore.actualStatus);
  vbl = PsychMetal('GetSecs') + ifi;

  for k = 1:(frames + 60)
   j = k - 60; rec = k > 60;

   if useLate(a)
    % Sleep until the last moment that still makes the next boundary. The
    % budget must cover the drawing that follows, or the frame is late.
    PsychMetal('WaitToDraw', w, vbl + ifi, 0.005);
   end
   t1 = PsychMetal('GetSecs');
   if rec, tSample(j) = t1; end
   [mx, my] = PsychMetal('GetMouse', w);
   x = min(max(mx, 0), W); y = min(max(my, 0), H);

   PsychMetal('FillRect', w, [26 28 36]);
   PsychMetal('FillRect', w, [242 89 64], ...
       [x-half, y-half, x+half, y+half]);
   t2 = PsychMetal('GetSecs');
   vbl = PsychMetal('Flip', w);
   t3 = PsychMetal('GetSecs');
   if rec, tFlip(j) = (t3-t2)*1000; end
  end

  d = PsychMetal('Diagnostic', w);
  st = PsychMetalFrameStats(d, ifi, before + 60);
  hz(a,p) = st.achievedHz; skip(a,p) = st.skipped;
  leadRef(a,p) = st.leadRefreshes;
  pipeRef(a,p) = st.pipelineRefreshes;
  waitMs(a,p) = st.drawableWaitMs;
  msFlip(a,p) = median(tFlip);

  rows = (before+61):numel(d.actualStatus);
  nrows = min(numel(rows), frames);
  rows = rows(1:nrows);
  okr = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
  samp = tSample(1:nrows);
  inputRef(a,p) = median(d.actualTimestamp(rows(okr)) - samp(okr)) / ifi;
 end

 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 report = struct('ifi', ifi, 'frames', frames, 'names', {names}, ...
     'drawables', drawables, 'useLate', useLate, 'usePrefetch', usePre, ...
     'achievedHz', hz, 'skipped', skip, 'msFlip', msFlip, ...
     'leadRefreshes', leadRef, 'inputRefreshes', inputRef, ...
     'pipelineRefreshes', pipeRef, 'drawableWaitMs', waitMs, ...
     'savedRefreshes', mean(inputRef(1,:)) - mean(inputRef(3,:)));

 fprintf('\n===== where the input sample sits in the frame =====\n');
 fprintf('%-26s %8s %8s %9s %9s %10s %10s\n', 'arm', 'Hz', 'skipped', ...
     'Flip ms', 'dwait ms', 'PIPELINE', 'sample->pres');
 for a = 1:nArm
  fprintf('%-26s %8.3f %8.0f %9.2f %9.2f %10.3f %10.3f\n', names{a}, ...
      mean(hz(a,:)), mean(skip(a,:)), mean(msFlip(a,:)), mean(waitMs(a,:)), ...
      mean(pipeRef(a,:)), mean(inputRef(a,:)));
 end
 fprintf(['PIPELINE is commit->presented in refreshes, the N+2 figure.\n' ...
     'dwait is time inside Flip waiting for a free drawable, which the old\n' ...
     'submit->pres number wrongly charged to the pipeline.\n']);

 fprintf('\nPrefetching saved %.3f refreshes (%.2f ms) of input latency.\n', ...
     report.savedRefreshes, report.savedRefreshes * ifi * 1000);
 fprintf(['PIPELINE should be about equal across arms: none of these change\n' ...
     'what the compositor does. If prefetch shows a near-zero dwait and a\n' ...
     'lower sample->pres at the SAME rate and skip count, the latency was\n' ...
     'the position of the wait. If its skip count rises instead, the pool is\n' ...
     'too small to spare a drawable and the window needs three.\n']);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
