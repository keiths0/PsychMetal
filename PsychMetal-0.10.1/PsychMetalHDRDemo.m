function report=PsychMetalHDRDemo(seconds,flickerHzTarget)
% Pairwise 0.5..16x HDR flicker grid with steady references and live headroom.
if nargin<1,seconds=20;end
if nargin<2,flickerHzTarget=16;end
assert(isnumeric(flickerHzTarget)&&isreal(flickerHzTarget)&&isscalar(flickerHzTarget)&&isfinite(flickerHzTarget)&&flickerHzTarget>=1&&flickerHzTarget<=60,'flickerHzTarget must be finite and between 1 and 60 Hz.');
assert(isnumeric(seconds)&&isreal(seconds)&&isscalar(seconds)&&isfinite(seconds)&&seconds>0,'seconds must be positive and finite.');
[w,rect,ifi]=PsychMetal('OpenWindow',struct('hdr',true));
cleanup=onCleanup(@()PsychMetal('Close',w));
PsychMetal('ColorRange',w,1);
levels=[.5 1 2 4 8 12 16];n=numel(levels);textures=zeros(size(levels));
width=rect(3);height=rect(4);textSize=max(12,min(width/45,height/38));
% Confirm the refresh grid; these startup frames are excluded from the stimulus.
for warmup=1:max(60,round(1/ifi))
 [~,~,keys]=PsychMetal('KbCheck');
 if keys(41)
  report=struct('frames',0,'hdr',PsychMetal('HDRInfo',w),'levels',levels,...
   'headroomHistory',zeros(0,3),'stoppedDuringCalibration',true);return;
 end
 PsychMetal('FillRect',w,0);
 PsychMetal('DrawText',w,'Measuring display refresh...',width*.08,height*.12,1,textSize,[],width*.84);
 PsychMetal('Flip',w);
end
grid=PsychMetal('GridAnchor',w);ifi=grid(2);
assert(grid(3)>=30&&isfinite(ifi)&&ifi>0,'Could not measure the display refresh rate from confirmed frames.');
idealHalf=1/(ifi*2*flickerHzTarget);candidates=max(1,[ceil(idealHalf) floor(idealHalf)]);
[~,best]=min(abs(1./(ifi*2*candidates)-flickerHzTarget));halfFrames=candidates(best);
flickerHz=1/(ifi*2*halfFrames);
span=min(width*.78,height*.48);pitch=span/n;edge=pitch*.78;
left=(width-span)/2;top=height*.27;boxes=zeros(4,n*n+n);
for row=0:n-1
 for column=0:n-1
  x=left+(column+.5)*pitch;y=top+(row+.5)*pitch;
  boxes(:,row*n+column+1)=[x-edge/2;y-edge/2;x+edge/2;y+edge/2];
 end
end
refEdge=min([edge*.7 width*.8/(n*1.2) height*.065]);
for i=1:n
 x=width/2+(i-1-(n-1)/2)*refEdge*1.2;y=height*.82;
 boxes(:,n*n+i)=[x-refEdge/2;y;x+refEdge/2;y+refEdge];
end
% Precompute circular straight-RGBA patches with antialiased alpha edges.
diameter=max(64,ceil(max(edge,refEdge)));
coordinates=single((0:diameter-1)+.5-diameter/2);
[xx,yy]=meshgrid(coordinates);coverage=min(1,max(0,diameter/2-.5-hypot(xx,yy)));
image=ones(diameter,diameter,4,'single');image(:,:,4)=coverage;
for i=1:n
 image(:,:,1:3)=levels(i);textures(i)=PsychMetal('MakeTexture',w,image);
