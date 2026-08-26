function report = PTBGeometryCompare(holdSeconds)
% PTBGeometryCompare  Check that the stimulus covers the whole panel.
%
%   report = PTBGeometryCompare(2)
%
% Opens PsychMetal, then a normal Psychtoolbox fullscreen window, holding each
% with a full-field black/white alternation so the top of the screen can be
% inspected. Prints every rectangle in the chain from the display down to the
% Metal layer:
%
%   cgDisplayBounds        CoreGraphics' view of the panel
%   screenFrame            AppKit's NSScreen.frame
%   screenVisibleFrame     minus menu bar and Dock
%   screenSafeAreaInsets   [top left bottom right]; a nonzero top is the notch
%   windowFrame            our NSWindow
%   viewBounds             its content view
%   layerFrame             the CAMetalLayer
%   drawable               layer.drawableSize, in pixels
%
% Everything except drawable and cgDisplayBounds is in points; multiply by
% backingScaleFactor to compare against pixels.
%
% This exists because a window of the right SIZE at the wrong ORIGIN looks
% correct in every height column. Before 0.3.1, AppKit fullscreen placed the
% window at y = -safeAreaInsets.top on a notched display, displacing every
% stimulus by 57 pixels and pushing the bottom rows off the panel. The origin
% check below is the one that catches that.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(holdSeconds), holdSeconds = 2; end

fprintf('\nWatch the top of the screen in each configuration.\n');
m = probeMetal(holdSeconds);
p = probePTB(holdSeconds);
report = struct('metal', m, 'ptb', p);

fprintf('\n================ geometry ================\n');
showRow('cgDisplayBounds',     m.cgDisplayBounds);
showRow('screenFrame',         m.screenFrame);
showRow('screenVisibleFrame',  m.screenVisibleFrame);
showRow('safeAreaInsets TLBR', m.screenSafeAreaInsets);
showRow('windowFrame',         m.windowFrame);
showRow('viewBounds',          m.viewBounds);
showRow('layerFrame',          m.layerFrame);
fprintf('%-24s %26s\n', 'drawable (px)', ...
    sprintf('%g x %g', m.drawableWidth, m.drawableHeight));
fprintf('%-24s %26g\n', 'backingScaleFactor', m.backingScaleFactor);
fprintf('%-24s %26d\n', 'display captured', m.displayCaptured);

fprintf('\n--- Psychtoolbox, same process ---\n');
fprintf('Screen Rect (points)   %s\n', mat2str(p.rect));
fprintf('Screen Rect (pixels)   %s\n', mat2str(p.rectPixels));
fprintf('Screen GlobalRect      %s\n', mat2str(p.globalRect));
fprintf('Window Rect            %s\n', mat2str(p.windowRect));

fprintf('\n--- display mode ---\n');
fprintf('Current: %.0f points wide, %.0f pixels wide; largest available %.0f\n', ...
    m.modePointWidth, m.modePixelWidth, m.nativePixelWidth);
% A scaled HiDPI mode renders to a framebuffer LARGER than the panel and
% downsamples, so the current mode's pixel width exceeds the panel's. The panel
% width is the largest width CGDisplayCopyAllDisplayModes reports, because that
% list omits the scaled modes. Any inequality means a resampling pass.
if isfinite(m.modePixelWidth) && isfinite(m.nativePixelWidth) && ...
        abs(m.modePixelWidth - m.nativePixelWidth) > 1
 fprintf(['SCALED mode: macOS renders a %.0f-pixel-wide framebuffer and resamples\n' ...
     'it to the %.0f-pixel panel. Measured not to affect presentation timing\n' ...
     '(docs/05_results.md section 8), but it costs image quality, and mixing it\n' ...
     'with native-resolution runs makes timing comparisons unsound.\n'], ...
     m.modePixelWidth, m.nativePixelWidth);
else
 fprintf('Native mode, no resampling pass.\n');
end

