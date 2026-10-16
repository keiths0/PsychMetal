function PsychMetalMaskedImageDemo(seconds, imageFile)
% One still image, four GPU apertures. Hold/drag a panel; Escape exits.
% Optional imageFile uses imread at its original resolution (no downsampling).
if nargin<1 || isempty(seconds),seconds=20;end
[w,r]=PsychMetal('OpenWindow');guard=onCleanup(@() closeWindow(w)); %#ok<NASGU>
PsychMetal('ColorRange',w,1);
if nargin>=2 && ~isempty(imageFile)
 [image,map,alpha]=imread(imageFile);
 if ~isempty(map),image=ind2rgb(image,map);end
 if ~isempty(alpha)
  if size(image,3)==1,image=repmat(image,1,1,3);end
  image=normalImage(image);image=cat(3,image,normalImage(alpha));
 end
else
 [x,y]=meshgrid(0:255,0:255);checker=mod(floor(x/16)+floor(y/16),2);
 image=single(cat(3,x/255,y/255,.2+.6*checker));
end
if isinteger(image) && ~isa(image,'uint8'),image=normalImage(image);end
texture=PsychMetal('MakeTexture',w,image);
masks={[],PsychMetal('MakeMask','gaussian',struct('sigma',.4)), ...
 PsychMetal('MakeMask','annulus',struct('inner',.45,'edge',.12)), ...
 PsychMetal('MakeMask','raised_cosine',struct('edge',.2))};
width=r(3);height=r(4);side=.38*min(width,height);
centers=[width*.27 height*.35;width*.73 height*.35;width*.27 height*.65;width*.73 height*.65];
active=[];offset=[0 0];previous=false;PsychMetal('KbWait',true);begin=PsychMetal('GetSecs');
fprintf('Top: original / Gaussian. Bottom: annulus / raised cosine. Hold and drag any panel; Escape exits.\n');
while PsychMetal('GetSecs')-begin<seconds
 [x,y,buttons]=PsychMetal('GetMouse',w);[down,~,keys]=PsychMetal('KbCheck');
 if down && keys(PsychMetal('KbName','ESCAPE')),break;end
 pointer=[x y];held=buttons(1);
 if held && ~previous
  for i=4:-1:1
   if all(abs(pointer-centers(i,:))<=side/2),active=i;offset=centers(i,:)-pointer;break;end
  end
 end
 if ~held,active=[];end
 if ~isempty(active),centers(active,:)=pointer+offset;end
 previous=held;PsychMetal('FillRect',w,[.12 .12 .12]);
 for i=1:4
  dst=[centers(i,:)-side/2 centers(i,:)+side/2];
  PsychMetal('DrawMaskedTexture',w,texture,masks{i},[],dst);
 end
 PsychMetal('Flip',w);
end
end
function x=normalImage(x)
if isinteger(x),x=single(x)/single(intmax(class(x)));else,x=single(x);end
end
function closeWindow(w)
try,PsychMetal('Close',w);catch,end
end
