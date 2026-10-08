function report = PsychMetalBlobArrayDemo(seconds, contrast)
% Draggable Gaussian array: refresh/2, refresh/4, ... down to about 1 Hz.
% PsychMetalBlobArrayDemo(60, 0.5)
% Hold the left mouse button on a blob to drag; release to leave it. Escape
% stops. Labels travel with the blobs; overlap uses normal alpha compositing.
% Frequencies are nominal, with one cosine sample per frame. Missed refreshes
% slow the sequence (see report.frameStats). Cosine makes the highest frequency
% alternate white/black rather than sampling only the zeros of a sine wave.
% SPDX-License-Identifier: MIT
if nargin < 1 || isempty(seconds), seconds = 60; end
if nargin < 2 || isempty(contrast), contrast = .5; end
assert(isnumeric(seconds) && isscalar(seconds) && isreal(seconds) && isfinite(seconds) && seconds > 0, 'seconds must be positive and finite.');
assert(isnumeric(contrast) && isscalar(contrast) && isreal(contrast) && isfinite(contrast) && contrast > 0 && contrast <= .5, 'contrast must be in (0, 0.5].');
w = [];
try
 [w, rect, ifi] = PsychMetal('OpenWindow', []);
 assert(isfinite(ifi) && ifi > 0, 'A positive measured refresh interval is required.');
 top = .5 / ifi;
 n = max(1, floor(log2(top) + .5) + 1);
 hz = top ./ (2 .^ (0:n-1));
 width = rect(3)-rect(1); height = rect(4)-rect(2);
 cols = min(n, max(1, ceil(sqrt(n*width/height)))); rows = ceil(n/cols);
 cw = width/cols; ch = height/rows;
 half = min(cw*.42, ch*.32); textSize = max(12, min(cw*.08, ch*.08));
 centers = [(mod(0:n-1,cols)+.5)'*cw, (floor((0:n-1)/cols)+.43)'*ch];
 labels = cell(1,n); widths = zeros(1,n);
 for i=1:n
  labels{i} = sprintf('%.3g Hz', hz(i));
  b = PsychMetal('TextBounds', w, labels{i}, textSize); widths(i)=b(3);
 end
 escape = PsychMetal('KbName','ESCAPE'); order=1:n; active=0; held=false; offset=[0 0]; frames=0;
 fprintf('Blob array: '); fprintf('%g Hz ', hz); fprintf('\nHold and drag; release to leave it. Escape stops.\n');
 for k=0:max(1,round(seconds/ifi))-1
  [~,~,keys]=PsychMetal('KbCheck'); if keys(escape), break; end
  [x,y,buttons]=PsychMetal('GetMouse',w); pressed=logical(buttons(1));
  if pressed && ~held
   for j=n:-1:1
    i=order(j);
    if norm(centers(i,:)-[x y]) <= half
     active=i; offset=centers(i,:)-[x y]; order=[order(order~=i) i]; break;
    end
   end
  end
  if active && (pressed || held), centers(active,:)=[x y]+offset; end
  if ~pressed, active=0; end
  held=pressed;
  PsychMetal('FillRect',w,127.5);
  amplitude=contrast*cos(2*pi*hz*(k*ifi));
  for i=order
   x=centers(i,1); y=centers(i,2); s=amplitude(i); value=255*(s>=0);
   PsychMetal('DrawGabor',w,[value value value 510*abs(s)],[x-half y-half x+half y+half],.30);
   PsychMetal('DrawText',w,labels{i},x-widths(i)/2,y+half,0,textSize);
  end
  PsychMetal('Flip',w); frames=frames+1;
 end
 stats=PsychMetalFrameStats(PsychMetal('Diagnostic',w),ifi);
 PsychMetal('Close',w); w=[];
 report=struct('ifi',ifi,'frequencies',hz,'frames',frames,'centers',centers,'frameStats',stats);
 fprintf('%d frames; %.3f presentations/s; %g long frame intervals.\n',frames,stats.achievedHz,stats.skipped);
catch e
 if ~isempty(w), try, PsychMetal('Close',w); catch, end; end
 rethrow(e);
end
end
