function PsychMetalStimulusDemo(seconds, maskFile)
% Reusable GPU carriers/masks. Space toggles noise/grating; click/Escape exits.
% Optional maskFile: black pixels inside; otherwise a soft circular aperture.
if nargin<1 || isempty(seconds),seconds=20;end
[w,r]=PsychMetal('OpenWindow');
windowGuard=onCleanup(@() closeWindow(w)); %#ok<NASGU>
width=r(3);height=r(4);
background=PsychMetal('MakeStimulus','noise',struct('colour',true,'seed',13));
noise=PsychMetal('MakeStimulus','noise',struct('colour',true,'seed',37));
grating=PsychMetal('MakeStimulus','grating',struct('frequency',.025,'contrast',.9));
if nargin>=2 && ~isempty(maskFile)
 img=imread(maskFile);coverage=single(all(img==0,3));
else
 [x,y]=meshgrid(linspace(-1,1,128));
 coverage=single(min(1,max(0,(1-sqrt(x.^2+y.^2))/.12)));
end
mask=PsychMetal('MakeTexture',w,coverage);
patchH=height/2;patchW=patchH*size(coverage,2)/size(coverage,1);
assert(patchW<=width,'Mask too wide for the screen.');
PsychMetal('SetMouse',w,width/2,height/2);
PsychMetal('HideCursor');cursorGuard=onCleanup(@restoreCursor); %#ok<NASGU>
PsychMetal('KbWait',true);
start=PsychMetal('GetSecs');previousSpace=false;showNoise=false;
fprintf('Space switches grating/noise. Mouse moves aperture. Click or Escape exits.\n');
while PsychMetal('GetSecs')-start<seconds
 [x,y,buttons]=PsychMetal('GetMouse',w);[down,~,keys]=PsychMetal('KbCheck');
 if any(buttons)||(down&&keys(PsychMetal('KbName','ESCAPE'))),break;end
 space=keys(PsychMetal('KbName','space'));
 if space && ~previousSpace,showNoise=~showNoise;end
 previousSpace=space;
 t=PsychMetal('GetSecs')-start;
 x=min(width-patchW/2,max(patchW/2,x));y=min(height-patchH/2,max(patchH/2,y));
 left=round(x-patchW/2);top=round(y-patchH/2);
 dst=[left top left+round(patchW) top+round(patchH)];
 PsychMetal('FillRect',w,[0 0 0]);
 PsychMetal('DrawStimulus',w,background,[(width-height)/2 0 (width+height)/2 height]);
 stimulus=grating;if showNoise,stimulus=noise;end
 PsychMetal('DrawStimulus',w,stimulus,dst,mask,struct('phase',-180*t,'orientation',30));
 PsychMetal('Flip',w);
end
end
function closeWindow(w)
try,PsychMetal('Close',w);catch,end
end
function restoreCursor()
try,PsychMetal('ShowCursor');catch,end
end
