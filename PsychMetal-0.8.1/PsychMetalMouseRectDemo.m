function report = PsychMetalMouseRectDemo(seconds)
% PsychMetalMouseRectDemo  A rectangle that follows the mouse, drawn in Metal.
%
%   report = PsychMetalMouseRectDemo(20)
%
% Click any mouse button to stop early.
%
% Every pixel is drawn by Metal. PsychMetal GetMouse polls CoreGraphics;
% neither presentation nor input uses Psychtoolbox.
%
% Colours use the default 0-to-255 ColorRange.
%
% PsychMetal('GetMouse', w) returns the pointer already in the window's own
% pixel coordinates. Plain GetMouse returns points, which differ from pixels by
% the backing scale factor on a Retina display in a scaled mode; using those
% directly makes the rectangle track at the wrong speed.
%
% Reports the interval from reading the mouse to the confirmed presentation of
% the frame containing it, about 1.97 refreshes. Most of that is the compositor;
% the rest is drawing. It was 3.85 refreshes until the window began acquiring
% its next drawable at the end of Flip instead of the start, which moved the
% unavoidable wait for a drawable to before the mouse read rather than after it.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds), seconds = 20; end
w = [];

try
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen);
 PsychMetal('HideCursor');

 side = min(rect(3), rect(4)) * 0.12;
 half = side / 2;
 total = round(seconds / ifi);
 sampleTime = nan(total,1);
 frames = 0;

 fprintf('\nMove the mouse. Click to stop. %g seconds maximum.\n', seconds);

 for k = 1:total
  sampleTime(k) = PsychMetal('GetSecs');
  [mx, my, buttons] = PsychMetal('GetMouse', w);
  if any(buttons), break; end
  frames = k;

  x = min(max(mx, 0), rect(3));
  y = min(max(my, 0), rect(4));

  % Background, then a crosshair through the cursor, then the box on top.
  PsychMetal('FillRect', w, [26 28 36]);
  PsychMetal('DrawLines', w, ...
      [0 rect(3) x x; y y 0 rect(4)], 2, [64 71 89]);
  PsychMetal('FillRect', w, [242 89 64], ...
      [x - half, y - half, x + half, y + half]);
  PsychMetal('FrameRect', w, 255, ...
      [x - half, y - half, x + half, y + half], 3);
  PsychMetal('Flip', w);
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 % Diagnostic row k corresponds to loop iteration k.
 n = min(frames, numel(d.flipNumber));
 st = PsychMetalFrameStats(d, ifi);
 rows = 1:n;
 ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
 inputMs = (d.actualTimestamp(rows(ok)) - sampleTime(rows(ok))) * 1000;

 report = struct('ifi', ifi, 'frames', n, 'confirmed', st.confirmed, ...
     'achievedHz', st.achievedHz, 'skipped', st.skipped, ...
     'inputToPhotonsMedianMs', median(inputMs), ...
     'inputToPhotonsRefreshes', median(inputMs)/(ifi*1000), ...
     'summary', d.summary);

 fprintf('\n===== mouse rectangle, drawn in Metal =====\n');
 fprintf('Frames %d; confirmed %d; skipped %d\n', n, sum(ok), report.skipped);
 fprintf('RATE: %.3f presentations/s\n', report.achievedHz);
 fprintf('MOUSE -> PRESENTED median %.3f ms (%.3f refreshes)\n', ...
     report.inputToPhotonsMedianMs, report.inputToPhotonsRefreshes);
 fprintf(['About two refreshes, of which the compositor is most and drawing is\n' ...
     'the rest. The window prefetches its next drawable so that the wait for\n' ...
     'one happens before the mouse is read rather than after, which is worth\n' ...
     'a full refresh here. See docs/05_results.md section 9c.\n']);

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
