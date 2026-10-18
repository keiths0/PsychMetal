function report=PsychMetalImagingDemo(seconds)
% Reusable GPU blur, sharpening and colour-matrix processing.
if nargin<1,seconds=20;end
[w,r]=PsychMetal('OpenWindow');cleanup=onCleanup(@()PsychMetal('Close',w));
PsychMetal('ColorRange',w,1);
[x,y]=meshgrid(0:255);image=single(cat(3,.1+.8*(mod(x,32)<16),.1+.8*(mod(y,32)<16),(x+y)/510));
source=PsychMetal('MakeTexture',w,image);
ops={{struct('type','gaussian','sigma',3)},...
 {struct('type','convolution','kernel',[0 -1 0;-1 5 -1;0 -1 0])},...
 {struct('type','color_matrix','matrix',repmat([.2126 .7152 .0722],3,1)),struct('type','gaussian','sigma',1.5)}};
pipelines=zeros(1,3);outputs=zeros(1,3);
for i=1:3,pipelines(i)=PsychMetal('CreateImagePipeline',w,ops{i});outputs(i)=PsychMetal('ProcessImage',w,pipelines(i),source);end
width=r(3);height=r(4);edge=min(width/2.4,height/3.2);
boxes=[width/2-edge*1.1 height/2-edge*1.15 width/2-edge*.1 height/2-edge*.15;...
 width/2+edge*.1 height/2-edge*1.15 width/2+edge*1.1 height/2-edge*.15;...
 width/2-edge*1.1 height/2+edge*.15 width/2-edge*.1 height/2+edge*1.15;...
 width/2+edge*.1 height/2+edge*.15 width/2+edge*1.1 height/2+edge*1.15];
labels={'Original','Gaussian','Sharpen','Grey + Gaussian'};t0=PsychMetal('GetSecs');frames=0;
while PsychMetal('GetSecs')-t0<seconds
 [~,~,keys]=PsychMetal('KbCheck');if keys(41),break;end
 for i=1:3,outputs(i)=PsychMetal('ProcessImage',w,pipelines(i),source,outputs(i));end
 PsychMetal('FillRect',w,0);textures=[source outputs];
 for i=1:4
  PsychMetal('DrawTexture',w,textures(i),[],boxes(i,:));
  PsychMetal('DrawText',w,labels{i},boxes(i,1),boxes(i,2)-25,1,20);
 end
 PsychMetal('Flip',w);frames=frames+1;
end
report=struct('frames',frames);
end
