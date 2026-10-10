function report=PsychMetalOpenReadyTest(repeats)
% Verify integrated background confirmation and first stimulus across repeated opens.
% Ten opens by default, alternating immediate/scheduled first frames and backgrounds.
if nargin<1||isempty(repeats),repeats=10;end
assert(isscalar(repeats)&&isfinite(repeats)&&repeats==fix(repeats)&&repeats>=2&&repeats<=100);
base=fullfile(pwd,['PsychMetalOpenReady-' datestr(now,'yyyymmdd-HHMMSS')]);
report=struct('date',datestr(now,31),'native',which('PsychMetalCore'),'runs',{{}},'complete',false,'error','');w=[];
try
 for k=1:repeats
  [down,~,keys]=PsychMetal('KbCheck');if down&&keys(41),error('Aborted with Escape');end
  backgrounds=[0 32 64];bg=backgrounds(mod(k-1,3)+1);opened=tic;
  [w,r,ifi]=PsychMetal('OpenWindow',[],bg);openSeconds=toc(opened);
  before=PsychMetal('Diagnostic',w);
  assert(isfield(before,'startup'),'This test requires the ready candidate');
  st=before.startup;assert(numel(st.status)>=2 && all(st.status(end-1:end)==0),'Startup was not confirmed');
  assert(isempty(before.actualStatus),'Startup frames leaked into stimulus history');
  assert(all(abs(before.summary.backgroundColor(1:3)-bg/255)<1e-12),'Wrong requested background');
  PsychMetal('FillRect',w,128,[r(3)*.4 r(4)*.4 r(3)*.6 r(4)*.6]);
  target=NaN;mode='immediate';if mod(k,2)==0,target=PsychMetal('GetSecs')+.25;mode='scheduled';end
  flipError='';
  try
   if isfinite(target),PsychMetal('Flip',w,target);else,PsychMetal('Flip',w);end
  catch err
   if isempty(strfind(err.message,'Presentation callback returned no timestamp.')),rethrow(err);end
   flipError=err.message;
  end
  d=PsychMetal('Diagnostic',w);assert(numel(d.actualStatus)==1,'Expected exactly one stimulus record');
  confirmed=d.actualStatus(1)==0;delta=(d.actualTimestamp(1)-target)*1000;
  deadlineOK=~isfinite(target) || (isfinite(delta)&&delta>=-.2&&delta<=ifi*1000+2);
  good=confirmed&&deadlineOK&&isempty(flipError);
  pause(.15);PsychMetal('Close',w);w=[];
  run=struct('iteration',k,'mode',mode,'background',bg,'openSeconds',openSeconds,'startup',st, ...
   'target',target,'ifi',ifi,'deadlineErrorMs',delta,'history',d,'flipError',flipError,'ok',good);
  report.runs{end+1}=run;saveReport(report,base);printRun(1,run);
 end
 report.complete=true;
catch err
 if ~isempty(w),try,PsychMetal('Close',w);catch,end;end
 report.error=err.message;
 try,report.failedStartupRaw=PsychMetalCore('StartupHistory');catch,end
 saveReport(report,base);rethrow(err);
end
saveReport(report,base);fprintf('Saved %s.txt and .mat\n',base);
end
function printRun(fid,r)
fprintf(fid,'Open %d %s, background %g: %s, stimulus status %d, deadline error %.3f ms, startup %d attempts / %.3f s, whole Open %.3f s\n', ...
 r.iteration,r.mode,r.background,label(r.ok),r.history.actualStatus(1),r.deadlineErrorMs,numel(r.startup.status),r.startup.seconds,r.openSeconds);
fprintf(fid,'  Startup statuses: ');fprintf(fid,'%d ',r.startup.status);fprintf(fid,'\n');
end
function s=label(ok)
if ok,s='PASS';else,s='FAIL';end
end
function saveReport(report,base)
save([base '.mat'],'report','-v7');fid=fopen([base '.txt'],'w');assert(fid>=0);guard=onCleanup(@() fclose(fid));
fprintf(fid,'Open readiness test %s\nNative %s\nStartup frames retained separately; no stimulus frames discarded.\n',report.date,report.native);
fprintf(fid,'Scheduled checks allow the next refresh boundary plus 2 ms tolerance; software timing, not physical onset.\n');
passed=0;for k=1:numel(report.runs),r=report.runs{k};printRun(fid,r);passed=passed+r.ok;end
fprintf(fid,'Passed %d/%d completed opens. Complete %d; error %s\n',passed,numel(report.runs),report.complete,report.error);
end
