function report = PsychMetalExportDemo(path, seconds)
% Write a drifting Gabor movie without opening a presentation window.
%   PsychMetalExportDemo('stimulus.mp4', 3)
% Requires a Metal GPU and an available H.264 encoder.
if nargin<1 || isempty(path),path='psychmetal_export.mp4';end
if nargin<2 || isempty(seconds),seconds=3;end
if ~(isnumeric(seconds) && isreal(seconds) && isscalar(seconds) && isfinite(seconds) && seconds>0 && seconds<=60)
 error('seconds must be positive and at most 60.');
end
[w,~,ifi]=PsychMetal('OpenWindow',struct('exportSize',[640 480],'refreshHz',60,'backgroundColor',127));
try
 PsychMetal('StartMovieRecording',w,path,struct('codec','h264','sound',false,'clock','virtual'));
 for frame=0:max(1,round(seconds/ifi))-1
  PsychMetal('DrawGabor',w,[],[160 80 480 400],.5,.04,30,frame*6);
  PsychMetal('Flip',w);
 end
 report=PsychMetal('StopMovieRecording',w);
 PsychMetal('Close',w);
catch e
 try,PsychMetal('Close',w);catch,end
 rethrow(e);
end
fprintf('Wrote %.0f frames, %.3f s: %s\n',report.frames,report.duration,report.path);
end
