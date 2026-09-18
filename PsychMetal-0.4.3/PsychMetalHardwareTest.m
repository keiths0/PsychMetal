function PsychMetalHardwareTest
% Manual display acceptance plus session/texture lifecycle checks.
% The visible frame should show dark gray on the left, white in the middle,
% and green on the right. Run on a physical display after restarting the host.
w=[];
try
 [w,r]=PsychMetal('OpenWindow');
 oldWindow=w; H=r(4); W=r(3);
 tex=PsychMetal('MakeTexture',w,single(ones(64)*.25));
 PsychMetal('DrawTexture',w,tex,[],[0 0 W/3 H]);
 PsychMetal('UpdateTexture',w,tex,uint8(ones(64)*255));
 PsychMetal('DrawTexture',w,tex,[],[W/3 0 2*W/3 H]);
 PsychMetal('CloseTexture',w,tex);
 green=zeros(64,64,3,'single');green(:,:,2)=1;
 next=PsychMetal('MakeTexture',w,green);
 assert(next~=tex,'Texture handle was reused');
 reject(@() PsychMetal('DrawTexture',w,tex));
 PsychMetal('DrawTexture',w,next,[],[2*W/3 0 W H]);
 PsychMetal('Flip',w);pause(3);
 PsychMetal('PrepareFlip',w);
 PsychMetal('Close',w);w=[];
 [w,r]=PsychMetal('OpenWindow');
 assert(w~=oldWindow,'Window handle was reused');
 reject(@() PsychMetal('Flip',oldWindow));
 PsychMetal('FillRect',w,[0 0 255],r);
 PsychMetal('PrepareFlip',w);PsychMetal('PresentNow',w);pause(1);
 PsychMetal('Close',w);w=[];
 fprintf('PASS: texture snapshots/handles and close-after-prepare/reopen calls completed.\n');
 fprintf('Visual acceptance requires gray | white | green, then a blue frame.\n');
catch err
 if ~isempty(w),try,PsychMetal('Close',w);catch,end;end
 rethrow(err);
end
end
function reject(f)
raised=false;try,f();catch,raised=true;end
assert(raised,'A stale handle was accepted');
end
