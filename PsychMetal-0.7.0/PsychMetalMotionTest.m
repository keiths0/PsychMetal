function report=PsychMetalMotionTest(n,frames)
% Compare preloaded reference (left) with UpdateTexture (right).
% Both panels must move right together, with matching phase and brightness.
% Inputs are precomputed single-precision frames; no image generation in loop.
if nargin<1||isempty(n),n=1024;end
if nargin<2||isempty(frames),frames=600;end
assert(isscalar(n)&&isfinite(n)&&n==fix(n)&&n>=64&&n<=2048,'n must be 64..2048');
assert(isscalar(frames)&&isfinite(frames)&&frames==fix(frames)&&frames>=60&&frames<=12000,'frames must be 60..12000');
base=fullfile(pwd,['PsychMetalMotion-' datestr(now,'yyyymmdd-HHMMSS')]);
w=[];report=struct('size',n,'frames',frames,'host',version,'native',which('PsychMetalCore'),'error','','complete',false);
fprintf('Precomputing 32 frames. LEFT: preloaded reference. RIGHT: updated texture.\n');
fprintf('Both must move RIGHT together, with matching phase, orientation and brightness. Escape aborts.\n');
images=cell(1,32);x=single((0:n-1)/n);
for j=1:32
 row=single(.5+.4*cos(2*pi*(3*x-(j-1)/32)));
 images{j}=repmat(row,n,1);
 % Static asymmetric markers expose flips and transposes.
 images{j}(1:ceil(n/12),1:ceil(n/6))=1;
 images{j}(end-ceil(n/12)+1:end,end-ceil(n/6)+1:end)=0;
end
try
 [w,r,ifi]=PsychMetal('OpenWindow');side=min(r(3)*.44,r(4)*.8);cy=r(4)/2;
 left=[r(3)*.25-side/2 cy-side/2 r(3)*.25+side/2 cy+side/2];
 right=left+[r(3)*.5 0 r(3)*.5 0];
 refs=zeros(1,32);for j=1:32,refs(j)=PsychMetal('MakeTexture',w,images{j});end
 t=PsychMetal('MakeTexture',w,images{1});count=120+frames;upload=zeros(count,1);missing=false(count,1);
 for k=1:count
  [down,~,keys]=PsychMetal('KbCheck');if down&&keys(41),error('Aborted with Escape');end
  j=mod(k-1,32)+1;began=tic;PsychMetal('UpdateTexture',w,t,images{j});upload(k)=toc(began)*1000;
  PsychMetal('DrawTexture',w,refs(j),[],left);
  PsychMetal('DrawTexture',w,t,[],right);
  try,PsychMetal('Flip',w);catch err
   if isempty(strfind(err.message,'Presentation callback returned no timestamp.')),rethrow(err);end
   missing(k)=true;
  end
 end
 d=PsychMetal('Diagnostic',w);PsychMetal('Close',w);w=[];
 report.history=d;report.uploadMs=upload;report.missingAtFlip=missing;report.stats=PsychMetalFrameStats(d,ifi,120);
 report.warmupMissing=sum(d.actualStatus(1:120)==1);report.measuredMissing=sum(d.actualStatus(121:end)==1);
 ts=d.actualTimestamp(121:end);ts=ts(isfinite(ts)&d.actualStatus(121:end)==0);hz=NaN;
 if numel(ts)>1&&ts(end)>ts(1),hz=(numel(ts)-1)/(ts(end)-ts(1));end
 report.deliveryHz=hz;report.complete=true;save([base '.mat'],'report','-v7');
 fid=fopen([base '.txt'],'w');assert(fid>=0);guard=onCleanup(@() fclose(fid));
 text=sprintf('Motion test %dx%d: delivery %.3f Hz; %d/%d confirmed; %d long adjacent intervals; missing warm-up/measured %d/%d; median upload %.3f ms.\n', ...
 n,n,hz,report.stats.confirmed,frames,report.stats.skipped,report.warmupMissing,report.measuredMissing,median(upload(121:end)));
 fprintf('%sSaved %s.txt and .mat\n',text,base);fprintf(fid,'%sNative: %s\nVisual match requires user confirmation.\n',text,report.native);
catch err
 if ~isempty(w),try,PsychMetal('Close',w);catch,end;end
 report.error=err.message;save([base '.mat'],'report','-v7');rethrow(err);
end
end
