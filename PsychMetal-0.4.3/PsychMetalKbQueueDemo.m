function events = PsychMetalKbQueueDemo(seconds)
% PsychMetalKbQueueDemo([seconds=15]) demonstrates taps retained during waits.
% No display capture. Tap T quickly while the host waits 0.5 seconds per read.
% Escape exits. Events: [detectionTime HIDkeyCode pressed].
if nargin<1 || isempty(seconds), seconds=15; end
assert(isscalar(seconds) && isfinite(seconds) && seconds>0,'seconds must be positive.');
mask=zeros(1,256); mask([23 41])=1;
PsychMetal('KbQueueCreate',mask);
guard=onCleanup(@() PsychMetal('KbQueueRelease'));
PsychMetal('KbQueueStart'); events=zeros(0,3);
fprintf('Tap T during each half-second host wait. Escape exits.\n');
deadline=PsychMetal('GetSecs')+seconds;
while PsychMetal('GetSecs')<deadline
    PsychMetal('WaitSecs',.5);
    [new,dropped]=PsychMetal('KbQueueGetEvents');
    if dropped>0, error('Keyboard queue overflowed: %d events lost.',dropped); end
    for j=1:size(new,1)
        state='release'; if new(j,3), state='press'; end
        fprintf('%.6f key %d %s\n',new(j,1),new(j,2),state);
    end
    events=[events; new]; %#ok<AGROW>
    if any(new(:,2)==41 & new(:,3)==1), break; end
end
clear guard;
end
