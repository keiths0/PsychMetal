function varargout=PsychMetalCore(cmd,varargin)
global PMTestCalls PMTestArgs PMTestHandle PMTestWindow PMTestStartupFail;
if isempty(PMTestCalls),PMTestCalls={};end
PMTestCalls{end+1}=cmd; PMTestArgs=varargin;
switch lower(cmd)
case 'confirmstartup'
 if ~isempty(PMTestStartupFail)&&PMTestStartupFail,error('Synthetic startup failure');end
 varargout={[1 1 0 1 1 1;2 0 1.1 1.1 1 1;3 0 1.2 1.2 1 1]};
case 'version', varargout={'0.4.3'};
case 'open'
 if isempty(PMTestWindow),PMTestWindow=0;end
 PMTestWindow=PMTestWindow+1; varargout={800,600,1/60,800,600,PMTestWindow};
case 'maketexture'
 if isempty(PMTestHandle),PMTestHandle=0;end
 PMTestHandle=PMTestHandle+1; varargout={PMTestHandle};
case 'modes', varargout={[800 600 800 600 60;1024 768 1024 768 60]};
case 'setmode', assert(nargout==1);varargout={1};
case 'gridanchor',varargout={[0 1/60 30]};
case 'flip',varargout={[1 0 0 0 0 0 1/60 1 2 1.1 1]};
case {'prepareapp','setbackgroundcolor','prefetchdrawable','close','closetexture','updatetexture','addshapes','drawtexture','kbqueuecreate'}
otherwise,error('Unexpected native call %s',cmd);
end
end
