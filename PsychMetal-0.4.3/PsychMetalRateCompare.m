function report = PsychMetalRateCompare(measuredFrames, mode)
% PsychMetalRateCompare  Sustained presentation rate with and without capture.
%
%   report = PsychMetalRateCompare(300)             % capture on/off/on
%   report = PsychMetalRateCompare(300, 'drawables') % 2 / 3 / 2 drawables
%
% Every window-related comparison so far measured the latch minimum: the
% call-to-presentation floor from a DRAINED queue. That is not the same question
% as whether a continuous 60 Hz loop holds its rate, and a configuration can
% improve one while damaging the other - lower queue depth means lower latency
% and less tolerance for jitter.
%
% This measures the sustained case. The window sits at CGShieldingWindowLevel in
% every arm, so the geometry is correct throughout.
%
% ABA: baseline, manipulation, baseline again. The repeated baseline bounds how
% much the identical configuration drifts within a session, which is the only
% honest yardstick for the middle run.
%
% Each run discards its own first 120 frames. That is not superstition: the
% refresh-grid estimator needs confirmed presentations before measuredIFI and
% the grid anchor exist, and until they do Flip cannot predict a boundary.
%
% There is deliberately NO discarded warm-up run. One was added on the theory
% that the first run of a session was systematically worst; the first run that
% included it dropped no frames and the run after it dropped three, which
% falsified the theory. See docs/05_results.md section 8.
%
% Do not over-read a single ABA here. Frame drops in this configuration are
% sporadic - 0 to 6 per 300 across runs of identical settings - so one
% comparison cannot resolve a reliability difference of that size.
%
% Note also that this design places the manipulation in the middle position. If
% any position effect exists, that biases the comparison toward the manipulation.
%
% Read the skipped count first. A configuration that drops frames at 60 Hz is
% not usable for stimulus presentation whatever it does for latency.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(measuredFrames), measuredFrames = 300; end
if nargin < 2 || isempty(mode), mode = 'capture'; end
assert(any(strcmpi(mode, {'capture','drawables'})), ...
    'mode must be ''capture'' or ''drawables''.');

if strcmpi(mode, 'drawables')
 % Removing AppKit fullscreen cut sustained submit-to-present from about 2.7
 % refreshes to about 1.8. Each additional drawable then costs exactly one
 % refresh: 1.789 against 2.792 and 1.784 against 2.792 in two runs. Whether the
 % third drawable also buys back the sporadic dropped frame is UNRESOLVED - two
 % three-drawable runs dropped none, five of eight two-drawable runs dropped at
 % least one, and that is not enough to separate from noise.
 names = {'2 drawables', '3 drawables', '2 again'};
 fprintf('\n########## arm 1 of 3: 2 drawables ##########\n');
 a = runArm(measuredFrames, true, 2);
 fprintf('\n########## arm 2 of 3: 3 drawables ##########\n');
 b = runArm(measuredFrames, true, 3);
 fprintf('\n########## arm 3 of 3: 2 drawables again ##########\n');
 c = runArm(measuredFrames, true, 2);
 report = struct('two_first', a, 'three', b, 'two_second', c);
else
 names = {'capture', 'no capture', 'capture'};
 fprintf('\n########## arm 1 of 3: capture ON ##########\n');
 a = runArm(measuredFrames, true, 2);
 fprintf('\n########## arm 2 of 3: capture OFF ##########\n');
 b = runArm(measuredFrames, false, 2);
 fprintf('\n########## arm 3 of 3: capture ON again ##########\n');
 c = runArm(measuredFrames, true, 2);
 report = struct('capture_first', a, 'noCapture', b, 'capture_second', c);
end

fprintf('\n================ sustained rate comparison ================\n');
fprintf('%-30s %12s %12s %12s\n', '', names{1}, names{2}, names{3});
fprintf('%-30s %12.3f %12.3f %12.3f\n', 'rate (Hz, mean interval)', ...
    a.achievedHz, b.achievedHz, c.achievedHz);
