function stats = PsychMetalFrameStats(d, ifi, discard)
% PsychMetalFrameStats  Presentation statistics from a Diagnostic history.
%
%   stats = PsychMetalFrameStats(d, ifi)         % use every row
%   stats = PsychMetalFrameStats(d, ifi, 120)    % discard the first 120
%
% Every demo and test needs the same summary of a run, and every one of them
% used to compute it inline. That duplication produced real errors: reporting
% the rate from the MEDIAN interval, which hides dropped frames entirely, and
% counting gaps across rows that were not adjacent confirmed presentations.
% One implementation, used everywhere, is the point of this function.
%
% Returns:
%   frames          rows considered after the discard
%   confirmed       rows with a confirmed presentedTime
%   unconfirmed     rows without one
%   achievedHz      from the MEAN interval. Not the median: a loop that
%                   presents on nine refreshes out of ten still has a median
%                   interval of exactly one refresh.
%   medianIntervalMs, p99IntervalMs, minIntervalMs, maxIntervalMs
%   spreadMs        p99 minus median, the number to quote for stability
%   onePerRefresh   adjacent confirmed pairs exactly one refresh apart
%   skipped         adjacent confirmed pairs more than one refresh apart
%   gaps            the rounded gap for each adjacent confirmed pair
%   leadMedianMs    submit to presented, where the history provides it
%
% SPDX-License-Identifier: MIT

if nargin < 3 || isempty(discard), discard = 0; end
assert(isstruct(d) && isfield(d, 'actualStatus') && isfield(d, 'actualTimestamp'), ...
    'The first argument must be a PsychMetal Diagnostic history.');
assert(isscalar(ifi) && isfinite(ifi) && ifi > 0, 'ifi must be a positive scalar.');

total = numel(d.actualStatus);
rows = (min(discard, total) + 1):total;

ok = false(size(rows));
if ~isempty(rows)
 ok = d.actualStatus(rows) == 0 & isfinite(d.actualTimestamp(rows));
end

% Only ADJACENT confirmed pairs. An interval spanning an unconfirmed row is not
% a presentation interval and would be counted as a skip that never happened.
adj = find(ok(1:max(0,end-1)) & ok(2:end));
if isempty(adj)
 iv = []; gaps = [];
else
 iv = (d.actualTimestamp(rows(adj+1)) - d.actualTimestamp(rows(adj))) * 1000;
 gaps = round(iv / (ifi * 1000));
end

lead = [];
if isfield(d, 'measuredLeadMs') && any(ok)
 lead = d.measuredLeadMs(rows(ok));
 lead = lead(isfinite(lead));
end
% The pipeline proper, excluding the wait for a free drawable. measuredLeadMs
% starts before nextDrawable and so charges backpressure to the compositor.
pipe = []; dwait = [];
if isfield(d, 'pipelineLeadMs') && any(ok)
 pipe = d.pipelineLeadMs(rows(ok));  pipe = pipe(isfinite(pipe));
 dwait = d.drawableWaitMs(rows(ok)); dwait = dwait(isfinite(dwait));
end

stats = struct( ...
    'frames',           numel(rows), ...
    'confirmed',        sum(ok), ...
    'unconfirmed',      sum(~ok), ...
    'achievedHz',       tern(isempty(iv), NaN, 1000 / mean(iv)), ...
    'medianIntervalMs', tern(isempty(iv), NaN, median(iv)), ...
    'p99IntervalMs',    pct(iv, 99), ...
    'minIntervalMs',    tern(isempty(iv), NaN, min(iv)), ...
    'maxIntervalMs',    tern(isempty(iv), NaN, max(iv)), ...
    'spreadMs',         pct(iv, 99) - tern(isempty(iv), NaN, median(iv)), ...
    'onePerRefresh',    sum(gaps == 1), ...
    'skipped',          sum(gaps > 1), ...
    'gaps',             gaps(:)', ...
    'leadMedianMs',     tern(isempty(lead), NaN, median(lead)), ...
    'leadRefreshes',    tern(isempty(lead), NaN, median(lead)/(ifi*1000)), ...
    'pipelineLeadMs',   tern(isempty(pipe), NaN, median(pipe)), ...
    'pipelineRefreshes',tern(isempty(pipe), NaN, median(pipe)/(ifi*1000)), ...
    'drawableWaitMs',   tern(isempty(dwait), NaN, median(dwait)));
end

% -------------------------------------------------------------------------
function y = pct(x, p)
x = sort(x(isfinite(x)));
n = numel(x);
if n == 0, y = NaN; return; end
if n == 1, y = x(1); return; end
q = 1 + (n-1)*p/100;
lo = floor(q); hi = ceil(q);
y = x(lo) + (q-lo)*(x(hi)-x(lo));
end

function out = tern(c, a, b)
if c, out = a; else, out = b; end
end
