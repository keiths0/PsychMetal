function PsychMetalDirectDemo(measuredFrames)
% Validate full-resolution direct presentation without Screen('Flip').
% Rotation follows projected presentation time, not the loop iteration.
if nargin < 1, measuredFrames = 600; end
warmup = 120; total = warmup + measuredFrames; results = nan(total,5); stages = nan(total,2);
target = [];
PsychDefaultSetup(2); KbName('UnifyKeyNames');
try
 [target, rect, ifi] = PsychMetal('OpenWindow');
 referenceVBL = NaN; nextVBL = NaN; angularSpeed = 120; % degrees/second
 side = 0.38 * min(rect(3), rect(4));
 halfSide = side / 2;
 corners = [-halfSide -halfSide; halfSide -halfSide; halfSide halfSide; -halfSide halfSide];
 center = [rect(3)/2 rect(4)/2];
 panel = [center(1)-190 35 center(1)+190 145];
 for k = 1:total
  t0 = GetSecs;
  Screen('FillRect', target, [238 238 238]);
  if isnan(nextVBL), angle = 0;
  else, angle = mod((nextVBL - referenceVBL) * angularSpeed, 360); end
  rotation = [cosd(angle) -sind(angle); sind(angle) cosd(angle)];
  vertices = corners * rotation' + center;
  % Draw the square through PTB's normal OpenGL shape path. FramePoly uses
  % the line smoothing supplied by that path; no texture or texture filter
  % participates in rendering the square.
  Screen('FillPoly', target, [40 80 180], vertices, 1);
  Screen('FramePoly', target, [255 80 180], vertices, 12);
  Screen('FillRect', target, [15 20 35], panel);
  drawCounter(target, mod(k,10000), center(1)-132, 52, 5, [80 255 255]);
  Screen('FillRect', target, 255 * mod(k,2), [0 0 140 140]);
  t1 = GetSecs;
  [results(k,1),results(k,2),results(k,3),results(k,4),results(k,5)] = PsychMetal('Flip',target);
  if isnan(referenceVBL), referenceVBL = results(k,1); end
  nextVBL = results(k,1) + ifi;
  stages(k,:) = [t1-t0 GetSecs-t1];
  [down,~,keys] = KbCheck;
  if down && keys(KbName('ESCAPE')), total=k; results=results(1:k,:); stages=stages(1:k,:); break; end
 end
 diag=PsychMetal('Diagnostic',target);
 results=[diag.projectedTimestamp diag.frameID zeros(size(diag.frameID)) diag.scheduledAt diag.displayLinkTick];
 PsychMetal('Close',target);
 first=min(warmup+1,total); m=results(first:end,:); valid=m(:,3)==0; v=m(valid,:);
 intervals=diff(v(:,1))*1000; gaps=diff(v(:,2)); sm=stages(first:end,:)*1000;
 fprintf('\nNo Screen(''Flip'') calls were made. Nominal IFI %.6f ms.\n',ifi*1000);
 fprintf('Measured %d; valid %d; invalid %d\n',size(m,1),sum(valid),sum(~valid));
 if ~isempty(intervals),fprintf('Presented median/p99/max %.6f / %.6f / %.6f ms\n',median(intervals),prctile(intervals,99),max(intervals));end
 if ~isempty(gaps),fprintf('Consecutive %d; skipped-refresh %d\n',sum(gaps==1),sum(gaps>1));end
 fprintf('Draw / synchronous Flip medians %.3f / %.3f ms\n',median(sm(:,1)),median(sm(:,2)));
 fprintf('Last direct queue / full Flip %.3f / %.3f ms.\n',diag.summary.lastQueueMs,diag.summary.lastFlipMs);
 disp(diag.summary); dlmwrite('psychmetal_direct.csv',[(1:size(results,1))' results stages],',');
catch e
 try, if ~isempty(target), PsychMetal('Close', target); end; catch, end
 try, Screen('CloseAll'); catch, end
 try, ShowCursor; catch, end
 try, Priority(0); catch, end
 rethrow(e);
end
end

function drawCounter(target, value, x, y, s, color)
patterns=[1 1 1 1 1 1 0;0 1 1 0 0 0 0;1 1 0 1 1 0 1;1 1 1 1 0 0 1;0 1 1 0 0 1 1;1 0 1 1 0 1 1;1 0 1 1 1 1 1;1 1 1 0 0 0 0;1 1 1 1 1 1 1;1 1 1 1 0 1 1];
digits=zeros(1,4);for q=4:-1:1,digits(q)=mod(value,10);value=floor(value/10);end
for q=1:4
 px=x+(q-1)*14*s;py=y;w=8*s;h=14*s;t=s;
 seg=[px py px+w py+t;px+w-t py px+w py+h/2;px+w-t py+h/2 px+w py+h;px py+h-t px+w py+h;px py+h/2 px+t py+h;px py px+t py+h/2;px py+h/2-t/2 px+w py+h/2+t/2];
 Screen('FillRect',target,color,seg(patterns(digits(q)+1,:)>0,:)');
end
end
