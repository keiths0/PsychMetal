"""Original mathematical icon: a Gabor patch with a psychometric sigmoid.
Requires numpy and Pillow. No fonts, stock artwork, or remote assets.
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

out=Path(__file__).resolve().parents[1]/'resources'
out.mkdir(exist_ok=True)
n=2048
y,x=np.mgrid[0:n,0:n].astype(np.float32)/(n-1)
u,v=x-.5,y-.5
carrier=u*np.cos(np.pi/10)+v*np.sin(np.pi/10)
envelope=np.exp(-(u*u+v*v)/(2*.235**2))
wave=.5+.5*np.cos(2*np.pi*5.3*carrier)
background=np.array([23,34,49],np.float32)
gray=24+217*wave
rgb=background[None,None,:]*(1-envelope[:,:,None])+gray[:,:,None]*envelope[:,:,None]
im=Image.fromarray(np.clip(rgb,0,255).astype('uint8'),'RGB')
d=ImageDraw.Draw(im)
# A sigmoid rising with stimulus strength; thick outline preserves contrast.
xx=np.linspace(.16,.85,400)
yy=.76-.52/(1+np.exp(-15*(xx-.50)))
points=[(int(a*n),int(b*n)) for a,b in zip(xx,yy)]
d.line(points,fill=(14,25,37),width=int(n*.046),joint='curve')
d.line(points,fill=(255,190,72),width=int(n*.025),joint='curve')
for px,py in (points[0],points[-1]):
    rr=int(n*.0125);d.ellipse((px-rr,py-rr,px+rr,py+rr),fill=(255,190,72))
for size in (20,29,40,58,60,76,80,87,120,152,167,180,640,1024,1280,1920):
    im.resize((size,size),Image.Resampling.LANCZOS).save(out/f'icon-{size}.png')
print('Created 16 opaque RGB icon/splash sizes.')
