function report=PsychMetalAudioStreamDemo(seconds)
% Append newly generated PCM while playing; move horizontally to change pitch.
if nargin<1,seconds=20;end
info=PsychMetal('OpenAudio',struct('channels',1));
audioCleanup=onCleanup(@()PsychMetal('CloseAudio'));
rate=info.rate;capacity=max(16,round(rate*.1));target=min(capacity,round(rate*.04));
stream=PsychMetal('MakeAudioStream',capacity,1);phase=0;frequency=440;
phase=refillTone(stream,target,frequency,rate,phase);
[w,r]=PsychMetal('OpenWindow');windowCleanup=onCleanup(@()PsychMetal('Close',w));
PsychMetal('ColorRange',w,1);PsychMetal('Play',stream);t0=PsychMetal('GetSecs');frames=0;
while PsychMetal('GetSecs')-t0<seconds
 [~,~,keys]=PsychMetal('KbCheck');if keys(41),break;end
 [x,~,~]=PsychMetal('GetMouse',w);frequency=220+660*max(0,min(1,x/r(3)));
 status=PsychMetal('AudioStreamStatus',stream);count=min(status.free,max(0,target-status.queued));
 if count>0,phase=refillTone(stream,count,frequency,rate,phase);end
 PsychMetal('FillRect',w,0);
 text=sprintf('Online buffer refill\n%.0f Hz\nMove horizontally\nUnderflow samples: %d',frequency,status.underflowFrames);
 PsychMetal('DrawText',w,text,r(3)*.1,r(4)*.3,1,max(20,r(3)/40));
 PsychMetal('Flip',w);frames=frames+1;
end
PsychMetal('StopSound');status=PsychMetal('AudioStreamStatus',stream);disp(status);
report=struct('frames',frames,'stream',status);
end

function phase=refillTone(stream,count,frequency,rate,phase)
samples=single(.15*sin(phase+2*pi*frequency/rate*(0:count-1)'));
PsychMetal('RefillSound',stream,samples);
phase=mod(phase+2*pi*frequency*count/rate,2*pi);
end
