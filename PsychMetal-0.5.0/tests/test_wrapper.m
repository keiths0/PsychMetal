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
% Texture draws as the native call receives them. t is 3x3 after the update,
% t2 5 wide and 3 high; the window is 800x600. DrawTexture is DrawTextures
% with one texture, so every case is one native call.
PsychMetal('DrawTexture',w,t);assert(isequal(PMTestArgs{2},[0;0;1;1]) && isequal(PMTestArgs{3},[398.5;298.5;401.5;301.5]));
t2=PsychMetal('MakeTexture',w,zeros(3,5));
PMTestCalls={};PsychMetal('DrawTexture',w,t2,[0 0 5 1],[40 30 10 5],90,0,51,[255 0 0]);
assert(isequal(PMTestCalls,{'DrawTextures'}));a=PMTestArgs;
assert(a{1}==t2 && max(abs(a{2}-[0;0;1;1/3]))<1e-12 && isequal(a{3},[10;5;40;30]) && abs(a{4}-pi/2)<1e-12 ...
    && max(abs(a{5}-[1;0;0;.2]))<1e-12 && a{6}==0,'DrawTexture arguments');
PsychMetal('DrawTextures',w,[t t2],[0 0 1 1],[5 5 25 25],[0 180],[1 0],[255 102],[255 0;0 255;0 0]);a=PMTestArgs;
assert(isequal(a{1},[t t2]) && max(max(abs(a{2}-[0 0;0 0;1/3 1/5;1/3 1/3])))<1e-12 && isequal(a{3},repmat([5;5;25;25],1,2)) ...
    && max(abs(a{4}-[0 pi]))<1e-12 && max(max(abs(a{5}-[1 0;0 1;0 0;1 .4])))<1e-12 && isequal(a{6},[1 0]),'DrawTextures arguments');
PsychMetal('DrawTextures',w,t,[],[0 100;0 100;10 150;10 120]);
assert(isequal(PMTestArgs{1},[t t]) && isequal(PMTestArgs{2},[0 0;0 0;1 1;1 1]) && isequal(PMTestArgs{6},[1 1]));
reject(@() PsychMetal('DrawTextures',w,[t t2 t],[],zeros(4,2)));
reject(@() PsychMetal('DrawTextures',w,[t 99]));
reject(@() PsychMetal('DrawTextures',w,t,[],[],[],[0 2]));
reject(@() PsychMetal('DrawTexture',w,t,[],[],0,[255 0 0 128]));
reject(@() PsychMetal('DrawTextures',w,t,[0 0 1]));
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
