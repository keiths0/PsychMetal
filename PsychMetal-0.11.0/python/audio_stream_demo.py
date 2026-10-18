"""Online PCM refill. Move the pointer/finger horizontally to change tone pitch."""
import math
import numpy as np
import psychmetal as pm

def audio_stream_demo(seconds=20):
    info=pm.open_audio(channels=1)
    rate=info['rate'];capacity=max(16,round(rate*.1));target=min(capacity,round(rate*.04))
    phase=0.;frequency=440.
    def fill(count):
        nonlocal phase
        theta=phase+(2*math.pi*frequency/rate)*np.arange(count)
        samples=(.15*np.sin(theta)).astype(np.float32)
        pm.refill_sound(stream,samples)
        phase=(phase+2*math.pi*frequency*count/rate)%(2*math.pi)
    try:
        stream=pm.make_audio_stream(capacity,1)
        fill(target)
        with pm.open_window() as (w,rect,ifi):
            pm.color_range(w,1);pm.play(stream);start=pm.get_secs();frames=0
            while pm.get_secs()-start<seconds:
                if pm.kb_check()[2][40]:break
                x,_,_=pm.get_mouse(w);frequency=220+660*max(0,min(1,x/rect[2]))
                status=pm.audio_stream_status(stream)
                count=min(status['free'],max(0,target-status['queued']))
                if count:fill(count)
                pm.fill_rect(w,0)
                pm.draw_text(w, f'Online buffer refill\n{frequency:.0f} Hz\nMove a finger horizontally\nUnderflow samples: {status["underflowFrames"]}',
                             x=rect[2]*.1,y=rect[3]*.3,size=max(16,rect[2]/40),wrap_width=rect[2]*.8,color=1)
                pm.flip(w);frames+=1
            pm.stop_sound()
            status=pm.audio_stream_status(stream)
            print('Audio stream:',status)
            return dict(frames=frames,stream=status)
    finally:pm.close_audio()

if __name__=='__main__':pm.run(audio_stream_demo)
