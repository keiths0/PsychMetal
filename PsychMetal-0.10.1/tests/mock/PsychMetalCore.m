function varargout=PsychMetalCore(cmd,varargin)
global PMTestCalls PMTestArgs PMTestHandle PMTestWindow PMTestStartupFail PMTestOpenArgs PMTestLink;
if isempty(PMTestCalls),PMTestCalls={};end
PMTestCalls{end+1}=cmd; PMTestArgs=varargin;
switch lower(cmd)
case 'confirmstartup'
 if ~isempty(PMTestStartupFail)&&PMTestStartupFail,error('Synthetic startup failure');end
 varargout={[1 1 0 1 1 1;2 0 1.1 1.1 1 1;3 0 1.2 1.2 1 1]};
case 'defaultpresentation',varargout={false};
case 'version', varargout={'0.10.1'};
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
case 'layouttext'
 % The engine's layout (PsychMetalShared.cpp), with this file's measure: 10 per character.
 txt=strrep(strrep(varargin{1},char([13 10]),char(10)),char(13),char(10));wrap=varargin{4};
 paragraphs=regexp(txt,char(10),'split');lines={};
 if isfinite(wrap)
  for p=1:numel(paragraphs)
   words=regexp(paragraphs{p},' +','split');line='';width=0;
   for k=1:numel(words)
    if isempty(words{k}),continue;end
    wd=10*numel(words{k})-2;
    if ~isempty(line) && width+12+wd>wrap-2,lines{end+1}=line;line='';width=0;end %#ok<AGROW>
    if isempty(line),line=words{k};width=wd;else,line=[line ' ' words{k}];width=width+12+wd;end %#ok<AGROW>
   end
   lines{end+1}=line; %#ok<AGROW>
  end
 else
  lines=paragraphs;
 end
 sizes=zeros(numel(lines),2);
 for k=1:numel(lines),if ~isempty(lines{k}),sizes(k,:)=[10*numel(lines{k}) 24];end,end
 if ~any(sizes(:,1)),error('The text must not be empty.');end
 varargout={lines,sizes,18};
case 'drawtext',assert(nargout==1);varargout={[10*numel(varargin{1}) 24 18]};
case {'blendmode','gamma','gammatable'}, assert(nargout==0);
case {'settarget','clip','drawpolygon'}, assert(nargout==0);
case 'openoffscreen'
 if isempty(PMTestHandle),PMTestHandle=0;end
 PMTestHandle=PMTestHandle+1; varargout={PMTestHandle};
case 'queueflip',varargout={[7 1 13]};
case 'queueresults',varargout={[varargin{1} 2 0 7]};
case 'queuecancel',varargout={2};
case 'recentframes',assert(varargin{1}>=1 && varargin{1}<=256);varargout={[6 0 1.5 1.49;7 2 0 1.51]};
case 'environment',varargout={struct('engineVersion','0.10.1','platform','scripted','osVersion','test OS','gpuName','scripted GPU','gpuAvailable',true,'debuggerAttached',false)};
case 'mouseevents',varargout={[1.5 1 1 10 20],0};
case 'touchevents',varargout={[2.5 1 0 30 40],0};
case {'prepareapp','setbackgroundcolor','close','closetexture','updatetexture','addshapes','drawtextures','kbqueuecreate'}
otherwise,error('Unexpected native call %s',cmd);
end
end
