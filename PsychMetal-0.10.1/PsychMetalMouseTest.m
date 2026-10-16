function report = PsychMetalMouseTest(seconds, screenNumber)
% PsychMetalMouseTest([seconds=30 [, screenNumber=[]]])
% Visual 0.4.2 mouse check. Move to all edges; press/hold/release buttons.
% Three boxes at top: left, right, middle; green while held, gray otherwise.
% Crosshair follows pointer in render pixels. Escape/Q exits; clicks do not.
% Console logs transitions; report counts rising edges, not timing accuracy.
if nargin<1 || isempty(seconds), seconds=30; end
if nargin<2, screenNumber=[]; end
assert(isscalar(seconds) && isfinite(seconds) && seconds>0,'seconds must be positive.');
[w,rect]=PsychMetal('OpenWindow',screenNumber,20);
guard=onCleanup(@() closewindow(w));
W=rect(3); H=rect(4); s=min(W,H)*0.05;
boxes=[W/2-4*s 2*s W/2-2*s 4*s; W/2-s 2*s W/2+s 4*s; W/2+2*s 2*s W/2+4*s 4*s]';
[~,~,prev]=PsychMetal('GetMouse',w); pressCounts=zeros(1,3); samples=0;
minXY=[Inf Inf]; maxXY=[-Inf -Inf];
fprintf('Mouse test: boxes LEFT, RIGHT, MIDDLE. Green means held. Q/Escape exits.\n');
deadline=PsychMetal('GetSecs')+seconds;
while PsychMetal('GetSecs')<deadline
    [x,y,buttons]=PsychMetal('GetMouse',w);
    assert(islogical(buttons) && isequal(size(buttons),[1 3]),'Expected logical 1x3 button state.');
    assert(isfinite(x) && isfinite(y),'Nonfinite mouse coordinates.');
    samples=samples+1; minXY=min(minXY,[x y]); maxXY=max(maxXY,[x y]);
    pressCounts=pressCounts+double(buttons & ~prev);
    if any(buttons~=prev)
        fprintf('x=%.1f y=%.1f; left=%d right=%d middle=%d\n',x,y,buttons);
    end
    prev=buttons;
    [~,~,keys]=PsychMetal('KbCheck'); if keys(41)||keys(20), break; end
    PsychMetal('FillRect',w,20);
    colors=repmat([80;80;80],1,3); colors(:,buttons)=repmat([40;230;90],1,nnz(buttons));
    PsychMetal('FillRect',w,colors,boxes);
    PsychMetal('FrameRect',w,220,boxes,2);
    PsychMetal('DrawLines',w,[0 W x x; y y 0 H],2,[40 200 255]);
    PsychMetal('FrameRect',w,255,[x-s/2 y-s/2 x+s/2 y+s/2],2);
    PsychMetal('Flip',w);
end
report=struct('samples',samples,'pressCounts',pressCounts,'minXY',minXY,'maxXY',maxXY,'rect',rect);
clear guard;
fprintf('Observed button presses [left right middle]: %d %d %d\n',pressCounts);
end
function closewindow(w)
try, PsychMetal('Close',w); catch, end
end
