function report = PsychMetalCompositorProbe(frames)
% PsychMetalCompositorProbe  Is the WindowServer still in the path?
%
%   report = PsychMetalCompositorProbe(300)
%
% The layer already asks for everything that makes macOS eligible to promote it
% to a hardware plane and skip composition:
%
%   opaque = YES, framebufferOnly = YES, pixelFormat = BGRA8Unorm,
%   colorspace = nil, wantsExtendedDynamicRangeContent = NO,
%   plus CGDisplayCapture and a borderless window at shielding level.
%
% macOS reports nowhere whether that worked, so the only evidence is timing. A
% frame scanned out directly should reach the display 0 to 1 refresh after the
% commit: present at time t, the next vblank takes it. Measured commit-to-
% presented is 1.7 to 2.0 refreshes. The extra refresh is what compositing looks
% like -- WindowServer collects the frame at one vblank, composites during that
% refresh, displays it at the next.
%
% WHY RE-RUN WHAT SECTION 8 ALREADY TESTED. Sections 2, 3, 4 and 8 concluded
% that nothing moves this floor: not resolution mode, not window mode, not full
% panel coverage, not Game Mode, not preferredFrameLatency, not drawable count.
% Every one of those was measured with two drawables, which is the regime where
% the loop sits on the deadline and the outcome is decided by noise. Four
% separate null results were reached that way today and all four were wrong. A
% real effect could easily have been buried in dropped frames.
%
% They were also measured with the OLD lead stamp, taken before nextDrawable, so
% the quantity being compared included drawable-pool backpressure. This uses
% committedAt and reports the pipeline alone.
%
% Arms, each in its OWN window so no state carries across:
%
%   scaled,  vsync on    the current default; panel fitter active
%   scaled,  vsync off   control. With no wait for a boundary this is the
%                        floor the hardware can reach, tearing and all.
%   native,  vsync on    no panel fitter. A scaling pass is the most likely
%                        reason a layer would be denied a hardware plane.
%   native,  vsync off   the same control at native resolution
%
% What the answer looks like:
%
%   If native halves the pipeline, the panel fitter was forcing composition and
%   section 8's null was a two-drawable artefact.
%   If vsync-off is near zero but vsync-on stays at ~2 refreshes in both modes,
%   the frame is ready early and something is holding it for an extra refresh:
%   composition, and not something this app can decline.
%   If all four agree, the floor is real and section 8 stands.
%
% Restores the original resolution on the way out, including on error.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(frames), frames = 300; end
w = [];
screen = [];   % [] is the last active display
original = PsychMetal('Resolution', screen);
restoreNeeded = false;

try
 % Largest available mode is the panel's own; anything smaller is scaled and
 % goes through the fitter.
 modes = PsychMetal('Resolutions', screen);
 area = [modes.width] .* [modes.height];
 [~, big] = max(area);
 native = modes(big);

 isNative = (original.width == native.width && original.height == native.height);
 fprintf('\nCurrent mode %dx%d; largest available %dx%d%s\n', ...
     original.width, original.height, native.width, native.height, ...
     tern(isNative, ' (already native)', ' (scaled: panel fitter active)'));

 names   = {'current, vsync on', 'current, vsync off', ...
            'native, vsync on',  'native, vsync off'};
 useNat  = [false false true  true ];
 useSync = [true  false true  false];
 nArm = numel(names);

 med = nan(1,nArm); lo = nan(1,nArm); p99 = nan(1,nArm);
 hz = nan(1,nArm); skip = nan(1,nArm); res = cell(1,nArm);

 for a = 1:nArm
  if useNat(a) && ~isNative
   PsychMetal('Resolution', screen, native.width, native.height);
   restoreNeeded = true;
   PsychMetal('WaitSecs', 1.0);          % let the mode change settle before opening
  elseif ~useNat(a) && restoreNeeded
   PsychMetal('Resolution', screen, original.width, original.height);
   restoreNeeded = false;
   PsychMetal('WaitSecs', 1.0);
  end

  [w, rect, ifi] = PsychMetal('OpenWindow', screen);

  PsychMetal('SetDisplaySync', w, useSync(a));
  res{a} = sprintf('%dx%d', rect(3), rect(4));

  for k = 1:(frames + 90)
   PsychMetal('FillRect', w, 51);
   PsychMetal('FillRect', w, 230, ...
       [rect(3)*0.4, rect(4)*0.4, rect(3)*0.6, rect(4)*0.6]);
   PsychMetal('Flip', w);
  end

  d = PsychMetal('Diagnostic', w);
  st = PsychMetalFrameStats(d, ifi, 90);
  hz(a) = st.achievedHz; skip(a) = st.skipped;

  % The FLOOR is the interesting statistic, not the average: the question is
  % what the path can do at best, not what it does when the loop is busy.
  g = d.pipelineLeadMs(91:end);
  g = g(isfinite(g) & g > 0);
  if ~isempty(g)
   g = sort(g);
   med(a) = median(g) / (ifi*1000);
   lo(a)  = g(max(1, round(0.01*numel(g)))) / (ifi*1000);
   p99(a) = g(max(1, round(0.99*numel(g)))) / (ifi*1000);
  end

  PsychMetal('Close', w); w = [];
 end

 if restoreNeeded
  PsychMetal('Resolution', screen, original.width, original.height);
  restoreNeeded = false;
 end

 report = struct('frames', frames, 'names', {names}, 'useNative', useNat, ...
     'useSync', useSync, 'resolution', {res}, 'wasNative', isNative, ...
     'pipelineMedian', med, 'pipelineP01', lo, 'pipelineP99', p99, ...
     'achievedHz', hz, 'skipped', skip);

 fprintf('\n===== commit to presented, in refreshes =====\n');
 fprintf('%-20s %-12s %8s %8s %8s %9s %8s\n', 'arm', 'drawable', ...
     'p01', 'median', 'p99', 'Hz', 'skipped');
 for a = 1:nArm
  fprintf('%-20s %-12s %8.3f %8.3f %8.3f %9.3f %8.0f\n', names{a}, res{a}, ...
      lo(a), med(a), p99(a), hz(a), skip(a));
 end

 fprintf(['\nA directly scanned-out frame should reach the display within one\n' ...
     'refresh of the commit. Two refreshes means something took the frame,\n' ...
     'held it for a refresh, and showed it at the next boundary.\n']);
 if isfinite(med(1)) && isfinite(med(3))
  fprintf('Native minus current, vsync on: %+.3f refreshes\n', med(3) - med(1));
 end
 if isfinite(med(1)) && isfinite(med(2))
  fprintf('Turning vsync off removes %.3f refreshes, which bounds what a\n', ...
      med(1) - med(2));
  fprintf('bypass could ever buy on this machine.\n');
 end

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try
  if restoreNeeded
   PsychMetal('Resolution', screen, original.width, original.height);
  end
 catch
 end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

% -------------------------------------------------------------------------
function out = tern(c, a, b)
if c, out = a; else, out = b; end
end