fprintf('%-30s %12d %12d %12d\n', 'skipped refreshes', a.skipped, b.skipped, c.skipped);
fprintf('%-30s %12d %12d %12d\n', 'confirmed', a.confirmed, b.confirmed, c.confirmed);
fprintf('%-30s %12.3f %12.3f %12.3f\n', 'submit -> presented (ms)', ...
    a.leadMs, b.leadMs, c.leadMs);
fprintf('%-30s %12.3f %12.3f %12.3f\n', 'in refreshes', ...
    a.leadRefreshes, b.leadRefreshes, c.leadRefreshes);
fprintf('%-30s %12d %12d %12d\n', 'display captured', ...
    a.displayCaptured, b.displayCaptured, c.displayCaptured);

drift = abs(a.skipped - c.skipped);
baseSkip = mean([a.skipped, c.skipped]);
leadDelta = b.leadRefreshes - mean([a.leadRefreshes, c.leadRefreshes]);
fprintf('\nBaseline: %.1f skips, %.3f refreshes lead. Drift between arms: %d skips.\n', ...
    baseSkip, mean([a.leadRefreshes, c.leadRefreshes]), drift);
fprintf('Middle arm: %d skips, %.3f refreshes lead (%+.3f).\n', ...
    b.skipped, b.leadRefreshes, leadDelta);
fprintf('VERDICT: ');
if abs(b.skipped - baseSkip) <= max(1, drift)
 fprintf(['no reliability difference beyond drift between arms. Judge on latency:\n' ...
     'the middle arm costs %+.3f refreshes.\n'], leadDelta);
elseif b.skipped < baseSkip
 fprintf(['the middle arm drops fewer frames (%d against %.1f), at %+.3f refreshes\n' ...
     'of latency. That is the trade.\n'], b.skipped, baseSkip, leadDelta);
else
 fprintf(['the middle arm drops MORE frames (%d against %.1f) for %+.3f refreshes.\n' ...
     'Not worth it.\n'], b.skipped, baseSkip, leadDelta);
end
fprintf(['\nAny dropped frame is visible in Diagnostic as a confirmed interval of\n' ...
    'more than one refresh, so drops are detectable rather than silent.\n']);
end

% -------------------------------------------------------------------------
function r = runArm(measuredFrames, capture, drawables)
warmup = 120; total = warmup + measuredFrames;
w = [];
try
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen, [], drawables, false, true, capture);
 PsychMetal('HideCursor');
 side = min(rect(3), rect(4)) * 0.2;
 for k = 1:total
  PsychMetal('FillRect', w, [30 35 50]);
  PsychMetal('FillOval', w, [220 210 190], centreOn([0 0 side side], ...
      rect(3)/2 + cos(k*0.11)*rect(3)*0.2, rect(4)/2 + sin(k*0.11)*rect(4)*0.2));
  PsychMetal('FillRect', w, 255 * mod(k,2), [0 0 140 140]);
  PsychMetal('Flip', w);
 end
 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 st = PsychMetalFrameStats(d, ifi, warmup);

 r = struct('capture', capture, 'drawables', drawables, 'ifi', ifi, ...
     'confirmed', st.confirmed, 'unconfirmed', st.unconfirmed, ...
     'achievedHz', st.achievedHz, 'skipped', st.skipped, ...
     'onePerRefresh', st.onePerRefresh, ...
     'leadMs', st.leadMedianMs, 'leadRefreshes', st.leadRefreshes, ...
     'displayCaptured', d.summary.displayCaptured, 'summary', d.summary);

 fprintf('capture %d, %d drawables: %.3f Hz, skipped %d, lead %.3f ms (%.3f refreshes)\n', ...
     capture, drawables, r.achievedHz, r.skipped, r.leadMs, r.leadRefreshes);
catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

function r = centreOn(rct, x, y)
% CenterRectOnPoint without Psychtoolbox. Two lines, and it removes the last
% dependency this file had on a toolbox it otherwise does not use.
w = rct(3) - rct(1); h = rct(4) - rct(2);
r = [x - w/2, y - h/2, x + w/2, y + h/2];
end
