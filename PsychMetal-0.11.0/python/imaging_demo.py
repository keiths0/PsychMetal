"""The same texture through prepared Gaussian, sharpening and colour pipelines."""
import numpy as np
import psychmetal as pm

def imaging_demo(seconds=20):
    with pm.open_window() as (w, rect, ifi):
        pm.color_range(w, 1)
        y, x = np.mgrid[:256,:256]
        image = np.stack([(x%32<16)*.8+.1,(y%32<16)*.8+.1,(x+y)/510], axis=2).astype(np.float32)
        source = pm.make_texture(w, image)
        operations = [[{'type':'gaussian','sigma':3}],
                      [{'type':'convolution','kernel':[[0,-1,0],[-1,5,-1],[0,-1,0]]}],
                      [{'type':'color_matrix','matrix':[[.2126,.7152,.0722],[.2126,.7152,.0722],[.2126,.7152,.0722]]},
                       {'type':'gaussian','sigma':1.5}]]
        pipelines = [pm.create_image_pipeline(w, ops) for ops in operations]
        outputs = [pm.process_image(w, p, source) for p in pipelines]
        width, height = rect[2:];edge=min(width/2.4,height/3.2)
        boxes = [[width/2-edge*1.1,height/2-edge*1.15,width/2-edge*.1,height/2-edge*.15],
                 [width/2+edge*.1,height/2-edge*1.15,width/2+edge*1.1,height/2-edge*.15],
                 [width/2-edge*1.1,height/2+edge*.15,width/2-edge*.1,height/2+edge*1.15],
                 [width/2+edge*.1,height/2+edge*.15,width/2+edge*1.1,height/2+edge*1.15]]
        start=pm.get_secs();frames=0
        while pm.get_secs()-start<seconds:
            if pm.kb_check()[2][40]:break
            # Reuse output handles; the engine pools snapshot-safe GPU targets.
            outputs=[pm.process_image(w,p,source,d) for p,d in zip(pipelines,outputs)]
            pm.fill_rect(w,0)
            for tex,box,label in zip([source]+outputs,boxes,['Original','Gaussian','Sharpen','Grey + Gaussian']):
                pm.draw_texture(w,tex,dst_rect=box)
                pm.draw_text(w,label,x=box[0],y=box[1]-22,size=16,color=1)
            pm.flip(w);frames+=1
        return dict(frames=frames)

if __name__=='__main__':pm.run(imaging_demo)
