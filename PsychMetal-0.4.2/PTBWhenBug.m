function gaps = PTBWhenBug(waitframes, n)
% PTBWhenBug  Minimal reproducer: does Screen('Flip', w, when) honour 'when'?
%
%   PTBWhenBug(1)   % should present every refresh
%   PTBWhenBug(2)   % should present every second refresh
%   PTBWhenBug(3)   % should present every third refresh
%
% Deliberately short and dependency-free so it can be pasted into a bug report.
% Uses nothing but PsychDefaultSetup, PsychImaging and Screen, and the standard
% vbl + (waitframes - 0.5) * ifi scheduling idiom that VBLSyncTest uses.
%
% Expected: the printed gap sequence is all <waitframes>.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(waitframes), waitframes = 2; end
if nargin < 2 || isempty(n), n = 60; end

PsychDefaultSetup(2);
screen = max(Screen('Screens'));
[w, rect] = PsychImaging('OpenWindow', screen, 0);
ifi = Screen('GetFlipInterval', w);

v = nan(n,1);
vbl = Screen('Flip', w);
for k = 1:n
 Screen('FillRect', w, 128 * mod(k,2), [0 0 rect(3)/2 rect(4)/2]);
 vbl = Screen('Flip', w, vbl + (waitframes - 0.5) * ifi);
 v(k) = vbl;
end
Screen('CloseAll');

gaps = diff(v) / ifi;
fprintf('\nifi %.6f ms; requested %d refreshes between presentations\n', ...
    ifi*1000, waitframes);
fprintf('achieved: median %.2f, mean %.3f, min %.2f, max %.2f\n', ...
    median(gaps), mean(gaps), min(gaps), max(gaps));
fprintf('rounded gap sequence:\n');
fprintf('%d ', round(gaps)); fprintf('\n');
if all(round(gaps) == waitframes)
 fprintf('PASS: every gap matches the request.\n');
else
 fprintf('FAIL: %d of %d gaps differ from the requested %d.\n', ...
     sum(round(gaps) ~= waitframes), numel(gaps), waitframes);
end
end
