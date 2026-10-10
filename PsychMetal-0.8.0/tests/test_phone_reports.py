"""Report persistence, native share-sheet contract, UI GC policy and close capture.
UIKit calls use doubles; this is not physical-device presentation acceptance.
"""
import ctypes
import gc
import json
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace, ModuleType
from unittest.mock import patch
root=Path(__file__).resolve().parents[1];sys.path[:0]=[str(root/'python'),str(root/'phone/src')]
# Report/UI contracts are portable; a committed Mac binary is not importable
# on Linux (nor by a different Python ABI). Keep testing the portable module.
from importlib.machinery import EXTENSION_SUFFIXES
if not any((root/'python/psychmetal'/('_psychmetal'+suffix)).exists() for suffix in EXTENSION_SUFFIXES):
    portable=ModuleType('psychmetal');portable.__path__=[str(root/'python/psychmetal')]
    portable._environment_observer=None
    portable._core=SimpleNamespace(environment=lambda:{'engineVersion':'test-double'})
    portable._np=SimpleNamespace(__version__='test-double')
    portable.diagnostic=lambda w:{'summary':{}}
    sys.modules['psychmetal']=portable
    print('Portable phone report tests use an engine metadata double; native ABI acceptance is separate.')
from psychmetaldemos.reports import Reports
from psychmetaldemos.lifecycle import MainThreadCollections
from psychmetaldemos.sharing import ShareSheet

class Loop:
 def __init__(self):self.pending=[];self.timers=[]
 def call_soon_threadsafe(self,fn,*args):self.pending.append((fn,args))
 def call_later(self,delay,fn):
  handle=SimpleNamespace(cancel=lambda:None);self.timers.append((fn,handle));return handle
 def run(self):
  fn,args=self.pending.pop(0);fn(*args)
loop=Loop()
with tempfile.TemporaryDirectory() as temp:
 reports=Reports(temp);reports.update('hello <world>','<html>timing</html>',dict(gpu='Apple',unmeasured=float('nan')))
 restored=Reports(temp);assert restored.data==reports.data
 assert restored.data['environment']['unmeasured'] is None
 reports.path.write_text('{broken');assert Reports(temp).data['output'] is None
 reports.update(environment={'later':True});assert reports.data['timingEnvironment']['gpu']=='Apple'
 reports.update(output='kept');assert Reports(temp).data['output']=='kept'
 # Lazy native imports, iPad anchoring and asynchronous cancellation cleanup.
 class Obj:
  def __init__(self):self.items=[];self.popoverPresentationController=SimpleNamespace()
  def alloc(self):return self
  def initWithActivityItems_applicationActivities_(self,items,apps):self.items=items.items;return self
  def array(self):return self
  def addObject_(self,item):self.items.append(item)
  def fileURLWithPath_(self,path):return path
 objects=[]
 def cls(name):o=Obj();objects.append(o);return o
 class Block:
  def __init__(self,fn,*signature):self.fn=fn
 objc=ModuleType('rubicon.objc');objc.ObjCClass=cls;objc.Block=Block;objc.ObjCInstance=lambda e:SimpleNamespace(localizedDescription=str(e))
 types=ModuleType('rubicon.objc.types');types.objc_id=ctypes.c_void_p;types.CGRect=lambda *a:a
 native=SimpleNamespace(presentedViewController=None,view=SimpleNamespace(bounds=SimpleNamespace(size=SimpleNamespace(width=1024,height=1366))))
 native.presentViewController_animated_completion_=lambda *a:None
 window=SimpleNamespace(_impl=SimpleNamespace(native=SimpleNamespace(rootViewController=native)))
 done=[]
 with patch.dict(sys.modules,{'rubicon':ModuleType('rubicon'),'rubicon.objc':objc,'rubicon.objc.types':types}):
  share=ShareSheet(loop);share.present(window,reports,lambda *a:done.append(a))
  files=[Path(p) for p in share.controller.items];assert len(files)==4 and all(p.exists() for p in files)
  pop=share.controller.popoverPresentationController;assert pop.sourceView is native.view and pop.sourceRect==((512,683),(1,1))
  try:share.present(window,reports,lambda *a:None);raise AssertionError('double presentation')
  except RuntimeError:pass
  share.completion.fn(None,False,None,None);assert share.active and all(p.exists() for p in files)
  loop.run();assert done==[(False,None)] and not share.active and not any(p.exists() for p in files)
  share.present(window,reports,lambda *a:done.append(a));share.completion.fn(None,True,None,None);loop.run();assert done[-1]==(True,None)
  native.presentedViewController=object()
  try:share.present(window,reports,lambda *a:None);raise AssertionError('already presented')
  except RuntimeError:assert share.temporary is None and not share.active

prior=gc.isenabled();busy=[False];collected=[]
with patch.object(gc,'collect',lambda:collected.append(threading.get_ident())):
 policy=MainThreadCollections(loop,lambda:not busy[0]);assert not gc.isenabled()
 busy[0]=True;policy.collect();assert not collected
 busy[0]=False;policy.collect();assert collected==[threading.get_ident()]
 failures=[]
 def worker():
  try:policy.collect()
  except RuntimeError:failures.append(True)
 thread=threading.Thread(target=worker);thread.start();thread.join();assert failures==[True]
 policy.close();policy.close();assert gc.isenabled()==prior

import psychmetal as pm
from psychmetal.environment import Capture
with Capture(pm) as captured:
 assert pm._environment_observer is not None
 with patch.object(pm,'diagnostic',lambda w:{'summary':{'measuredRefreshHz':119.98}}):
  captured.collect(1)
 assert captured.report['window']['measuredRefreshHz']==119.98
assert pm._environment_observer is None
with Capture(pm) as captured:
 with patch.object(pm,'diagnostic',side_effect=RuntimeError('injected')):captured.collect(1)
 assert captured.error=='injected'
assert pm._environment_observer is None
print('PASS: atomic persistence/reopen/corruption, strict JSON, share completion/cancellation/file lifetime/iPad anchor, main-thread-only idle collection, close-time environment capture.')
