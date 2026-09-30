function report = PsychMetalDrawableCompare(repeats)
% PsychMetalDrawableCompare  Does drawable count change what a drained queue can do?
%
%   report = PsychMetalDrawableCompare(40)
%
% In a continuous loop each additional drawable costs exactly one refresh of
% latency, because the loop keeps the pipeline full and a new present queues
% behind everything already in flight. This test asks a different question:
% with the queue drained before every present, does the buffer count change the
% floor?
%
% Two competing accounts:
%
%   Buffering account. The application writes into a slot two refreshes ahead,
%   so three buffers are needed to reach N+2 and two buffers should reach N+1.
%   Prediction: with 2 drawables the fastest call-to-presentation drops below
%   one refresh interval (< 16.667 ms).
%
%   Compositor account. The render server samples committed surfaces once per
%   refresh, one refresh ahead, so a present must be issued before boundary
%   B-1 to appear at boundary B regardless of how many buffers the application
%   owns. Prediction: the floor stays at about 1.04 refreshes (~17.3 ms) for
%   both counts.
%
% Runs 2 and 3 in a single session, back to back, so machine state is shared.
% Order is 3 then 2 then 3 again, so that a drift between the two 3-drawable
% arms bounds how much of any 2-vs-3 difference could be session drift.
%
% SPDX-License-Identifier: MIT

if nargin < 1 || isempty(repeats), repeats = 40; end

fprintf('\n########## arm 1 of 3: 3 drawables (baseline) ##########\n');
a = PsychMetalLatchTest(repeats, 3);

fprintf('\n########## arm 2 of 3: 2 drawables ##########\n');
b = PsychMetalLatchTest(repeats, 2);

fprintf('\n########## arm 3 of 3: 3 drawables (baseline repeat) ##########\n');
c = PsychMetalLatchTest(repeats, 3);

report = struct('three_first', a, 'two', b, 'three_second', c, 'repeats', repeats);

oneRefreshMs = a.gridPeriod * 1000;
drift = abs(a.bestCallToPresentMs - c.bestCallToPresentMs);
effect = b.bestCallToPresentMs - mean([a.bestCallToPresentMs, c.bestCallToPresentMs]);

fprintf('\n================ drawable count comparison ================\n');
fprintf('One refresh = %.4f ms\n\n', oneRefreshMs);
fprintf('%-28s %14s %14s %14s\n', '', '3 drawables', '2 drawables', '3 again');
fprintf('%-28s %14.4f %14.4f %14.4f\n', 'fastest call->present (ms)', ...
    a.bestCallToPresentMs, b.bestCallToPresentMs, c.bestCallToPresentMs);
fprintf('%-28s %14.4f %14.4f %14.4f\n', 'fastest (refreshes)', ...
    a.bestCallToPresentRefreshes, b.bestCallToPresentRefreshes, ...
    c.bestCallToPresentRefreshes);
fprintf('%-28s %14.3f %14.3f %14.3f\n', 'cutoff phase', ...
    a.cutoffPhase, b.cutoffPhase, c.cutoffPhase);

fprintf('\nBaseline drift between the two 3-drawable arms: %.4f ms\n', drift);
fprintf('Effect of dropping to 2 drawables: %.4f ms\n', effect);

fprintf('\nVERDICT: ');
if b.bestCallToPresentMs < oneRefreshMs
 fprintf(['2 drawables reached a presentation in under one refresh interval.\n' ...
     'The buffering account survives: the floor is a function of how many\n' ...
     'slots the application holds, and N+2 was a consequence of asking for 3.\n']);
elseif abs(effect) <= max(0.25, 2*drift)
 fprintf(['no effect beyond baseline drift. Both counts sit at about %.3f\n' ...
     'refreshes, so the one-refresh lead is a property of the compositor and\n' ...
     'not of the drawable pool. Buffer count adds queue depth in a continuous\n' ...
     'loop but does not change what a drained pipeline can achieve.\n'], ...
     mean([a.bestCallToPresentRefreshes, b.bestCallToPresentRefreshes, ...
           c.bestCallToPresentRefreshes]));
else
 fprintf(['2 drawables changed the floor by %.4f ms against a baseline drift\n' ...
     'of %.4f ms, but did not get under one refresh. Neither account is clean;\n' ...
     'worth repeating before drawing a conclusion.\n'], effect, drift);
end

fprintf(['\nPresentation boundary by phase (should be exact integers in every\n' ...
    'arm; a non-integer would mean the grid estimate drifted):\n']);
fprintf('%-10s %12s %12s %12s\n', 'phase', '3 draw', '2 draw', '3 again');
n = min([numel(a.phases), numel(b.phases), numel(c.phases)]);
for i = 1:n
 fprintf('%-10.3f %12.3f %12.3f %12.3f\n', ...
     a.phases(i), a.presRefreshes(i), b.presRefreshes(i), c.presRefreshes(i));
end
end
