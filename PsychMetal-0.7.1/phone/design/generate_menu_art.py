"""Static menu illustrations; run with NumPy. Never used in stimulus rendering."""
from pathlib import Path
import struct
import zlib
import numpy as np

OUT = Path(__file__).resolve().parents[1] / 'src/psychmetaldemos/art'
OUT.mkdir(parents=True, exist_ok=True)

def png(name, a):
    a = np.uint8(np.clip(a, 0, 255))
    h, w, _ = a.shape
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    raw = b''.join(b'\0' + row.tobytes() for row in a)
    (OUT / (name + '.png')).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

navy = np.array([23., 34., 49.])
teal = np.array([102., 204., 191.])
gold = np.array([236., 184., 91.])
rng = np.random.default_rng(71)
y, x = np.mgrid[-1:1:144j, -1:1:144j]
base = np.broadcast_to(navy, (144, 144, 3)).copy()
for name in ('rectangle', 'textures', 'blob', 'array', 'gabor', 'dots', 'noise', 'ring'):
    a = base.copy()
    if name == 'rectangle':
        a[(abs(x) < .6) & (abs(y) < .43)] = teal
        a[(abs(x) < .42) & (abs(y) < .27)] = navy
    elif name == 'textures':
        a += 85 * np.exp(-2*(x*x+y*y))[...,None] * np.stack([np.sin(5*x)**2,np.cos(5*y)**2,np.sin(5*(x+y))**2],axis=-1)
    elif name in ('blob', 'gabor'):
        env = np.exp(-4*(x*x+y*y))
        value = env * (np.cos(20*(x+.4*y)) if name == 'gabor' else 1)
        a += value[..., None] * (teal - navy)
    elif name == 'array':
        for cx,cy,k in ((-.45,-.35,1),(.45,-.35,.55),(0,.45,.8)):
            a += np.exp(-28*((x-cx)**2+(y-cy)**2))[...,None]*(teal-navy)*k
    elif name == 'dots':
        for cx,cy in rng.uniform(-.8,.8,(23,2)):
            a[(x-cx)**2+(y-cy)**2 < .004] = teal
    elif name in ('noise', 'ring'):
        n = np.repeat(np.repeat(rng.uniform(0,1,(36,36,1)),4,axis=0),4,axis=1)
        a = navy + n*(teal-navy)
        if name == 'ring':
            radius = np.sqrt(x*x+y*y)
            a[(radius>.43)&(radius<.64)] = gold
    png(name,a)
# Centered Gabor, with an overlaid psychometric curve matching the app icon.
y,x = np.mgrid[0:1:280j, 0:1:900j]
a = np.broadcast_to(navy,(280,900,3)).copy()
env = np.exp(-2*(((x-.5)/.25)**2+((y-.5)/.52)**2))
contrast = env*np.cos(74*(x-.5)+10*(y-.5))
a += contrast[...,None]*105
curve = .80-.60/(1+np.exp(-24*(x-.5)))
distance = abs(y-curve)
span = (x>.23)*(x<.77)
shadow = np.clip((.026-distance)*280,0,1)*span
a = a*(1-shadow[...,None])+navy*shadow[...,None]
alpha = np.clip((.012-distance)*280,0,1)*span
a = a*(1-alpha[...,None])+gold*alpha[...,None]
png('hero',a)
print('Generated nine static menu illustrations.')
