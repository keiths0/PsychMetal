function PsychMetalMinimalDemo(seconds)
% PsychMetalMinimalDemo  Open, draw a rectangle in Metal, flip. Nothing else.
%
%   PsychMetalMinimalDemo(3)
%
% There is no Screen drawing call anywhere below. The whole frame is produced by
% Metal: a full-window fill for the background, then a red rectangle over it.
%
% Colours follow the window's ColorRange, which opens at 255 exactly as Screen's
% does, so code written against Screen ports without touching a colour literal.
% This demo is written in 0-1, which is the one line below.
%
% Nothing here uses Screen, and neither does PsychMetal: there is no OpenGL
% and no Psychtoolbox window anywhere in the path as of 0.4.0.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(seconds), seconds = 3; end
w = [];

try
 screen = [];   % [] is the last active display
 [w, rect, ifi] = PsychMetal('OpenWindow', screen);
 PsychMetal('HideCursor');

 box = [rect(3)*0.30, rect(4)*0.30, rect(3)*0.70, rect(4)*0.70];
 fprintf('\nDrawing a red rectangle at %s for %g seconds.\n', ...
     mat2str(round(box)), seconds);
 fprintf('Everything on screen is drawn by Metal; no Screen drawing calls.\n');

 for k = 1:round(seconds / ifi)
  PsychMetal('FillRect', w, [38 38 51]);   % background, whole window
  PsychMetal('FillRect', w, [230 51 38], box);
  PsychMetal('Flip', w);
 end

 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');

 fprintf('Shapes appended %d, encoded %d.\n', ...
     d.summary.shapesAppended, d.summary.shapesEncoded);
 % lastShapeColor is the FIRST shape of a batch, so it is the background.
 fprintf('First shape of the last batch: %s (the background, 0-1).\n', ...
     mat2str(d.summary.lastShapeColor, 4));

catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end
