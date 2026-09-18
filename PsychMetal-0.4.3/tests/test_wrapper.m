function test_wrapper(root)
% Public API contract checks with a deterministic native boundary.
addpath(root);addpath(fullfile(root,'tests','mock'),'-begin');
guard=onCleanup(@() rmpath(fullfile(root,'tests','mock')));
clear PsychMetal PsychMetalCore
global PMTestCalls PMTestArgs PMTestStartupFail;
PMTestStartupFail=false;
PMTestCalls={};
for opts={{[],0,3,false,true},{[],0,3,false,[],true},{struct('refreshHz',60,'displaySync',true)}}
 w=PsychMetal('OpenWindow',opts{1}{:});PsychMetal('Close',w);
end
PMTestCalls={};w=PsychMetal('OpenWindow');
assert(find(strcmp(PMTestCalls,'SetBackgroundColor'),1)<find(strcmp(PMTestCalls,'ConfirmStartup'),1));
assert(find(strcmp(PMTestCalls,'ConfirmStartup'),1)<find(strcmp(PMTestCalls,'PrefetchDrawable'),1));
PsychMetal('Close',w);
PMTestStartupFail=true;PMTestCalls={};reject(@() PsychMetal('OpenWindow'));
assert(strcmp(PMTestCalls{end},'Close'));
PMTestStartupFail=false;w=PsychMetal('OpenWindow');PsychMetal('Close',w);
m=PsychMetal('Resolution',0);assert(m.width==800);
m=PsychMetal('Resolutions',0);assert(numel(m)==2);
PsychMetal('Resolution',0,1024,768);
reject(@() PsychMetal('Resolution',0,800));
reject(@() PsychMetal('OpenWindow',[],0,3,NaN));
w=PsychMetal('OpenWindow');
reject(@() PsychMetal('DrawDots',w,[NaN;1],1));
reject(@() PsychMetal('DrawDots',w,[1;1],-1));
reject(@() PsychMetal('DrawDots',w,[1;1],1,255,[0 0],1,99));
reject(@() PsychMetal('DrawLines',w,[0 1;0 1],-1));
reject(@() PsychMetal('DrawLines',w,[0 1;0 1],1,255,[0 0 3]));
reject(@() PsychMetal('DrawLines',w,[0 1;0 1],1,255,[0 0],99));
reject(@() PsychMetal('KbQueueCreate',sparse(1,23,1,1,256)));
t=PsychMetal('MakeTexture',w,single(ones(2)));
assert(isa(PMTestArgs{1},'single') && isequal(size(PMTestArgs{1}),[2 2]));
PsychMetal('UpdateTexture',w,t,uint8(ones(3)*255));
assert(isa(PMTestArgs{2},'uint8'));
reject(@() PsychMetal('DrawTexture',w,t,[NaN 0 1 1]));
PsychMetal('DrawTexture',w,t);assert(isequal(PMTestArgs{2},[0 0 1 1]));
PsychMetal('CloseTexture',w,t);u=PsychMetal('MakeTexture',w,zeros(2));assert(u~=t);
reject(@() PsychMetal('DrawTexture',w,t));
reject(@() PsychMetal('UpdateTexture',w,t,zeros(2)));
PMTestCalls={};PsychMetal('Flip',w);assert(isequal(PMTestCalls,{'Flip'}));
PsychMetal('Close',w);v=PsychMetal('OpenWindow');assert(v~=w);
reject(@() PsychMetal('FillRect',w,255));PsychMetal('Close',v);
source=fileread(fullfile(root,'PsychMetal.m'));source=source(1:strfind(source,'function printGeneralHelp')-1);
tokens=regexp(source,'\n\s*case\s+(\{[^}]*\}|''[a-z0-9]+'')','tokens');names={};
for k=1:numel(tokens),names=[names regexp(tokens{k}{1},'''([a-z0-9]+)''','tokens')];end
for k=1:numel(names),evalc('PsychMetal([names{k}{1} ''?''])');end
fprintf('PASS: wrapper contracts, native call count, expired handles, named options and %d help topics.\n',numel(names));
end
function reject(fn)
raised=false;try,fn();catch,raised=true;end;assert(raised,'Invalid input was accepted');
end