end
% Opposite phases in transposed cells preserve the histogram. Diagonal controls
% draw precisely the same texture for both halves of each cycle.
rowIndices=kron(1:n,ones(1,n));columnIndices=repmat(1:n,1,n);
batches=[textures(rowIndices) textures;textures(columnIndices) textures];
labelSize=max(12,min(textSize,pitch*.25));
radius=min(width,height)*.035;centers=[width*.2 height*.215;width*.65 height*.215];
hitBoxes=[centers(:,1)-radius*1.5 centers(:,2)-radius*1.5 centers(:,1)+radius*1.25+textSize*4 centers(:,2)+radius*1.5];
footer=sprintf('Diagonal = identical levels. 1x = SDR white.\n* Above headroom; may clip. Left/Right or click to adjust. Escape exits.');
t0=PsychMetal('GetSecs');nextQuery=t0;frames=0;history=zeros(0,3);
cycleFrame=0;pendingHalf=halfFrames;maxHalf=max(1,floor(1/(ifi*2)+.5));
rateHistory=[0 halfFrames flickerHz];previousKeys=false(1,2);
[~,~,buttons]=PsychMetal('GetMouse',w);wasDown=logical(buttons(1));
while PsychMetal('GetSecs')-t0<seconds
 [~,~,keys]=PsychMetal('KbCheck');if keys(41),break;end
 now=PsychMetal('GetSecs');
 arrows=logical([keys(80) keys(79)]);
 change=double(arrows(1)&&~previousKeys(1))-double(arrows(2)&&~previousKeys(2));previousKeys=arrows;
 [x,y,buttons]=PsychMetal('GetMouse',w);down=logical(buttons(1));
 if down&&~wasDown
  for i=1:2
   b=hitBoxes(i,:);
   if x>=b(1)&&x<=b(3)&&y>=b(2)&&y<=b(4),change=change+3-2*i;break;end
  end
 end
 wasDown=down;pendingHalf=max(1,min(maxHalf,pendingHalf+change));
 % Change only at a full-cycle boundary, preserving equal holds for each pair.
 if cycleFrame==0&&pendingHalf~=halfFrames
  halfFrames=pendingHalf;flickerHz=1/(ifi*2*halfFrames);
  rateHistory(end+1,:)=[now-t0 halfFrames flickerHz];nextQuery=now;
 end
 if now>=nextQuery
  info=PsychMetal('HDRInfo',w);
  history(end+1,:)=[now-t0 info.currentHeadroom info.potentialHeadroom];
  status=sprintf('Current: %.2fx | Potential: %.2fx\nFrame-grid rate: %.2f Hz; %d frames per level',...
   info.currentHeadroom,info.potentialHeadroom,flickerHz,halfFrames);
  labels=cell(size(levels));
  for i=1:n
   labels{i}=sprintf('%gx',levels(i));if levels(i)>info.currentHeadroom,labels{i}=[labels{i} ' *'];end
  end
  nextQuery=now+.5;
 end
 PsychMetal('FillRect',w,0);
 PsychMetal('DrawText',w,'HDR flicker comparisons',width*.08,height*.07,1,textSize*1.2,[],width*.84);
 PsychMetal('DrawText',w,status,width*.08,height*.12,1,textSize,[],width*.84);
 symbols={'-','+'};captions={'Slower','Faster'};
 for i=1:2
  cx=centers(i,1);cy=centers(i,2);
  PsychMetal('FillOval',w,.15,[cx-radius cy-radius cx+radius cy+radius]);
  PsychMetal('DrawText',w,symbols{i},cx-textSize*.45,cy-textSize*.7,1,textSize*1.5);
  PsychMetal('DrawText',w,captions{i},cx+radius*1.25,cy-textSize*.6,1,textSize);
 end
 phase=floor(cycleFrame/halfFrames)+1;
 PsychMetal('DrawTextures',w,batches(phase,:),[],boxes);
 for i=1:n
  PsychMetal('DrawText',w,sprintf('%gx',levels(i)),left+(i-.5)*pitch-edge/2,top-pitch*.35,1,labelSize);
  PsychMetal('DrawText',w,sprintf('%gx',levels(i)),left-pitch*.65,top+(i-.5)*pitch-labelSize*.6,1,labelSize);
  b=boxes(:,n*n+i);
  PsychMetal('DrawText',w,labels{i},b(1),b(4)+refEdge*.06,1,max(12,min(textSize,refEdge/2.5)));
 end
 PsychMetal('DrawText',w,'Steady references',width*.08,height*.775,1,textSize*.85,[],width*.84);
 PsychMetal('DrawText',w,footer,width*.08,height*.925,1,textSize*.75,[],width*.84);
 PsychMetal('Flip',w);frames=frames+1;cycleFrame=mod(cycleFrame+1,2*halfFrames);
end
info=PsychMetal('HDRInfo',w);history(end+1,:)=[PsychMetal('GetSecs')-t0 info.currentHeadroom info.potentialHeadroom];
fprintf('HDR flicker: %.3f Hz on the measured frame grid; %d frames per level.\n',flickerHz,halfFrames);disp(info);
report=struct('frames',frames,'hdr',info,'levels',levels,'headroomHistory',history,...
 'ifi',ifi,'halfCycleFrames',halfFrames,'flickerHz',flickerHz,...
 'requestedHz',flickerHzTarget,'rateHistory',rateHistory);
end
