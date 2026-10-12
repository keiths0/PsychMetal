function PsychMetalShaderDemo(seconds)
% Custom GPU spiral, using exactly the source used by the Python/phone demo.
if nargin<1 || isempty(seconds),seconds=20;end
[w,r,ifi]=PsychMetal('OpenWindow');guard=onCleanup(@() closeWindow(w)); %#ok<NASGU>
source=fileread(fullfile(fileparts(mfilename('fullpath')),'python','custom-shader-demo.metal'));
shader=PsychMetal('CreateShader',w,source);mask=PsychMetal('MakeMask','gaussian',struct('sigma',.4));
side=.7*min(r(3),r(4));center=r(3:4)/2;dst=[center-side/2 center+side/2];
escape=PsychMetal('KbName','ESCAPE');
fprintf('Custom Metal spiral, shared source on Mac and phone. Escape exits.\n');
for frame=0:max(1,round(seconds/ifi))-1
 [~,~,keys]=PsychMetal('KbCheck');if keys(escape),break;end
 PsychMetal('FillRect',w,127.5);
 PsychMetal('DrawShader',w,shader,[.025 frame*ifi*pi],dst,mask);
 PsychMetal('Flip',w);
end
end
function closeWindow(w)
try,PsychMetal('Close',w);catch,end
end
