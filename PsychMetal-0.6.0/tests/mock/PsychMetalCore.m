function varargout=PsychMetalCore(cmd,varargin)
global PMTestCalls PMTestArgs PMTestHandle PMTestWindow PMTestStartupFail PMTestOpenArgs PMTestLink;
if isempty(PMTestCalls),PMTestCalls={};end
PMTestCalls{end+1}=cmd; PMTestArgs=varargin;
switch lower(cmd)
case 'confirmstartup'
 if ~isempty(PMTestStartupFail)&&PMTestStartupFail,error('Synthetic startup failure');end
 varargout={[1 1 0 1 1 1;2 0 1.1 1.1 1 1;3 0 1.2 1.2 1 1]};
case 'version', varargout={'0.6.0'};
case 'open'
 PMTestOpenArgs=varargin;
 if isempty(PMTestWindow),PMTestWindow=0;end
 PMTestWindow=PMTestWindow+1; varargout={800,600,1/60,800,600,PMTestWindow};
case 'maketexture'
 if isempty(PMTestHandle),PMTestHandle=0;end
 PMTestHandle=PMTestHandle+1; varargout={PMTestHandle};
case 'modes', varargout={[800 600 800 600 60;1024 768 1024 768 60]};
case 'setmode', assert(nargout==0);
case 'setmouse', assert(nargout==0 && nargin==3);
case 'gridanchor',varargout={[0 1/60 30]};
case 'flip',varargout={[1 0 0 1/60 1 2 1.1 1]};
case 'flipstatus',varargout={[0 1 3]};
case 'getimage',varargout={zeros(600,800,3,'uint8')};
case 'linkinfo'
 if isempty(PMTestLink),PMTestLink=[NaN NaN NaN NaN NaN];end
 varargout={PMTestLink};
case 'textbounds',varargout={[10*numel(varargin{1}) 24 18]};
case 'drawtext',assert(nargout==1);varargout={[10*numel(varargin{1}) 24 18]};
case {'blendmode','gamma','gammatable'}, assert(nargout==0);
case {'settarget','clip','drawpolygon'}, assert(nargout==0);
case 'openoffscreen'
 if isempty(PMTestHandle),PMTestHandle=0;end
 PMTestHandle=PMTestHandle+1; varargout={PMTestHandle};
case 'queueflip',varargout={[7 1 13]};
case 'queueresults',varargout={[varargin{1} 2 0 7]};
case 'queuecancel',varargout={2};
case 'mouseevents',varargout={[1.5 1 1 10 20],0};
case {'prepareapp','setbackgroundcolor','prefetchdrawable','close','closetexture','updatetexture','addshapes','drawtextures','kbqueuecreate'}
otherwise,error('Unexpected native call %s',cmd);
end
end
