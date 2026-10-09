"""Front-end routing and unsupported-operation contracts, scripted engine."""
import os
from unittest.mock import patch
import psychmetal as pm
import blob_array_demo
os.environ['PM_MOCK_DISPLAY']='800x600@120'
os.environ['PM_MOCK_MOUSE']='-1,0,0'

def rejects(fn):
    try: fn()
    except (ValueError, RuntimeError): return
    raise AssertionError('accepted unsupported operation')

for value in ('unsupported', '', 1, None):
    rejects(lambda: pm.open_window(presentation=value))
rejects(lambda: pm.open_window(presentation='displaylink',display_sync=False))

def check():
    with pm.open_window(presentation='displaylink') as (w,rect,ifi):
        assert pm._S['presentation']=='displaylink'
        pm.fill_rect(w,127.5)
        pm.flip(w)
        rejects(lambda: pm.prefetch_drawable(w,True))
        rejects(lambda: pm.set_display_sync(w,False))
        rejects(lambda: pm.prepare_flip(w))
        rejects(lambda: pm.queue_flip(w,pm.get_secs()+1))
    # Reopen restores direct mode, with ordinary prefetch and prepared frames.
    with pm.open_window() as (w,_,ifi):
        pm.prefetch_drawable(w,True)
        pm.prepare_flip(w)
        pm.present_now(w)
    r=blob_array_demo.blob_array_demo(.025,diagnostic=False,presentation='displaylink')
    assert r['frames']==3 and r['presentation']=='displaylink'
pm.run(check)
print('PASS: backend selection, linked Flip, explicit rejection, cleanup/reopen and shared blob demo.')

# Simulate the native default of iOS 17+: every ordinary open selects the link.
def iphone_default():
    with pm.open_window() as (w,_,_):
        assert pm._S['presentation']=='displaylink'
        rejects(lambda: pm.prefetch_drawable(w,True))
        pm.fill_rect(w,127); pm.flip(w)
    with pm.open_window(presentation='direct') as (w,_,_):
        assert pm._S['presentation']=='direct'
        pm.prefetch_drawable(w,True)
    with pm.open_window(presentation='displaylink') as (w,_,_):
        assert pm._S['presentation']=='displaylink'
with patch.dict(os.environ,{'PM_MOCK_DISPLAY_LINK_DEFAULT':'1'}):
    pm.run(iphone_default)
print('PASS: native platform default selects iPhone display link, with explicit direct override.')
