function test_headless(root)
addpath(root);clear PsychMetal PsychMetalCore
assert(strcmp(PsychMetalCore('Version'),'0.4.3'));
reject(@() coreQueue());reject(@() corePrepare());reject(@() coreStartup());
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
function coreQueue(),t=PsychMetalCore('Queue');end
function corePrepare(),t=PsychMetalCore('PrepareFlip');end
function reject(fn)
raised=false;try,fn();catch,raised=true;end;assert(raised,'Invalid native call was accepted');
end

function coreStartup(),h=PsychMetalCore('ConfirmStartup');end
