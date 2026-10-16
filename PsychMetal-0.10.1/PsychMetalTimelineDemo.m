function report = PsychMetalTimelineDemo(seconds)
% Native frame-counted Gaussian flicker; no per-frame MATLAB/Octave drawing.
% Escape exits. Fixed scene: use PsychMetalBlobArrayDemo for dragging.
if nargin<1 || isempty(seconds),seconds=20;end
assert(isnumeric(seconds) && isreal(seconds) && isscalar(seconds) && isfinite(seconds) && seconds>0, ...
 'seconds must be positive and finite.');
[w,r,nominal]=PsychMetal('OpenWindow');
guard=onCleanup(@() closeWindow(w)); %#ok<NASGU>
PsychMetal('BackgroundColor',w,127.5);
for i=1:max(60,round(1/nominal)),PsychMetal('Flip',w);end
grid=PsychMetal('GridAnchor',w);
assert(grid(3)>=30 && isfinite(grid(2)) && grid(2)>0,'Could not measure refresh rate.');
interval=grid(2);frames=round(seconds/interval);
assert(frames>=1 && frames<=1000000,'Duration must produce 1 to 1000000 frames.');
count=max(1,floor(log2(.5/interval)+.5)+1);periods=2.^(1:count);
if periods(end)>=8,periods=unique([periods 6]);end
count=numel(periods);width=r(3)-r(1);height=r(4)-r(2);
cols=min(count,max(1,ceil(sqrt(count*width/height))));rows=ceil(count/cols);
cw=width/cols;ch=height/rows;half=min(cw*.42,ch*.32);font=max(12,min(cw*.08,ch*.08));
centers=zeros(count,2);
blob=PsychMetal('MakeStimulus','grating',struct('frequency',0,'mean',.5,'contrast',1,'aperture','gaussian','sigma',.3));
% All stimuli precede text; MATLAB timeline draw indices are one-based.
for i=1:count
 x=(mod(i-1,cols)+.5)*cw;y=(floor((i-1)/cols)+.43)*ch;centers(i,:)=[x y];
 PsychMetal('DrawStimulus',w,blob,[x-half y-half x+half y+half]);
end
for i=1:count
 PsychMetal('DrawText',w,sprintf('%.2f Hz',1/(interval*periods(i))), ...
  centers(i,1)-half*.7,centers(i,2)+half,255,font);
end
tracks=[(1:count)' ones(count,2) periods' 360*ones(count,1) zeros(count,1)];
fprintf('Native timeline: Escape stops; blobs stay in place.\n');
result=PsychMetal('PlayTimeline',w,frames,tracks);
history=PsychMetal('Diagnostic',w);summary=history.summary;
stats=PsychMetalFrameStats(history,interval,max(0,numel(history.actualStatus)-result.submitted));
fprintf('%d submitted; %.3f presentations/s; %d long adjacent intervals.\n',result.submitted,stats.achievedHz,stats.skipped);
fprintf(['The display reported %d shown and %d late (%d refreshes lost). A sample stayed %.3f ms on average,\n' ...
 'so the labelled frequencies ran at %.4f of their value.\n'],result.shown,result.late,result.lateRefreshes, ...
 result.meanSampleMs,1000*interval/result.meanSampleMs);
report=struct('playback',result,'framePeriods',periods,'frequencies',1./(interval*periods), ...
 'history',history,'summary',summary,'frameStats',stats);
end
function closeWindow(w)
try,PsychMetal('Close',w);catch,end
end
