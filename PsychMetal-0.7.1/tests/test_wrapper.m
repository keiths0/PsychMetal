function test_wrapper(root)
% Public API contract checks with a deterministic native boundary.
addpath(root);addpath(fullfile(root,'tests','mock'),'-begin');
guard=onCleanup(@() rmpath(fullfile(root,'tests','mock')));
clear PsychMetal PsychMetalCore
global PMTestCalls PMTestArgs PMTestStartupFail PMTestOpenArgs;
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
% What became of the frame is asked of the engine when FlipInfo is called, not kept from Flip.
PMTestCalls={};info=PsychMetal('FlipInfo',w);assert(isequal(PMTestCalls,{'FlipStatus'}));
assert(~info.confirmed && info.dropped && info.droppedFrames==3 && info.flips==1);
% Readback is chosen at OpenWindow, by name only; GetImage needs it.
reject(@() PsychMetal('GetImage',w));
PsychMetal('Close',w);
reject(@() PsychMetal('OpenWindow',struct('readback',2)));
w=PsychMetal('OpenWindow',struct('refreshHz',60));
assert(isequal(PMTestOpenArgs,{-1,3,0,1,1,60}));PsychMetal('Close',w);
w=PsychMetal('OpenWindow',struct('refreshHz',60,'readback',true));
assert(isequal(PMTestOpenArgs,{-1,3,0,1,1,60,1}));PsychMetal('Close',w);
w=PsychMetal('OpenWindow',struct('readback',true));
assert(isequal(PMTestOpenArgs,{-1,3,0,1,1,[],1}));
PMTestCalls={};g=PsychMetal('GetImage',w);assert(isequal(PMTestCalls,{'GetImage'}) && isempty(PMTestArgs));
assert(isa(g,'uint8') && isequal(size(g),[600 800 3]));
PsychMetal('GetImage',w,[1;2;30;40]);assert(isequal(PMTestArgs,{[1 2 30 40]}));
PsychMetal('GetImage',w,[]);assert(isempty(PMTestArgs));
reject(@() PsychMetal('GetImage',w,[1 2 3]));
reject(@() PsychMetal('GetImage',w,[1 2 30 40],5));
PsychMetal('Close',w);
% 0.7.1: bit depth, partial updates, blending, linearization, text and the link report.
global PMTestLink;
reject(@() PsychMetal('OpenWindow',struct('bitDepth',12)));
w=PsychMetal('OpenWindow',struct('bitDepth',10));assert(isequal(PMTestOpenArgs,{-1,3,0,1,1,[],0,10}));PsychMetal('Close',w);
w=PsychMetal('OpenWindow',struct('bitDepth',8));assert(isequal(PMTestOpenArgs,{-1,3,0,1,1}));
t=PsychMetal('MakeTexture',w,zeros(6,8,'uint8'));
PMTestCalls={};PsychMetal('UpdateTexture',w,t,ones(2,3,'uint8'),[4 1 7 3]);
assert(isequal(PMTestCalls,{'UpdateTexture'}) && isequal(PMTestArgs([1 3 4]),{t,4,1}));
PsychMetal('DrawTexture',w,t);assert(isequal(PMTestArgs{3},[396;297;404;303]),'a partial update keeps the texture size');
reject(@() PsychMetal('UpdateTexture',w,t,ones(2,3,'uint8'),[4 1 6 3]));
reject(@() PsychMetal('UpdateTexture',w,t,ones(2,3,'uint8'),[4.5 1 7.5 3]));
assert(strcmp(PsychMetal('BlendFunction',w),'alpha'));
assert(strcmp(PsychMetal('BlendFunction',w,'add'),'alpha') && isequal(PMTestArgs,{1}));
assert(strcmp(PsychMetal('BlendFunction',w,'Alpha'),'add') && isequal(PMTestArgs,{0}));
assert(strcmp(PsychMetal('BlendFunction',w,'copy'),'alpha') && isequal(PMTestArgs,{2}));PsychMetal('BlendFunction',w,'alpha');
reject(@() PsychMetal('BlendFunction',w,'multiply'));
reject(@() PsychMetal('BlendFunction',w,1));
PMTestCalls={};PsychMetal('Linearize',w,2);assert(isequal(PMTestCalls,{'Gamma'}) && isequal(PMTestArgs,{.5,.5,.5}));
PsychMetal('Linearize',w,[2 4 1]);assert(isequal(PMTestArgs,{.5,.25,1}));
assert(isequal(PsychMetal('Linearize',w),[2 4 1]));
ramp=linspace(0,1,5)'*[1 1 1];PMTestCalls={};PsychMetal('Linearize',w,ramp);
assert(isequal(PMTestCalls,{'GammaTable'}) && isequal(PMTestArgs,{ramp}));
PsychMetal('Linearize',w,[]);assert(isequal(PMTestArgs,{1,1,1}) && isempty(PsychMetal('Linearize',w)));
reject(@() PsychMetal('Linearize',w,0));
reject(@() PsychMetal('Linearize',w,[2 2]));
reject(@() PsychMetal('Linearize',w,ramp*2));
reject(@() PsychMetal('Linearize',w,[0 .5 1]'*[1 1]));
[r,ascent]=PsychMetal('TextBounds',w,'abc');assert(isequal(r,[0 0 30 24]) && ascent==18 && isequal(PMTestArgs,{'abc','',20}));
PsychMetal('TextBounds',w,"abc",40,'Menlo');assert(isequal(PMTestArgs,{'abc','Menlo',40}));
PMTestCalls={};r=PsychMetal('DrawText',w,'abc',10.4,20.6,[255 0 0],32,'Menlo');
assert(isequal(PMTestCalls,{'TextBounds','DrawText'}) && isequal(PMTestArgs,{'abc','Menlo',32,10.4,20.6,[1 0 0 1]}) && isequal(r,[10 21 40 45]));
PMTestCalls={};PsychMetal('DrawText',w,'abc',10.4,20.6,[255 0 0],32,'Menlo');
assert(isequal(PMTestCalls,{'DrawText'}),'a text drawn again is not measured again');
PMTestCalls={};r=PsychMetal('DrawText',w,'abcd');
assert(isequal(PMTestCalls,{'TextBounds','DrawText'}) && isequal(PMTestArgs,{'abcd','',20,380,288,[1 1 1 1]}) && isequal(r,[380 288 420 312]));
r=PsychMetal('DrawText',w,'abcd',5);assert(isequal(r,[5 288 45 312]));
reject(@() PsychMetal('DrawText',w,['ab';'cd']));
% Lines: a newline separates them; each is centred when x is empty, and the block when y is.
PMTestCalls={};[r,ascent]=PsychMetal('DrawText',w,sprintf('ab\n\nabcdef'),[],[],255,20);
assert(isequal(PMTestCalls,{'TextBounds','TextBounds','DrawText','DrawText'}) && ascent==18);
assert(isequal(PMTestArgs,{'abcdef','',20,370,314,[1 1 1 1]}) && isequal(r,[370 262 430 338]),'three lines 26 apart, the middle one empty');
r=PsychMetal('TextBounds',w,sprintf('ab\nabcdef'),20);assert(isequal(r,[0 0 60 50]));
% Wrapping: words are 10 wide per character here and a space 10; 65 pixels holds 'aa bbb' (60) but not a third word.
PMTestCalls={};r=PsychMetal('DrawText',w,'aa bbb cc dddd',0,0,255,20,[],65);
drawn=PMTestCalls(strcmp(PMTestCalls,'DrawText'));assert(numel(drawn)==3 && isequal(PMTestArgs{1},'dddd') && isequal(r,[0 0 60 76]));
reject(@() PsychMetal('DrawText',w,'a',0,0,255,20,[],-5));
reject(@() PsychMetal('DrawText',w,'a',0,0,255,-1));
reject(@() PsychMetal('DrawText',w,42));
reject(@() PsychMetal('TextBounds',w,'a',20,'Menlo',100,1));
k=PsychMetal('LinkInfo',w);assert(isnan(k.compressed) && isequal(fieldnames(k),{'lanes';'laneGbps';'payloadGbps';'pixelGbps';'compressed'}));
PsychMetal('Close',w);
PMTestLink=[4 5.4 17.28 36.65 1];said=evalc('w=PsychMetal(''OpenWindow'');');PMTestLink=[];
assert(~isempty(strfind(said,'compressed (DSC)')) && ~isempty(strfind(said,'36.6')) && ~isempty(strfind(said,'17.3')),'the open banner reports a compressed link');
k=PsychMetal('LinkInfo',w);assert(isnan(k.lanes));PsychMetal('Close',w);
said=evalc('w=PsychMetal(''OpenWindow'');');assert(isempty(strfind(said,'DSC')));PsychMetal('Close',w);
% Offscreen windows, polygons, the clip rect, queued frames and mouse events.
w=PsychMetal('OpenWindow');
PMTestCalls={};[off,r]=PsychMetal('OpenOffscreenWindow',w,[255 0 0 0],[0 0 64 32]);
assert(isequal(PMTestCalls,{'OpenOffscreen'}) && isequal(PMTestArgs,{64,32,[1 0 0 0]}) && isequal(r,[0 0 64 32]));
assert(isequal(PsychMetal('Rect',off),[0 0 64 32]));[a,b]=PsychMetal('WindowSize',off);assert(a==64 && b==32);
PMTestCalls={};PsychMetal('FillRect',off,255);
assert(isequal(PMTestCalls,{'SetTarget','AddShapes'}) && isequal(PMTestArgs{3},[0;0;64;32]),'a rectless FillRect fills what it is drawn into');
PMTestCalls={};PsychMetal('FillOval',off,255,[1 2 3 4]);assert(isequal(PMTestCalls,{'AddShapes'}),'the target is set once');
t=PsychMetal('MakeTexture',w,zeros(4,6));
PMTestCalls={};PsychMetal('DrawTexture',off,t);
assert(isequal(PMTestCalls,{'DrawTextures'}) && isequal(PMTestArgs{3},[29;14;35;18]),'a texture is centred in what it is drawn into');
PMTestCalls={};PsychMetal('DrawText',off,'abcd',[],[],255,20);assert(isequal(PMTestArgs(4:5),{12,4}),'text is centred in what it is drawn into');
PMTestCalls={};PsychMetal('DrawTexture',w,off,[],[0 0 64 32]);
assert(isequal(PMTestCalls,{'SetTarget','DrawTextures'}) && isequal(PMTestArgs{2},[0;0;1;1]),'an offscreen window is drawn as a texture');
reject(@() PsychMetal('FillRect',off+50,255));
reject(@() PsychMetal('OpenOffscreenWindow',off));
PMTestCalls={};PsychMetal('FillRect',off,0);PsychMetal('Close',off);
assert(isequal(PMTestCalls,{'SetTarget','AddShapes','CloseTexture'}));
PMTestCalls={};PsychMetal('FillRect',w,0);assert(isequal(PMTestCalls,{'AddShapes'}),'closing the target returns drawing to the window');
reject(@() PsychMetal('FillRect',off,255));
reject(@() PsychMetal('DrawTexture',w,off));
PMTestCalls={};PsychMetal('FillPoly',w,[255 0 0],[10 10;50 10;30 40]);
assert(isequal(PMTestCalls,{'DrawPolygon'}) && isequal(PMTestArgs,{[10 50 30;10 10 40],[1 0 0 1],0}));
PsychMetal('FillPoly',w,255,[10 50 30 20;10 10 40 60]);assert(isequal(size(PMTestArgs{1}),[2 4]),'2xN points are accepted');
PsychMetal('FramePoly',w,255,[10 10;50 10;30 40]);assert(PMTestArgs{3}==1);
PsychMetal('FramePoly',w,255,[10 10;50 10;30 40],3);assert(PMTestArgs{3}==3);
reject(@() PsychMetal('FillPoly',w,255,[10 10;50 10]));
reject(@() PsychMetal('FillPoly',w,255,[10 10;50 10;30 40],3));
reject(@() PsychMetal('FramePoly',w,255,[10 10;50 10;30 40],0));
reject(@() PsychMetal('FillPoly',w,255,[10 10;50 NaN;30 40]));
assert(isempty(PsychMetal('Clip',w)));
PMTestCalls={};assert(isempty(PsychMetal('Clip',w,[10;20;30;40])) && isequal(PMTestCalls,{'Clip'}) && isequal(PMTestArgs,{[10 20 30 40]}));
assert(isequal(PsychMetal('Clip',w,[]),[10 20 30 40]) && isempty(PMTestArgs) && isempty(PsychMetal('Clip',w)));
reject(@() PsychMetal('Clip',w,[1 2 3]));
[token,pending,capacity]=PsychMetal('QueueFlip',w,5);assert(isequal(PMTestArgs,{5}) && token==7 && pending==1 && capacity==13);
reject(@() PsychMetal('QueueFlip',w));
reject(@() PsychMetal('QueueFlip',w,0));
f=PsychMetal('QueueResults',w);assert(isequal(PMTestArgs,{1}) && isequal(f,[1 2 0 7]));
PsychMetal('QueueResults',w,false);assert(isequal(PMTestArgs,{0}));
assert(PsychMetal('QueueCancel',w)==2);
[events,dropped]=PsychMetal('MouseEvents',w);assert(isequal(events,[1.5 1 1 10 20]) && dropped==0);
reject(@() PsychMetal('MouseEvents',w,1));
[events,dropped]=PsychMetal('TouchEvents',w);assert(isequal(events,[2.5 1 0 30 40]) && dropped==0);
reject(@() PsychMetal('TouchEvents',w,1));
PsychMetal('Close',w);
v=PsychMetal('OpenWindow');assert(v~=w);
reject(@() PsychMetal('FillRect',w,255));PsychMetal('Close',v);
source=fileread(fullfile(root,'PsychMetal.m'));source=source(1:strfind(source,'function printGeneralHelp')-1);
tokens=regexp(source,'\n\s*case\s+(\{[^}]*\}|''[a-z0-9]+'')','tokens');names={};
for k=1:numel(tokens),names=[names regexp(tokens{k}{1},'''([a-z0-9]+)''','tokens')];end
for k=1:numel(names),evalc('PsychMetal([names{k}{1} ''?''])');end
fprintf('PASS: wrapper contracts, native call count, expired handles, named options, readback and %d help topics.\n',numel(names));
end
function reject(fn)
raised=false;try,fn();catch,raised=true;end;assert(raised,'Invalid input was accepted');
end
