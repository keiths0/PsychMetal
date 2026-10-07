function test_headless(root)
addpath(root);clear PsychMetal PsychMetalCore
assert(strcmp(PsychMetalCore('Version'),'0.7.0'));
reject(@() coreFlip());reject(@() corePrepare());reject(@() coreStartup());
reject(@() PsychMetalCore('BlendMode',1));reject(@() PsychMetalCore('Gamma',.5,.5,.5));reject(@() PsychMetalCore('GammaTable',zeros(4,3)));
reject(@() PsychMetalCore('TextBounds','a','',20)+0);reject(@() PsychMetalCore('DrawText','a','',20,0,0,[1 1 1 1])+0);reject(@() PsychMetalCore('LinkInfo')+0);
reject(@() PsychMetalCore('Clip',[0 0 10 10]));reject(@() PsychMetalCore('OpenOffscreen',10,10,[0 0 0 1])+0);reject(@() PsychMetalCore('SetTarget',0));
reject(@() PsychMetalCore('DrawPolygon',zeros(2,3),[1 1 1 1],0));reject(@() PsychMetalCore('QueueFlip',1)+0);reject(@() PsychMetalCore('QueueResults',1)+0);
reject(@() PsychMetalCore('QueueCancel')+0);reject(@() mouseEvents());
h=PsychMetalCore('StartupHistory');assert(isequal(size(h),[0 6]));
reject(@() PsychMetal('KbQueueCreate',sparse(1,23,1,1,256)));
reject(@() PsychMetalCore('KbQueueCreate',sparse(1,23,1,1,256),.002));
reject(@() PsychMetalCore('KbQueueCreate',nan(1,256),.002));
PsychMetal('KbQueueCreate',false(1,256));
s=PsychMetal('KbQueueStatus');assert(s.created && ~s.running && s.dropped==0);
[e,d]=PsychMetal('KbQueueGetEvents');assert(isequal(size(e),[0 3]) && d==0);
[p,a,b,c,d]=PsychMetal('KbQueueCheck');assert(~p && numel(a)==256 && ~any([a b c d]));
PsychMetal('KbQueueFlush');PsychMetal('KbQueueStop');PsychMetal('KbQueueRelease');
s=PsychMetal('KbQueueStatus');assert(~s.created && ~s.running);
reject(@() PsychMetal('KbQueueStart'));
fprintf('PASS: actual MEX ABI, closed-state rejection, sparse/nonfinite mask rejection, queue lifecycle/status.\n');
end
function coreFlip(),t=PsychMetalCore('Flip');end
function corePrepare(),t=PsychMetalCore('PrepareFlip');end
function mouseEvents()
[e,d]=PsychMetalCore('MouseEvents'); %#ok<ASGLU>
end
function reject(fn)
raised=false;try,fn();catch,raised=true;end;assert(raised,'Invalid native call was accepted');
end

function coreStartup(),h=PsychMetalCore('ConfirmStartup');end