fprintf('\n--- reading ---\n');
expectedPts = m.cgDisplayBounds(4);
scale = m.backingScaleFactor;
if ~isfinite(scale) || scale <= 0, scale = 1; end
bad = {};
if abs(m.screenFrame(4) - expectedPts) > 1, bad{end+1} = 'NSScreen.frame height'; end
if abs(m.windowFrame(4) - expectedPts) > 1, bad{end+1} = 'NSWindow.frame height'; end
if abs(m.viewBounds(4) - expectedPts) > 1,  bad{end+1} = 'contentView.bounds height'; end
if abs(m.layerFrame(4) - expectedPts) > 1,  bad{end+1} = 'CAMetalLayer.frame height'; end
if abs(m.drawableHeight/scale - expectedPts) > 1, bad{end+1} = 'drawableSize height'; end
if abs(m.windowFrame(1)) > 0.5 || abs(m.windowFrame(2)) > 0.5
 bad{end+1} = sprintf('NSWindow.frame ORIGIN (%g, %g)', m.windowFrame(1), m.windowFrame(2));
end
if isempty(bad)
 fprintf(['Every rectangle covers the display exactly. The stimulus should have\n' ...
     'painted the menu bar strip and the region beside the notch, the same as\n' ...
     'the Psychtoolbox window did.\n']);
else
 fprintf('WRONG: %s\n', strjoin(bad, '; '));
 if abs(m.windowFrame(2)) > 0.5 && ...
         abs(abs(m.windowFrame(2)) - m.screenSafeAreaInsets(1)) < 2
  fprintf(['The y offset equals the %g-point safe-area top inset, so the window\n' ...
      'was shifted down by the notch and every stimulus is displaced by that\n' ...
      'much. This should not happen in 0.3.1 - Open is supposed to reject it.\n'], ...
      m.screenSafeAreaInsets(1));
 end
end
end

% -------------------------------------------------------------------------
function g = probeMetal(holdSeconds)
w = [];
fprintf('\n########## PsychMetal ##########\n');
try
 PsychDefaultSetup(2);
 screen = max(Screen('Screens'));
 [w, ~, ifi] = PsychMetal('OpenWindow', screen);
 PsychMetal('HideCursor');
 for k = 1:max(1, round(holdSeconds / ifi))
  Screen('FillRect', w, 255 * mod(k,2));
  PsychMetal('Flip', w);
 end
 d = PsychMetal('Diagnostic', w);
 PsychMetal('Close', w); w = [];
 PsychMetal('ShowCursor');
 g = d.summary;
catch e
 try, if ~isempty(w), PsychMetal('Close', w); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 try, Screen('CloseAll'); catch, end
 rethrow(e);
end
end

function p = probePTB(holdSeconds)
win = [];
fprintf('\n########## Psychtoolbox fullscreen ##########\n');
try
 PsychDefaultSetup(2);
 screen = max(Screen('Screens'));
 [win, winRect] = PsychImaging('OpenWindow', screen, 0);
 ifi = Screen('GetFlipInterval', win);
 PsychMetal('HideCursor');
 for k = 1:max(1, round(holdSeconds / ifi))
  Screen('FillRect', win, 255 * mod(k,2));
  Screen('Flip', win);
 end
 p = struct('rect', Screen('Rect', screen), ...
     'rectPixels', Screen('Rect', screen, 1), ...
     'globalRect', Screen('GlobalRect', screen), ...
     'windowRect', winRect);
 Screen('CloseAll'); win = [];
 PsychMetal('ShowCursor');
catch e
 try, if ~isempty(win), Screen('CloseAll'); end; catch, end
 try, PsychMetal('ShowCursor'); catch, end
 rethrow(e);
end
end

function showRow(name, r)
if numel(r) ~= 4
 fprintf('%-24s %26s\n', name, '--');
else
 fprintf('%-24s %26s\n', name, sprintf('%g %g %g %g', r(1), r(2), r(3), r(4)));
end
end
