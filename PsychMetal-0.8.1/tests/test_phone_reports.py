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
  def __init__(self):self.items=[];self.view=SimpleNamespace(window=object());self.popoverPresentationController=SimpleNamespace();self.sheetPresentationController=Sheet();self.presentingViewController=None;self.presentedViewController=None;self._dismissing=False;self.transitionCoordinator=None
  def isBeingDismissed(self):return self._dismissing
  def setModalPresentationStyle_(self,value):self.modalPresentationStyle=value
  def alloc(self):return self
  def init(self):
   self.view=SimpleNamespace(bounds=native.view.bounds,layoutIfNeeded=lambda:None)
   self.traitCollection=native.traitCollection
   self.presentViewController_animated_completion_=lambda *a:None
   return self
  def initWithWindowScene_(self,scene):
   self.windowScene=scene;self.bounds=native.view.bounds;self._native_hidden=True
   return self
  def setHidden_(self,value):self._native_hidden=value
  def isHidden(self):return self._native_hidden
  def setWindowScene_(self,scene):self.windowScene=scene
  def setRootViewController_(self,controller):self.rootViewController=controller
  def setWindowLevel_(self,level):self.windowLevel=level
  def makeKeyAndVisible(self):self._native_hidden=False
  def layoutIfNeeded(self):pass
  def initWithActivityItems_applicationActivities_(self,items,apps):self.items=items.items;return self
  def array(self):return self
  def addObject_(self,item):self.items.append(item)
  def fileURLWithPath_(self,path):return path
 objects=[];idiom=[1]  # UIUserInterfaceIdiomPad
 class NSObject:
  def __init_subclass__(cls,**kwargs):super().__init_subclass__()
  @classmethod
  def alloc(cls):return cls()
  def init(self):return self
 def cls(name):
  if name=='NSObject':return NSObject
  if name=='UIDevice':return SimpleNamespace(currentDevice=SimpleNamespace(userInterfaceIdiom=idiom[0]))
  o=Obj();objects.append(o);return o
 class Block:
  def __init__(self,fn,*signature):self.fn=fn
 objc=ModuleType('rubicon.objc');objc.ObjCClass=cls;objc.Block=Block;objc.ObjCInstance=lambda e:e
 objc.ObjCProtocol=lambda name:name;objc.objc_method=lambda fn:fn;objc.objc_property=lambda kind:None
 # Match Rubicon's real module layout: objc_id is a runtime type, not a geometry type.
 runtime=ModuleType('rubicon.objc.runtime');runtime.objc_id=ctypes.c_void_p
 def send_message(receiver,selector,**kwargs):return getattr(receiver,selector)
 runtime.send_message=send_message
 types=ModuleType('rubicon.objc.types');types.CGRect=lambda *a:a
 class Sheet:
  def setPrefersPageSizing_(self,value):self.page=value
  def setPrefersEdgeAttachedInCompactHeight_(self,value):self.edge=value
  def setWidthFollowsPreferredContentSizeWhenEdgeAttached_(self,value):self.preferred_width=value
 native=SimpleNamespace(presentedViewController=None,view=SimpleNamespace(bounds=SimpleNamespace(size=SimpleNamespace(width=1024,height=1366)),layoutIfNeeded=lambda:None))
 native.traitCollection=SimpleNamespace(horizontalSizeClass=0,verticalSizeClass=0)
 native.presentViewController_animated_completion_=lambda *a:None
 window=SimpleNamespace(_impl=SimpleNamespace(native=SimpleNamespace(rootViewController=native,bounds=native.view.bounds,windowScene=object(),windowLevel=0,makeKeyAndVisible=lambda:None,layoutIfNeeded=lambda:None,isKeyWindow=lambda:True,isUserInteractionEnabled=lambda:True)))
 restored_windows=[]
 window._impl.native.makeKeyAndVisible=lambda:restored_windows.append(True)
 done=[]
 with patch.dict(sys.modules,{'rubicon':ModuleType('rubicon'),'rubicon.objc':objc,'rubicon.objc.types':types,'rubicon.objc.runtime':runtime}):
  share=ShareSheet(loop);share.present(window,reports,lambda *a:done.append(a))
  host=share.host_window
  assert host.windowScene is window._impl.native.windowScene and host.windowLevel==1
  assert not host.isHidden() and host.rootViewController is not native
  files=[Path(p) for p in share.controller.items];assert len(files)==4 and all(p.exists() for p in files)
  assert share.controller.modalPresentationStyle==7
  assert not vars(share.controller.sheetPresentationController)
  pop=share.controller.popoverPresentationController;assert pop.sourceView is share.host_window.rootViewController.view and pop.sourceRect==((512,683),(1,1))
  try:share.present(window,reports,lambda *a:None);raise AssertionError('double presentation')
  except RuntimeError:pass
  share.completion.fn(None,False,None,None);assert share.active and all(p.exists() for p in files)
  loop.run();assert done==[(False,None)] and not share.active and not any(p.exists() for p in files)
  assert host.isHidden() and host.rootViewController is None and share.host_window is None
  assert host.windowScene is None and not hasattr(host,"hidden")
  assert restored_windows==[True]
  share.present(window,reports,lambda *a:done.append(a));share.completion.fn(None,True,None,None);loop.run();assert done[-1]==(True,None)
  native.presentedViewController=object()
  try:share.present(window,reports,lambda *a:None);raise AssertionError('already presented')
  except RuntimeError:assert share.temporary is None and not share.active
  native.presentedViewController=None;idiom[0]=0  # UIUserInterfaceIdiomPhone
  for successful in (False,True):
   share.present(window,reports,lambda *a:done.append(a))
   assert share.controller.modalPresentationStyle==7
   delegate=share.presentation_delegate
   assert share.controller.popoverPresentationController.delegate is delegate
   assert delegate.owner is share
   assert delegate.adaptivePresentationStyleForPresentationController_(None)==0
   for width_class in (0,1,2):
    traits=SimpleNamespace(horizontalSizeClass=width_class)
    assert delegate.adaptivePresentationStyleForPresentationController_traitCollection_(None,traits)==0
   controller=share.controller;files=[Path(p) for p in controller.items]
   controller.presentingViewController=native;controller._dismissing=True
   controller.transitionCoordinator=object()
   share.completion.fn(None,successful,None,None);loop.run()
   assert share.active and share.controller is controller and all(p.exists() for p in files)
   try:share.present(window,reports,lambda *a:None);raise AssertionError('reopen during dismissal')
   except RuntimeError:pass
   controller.presentingViewController=None;controller._dismissing=False;controller.transitionCoordinator=None
   loop.timers[-1][0]()
   assert done[-1]==(successful,None) and not share.active and not any(p.exists() for p in files)
   assert delegate.owner is None and share.presentation_delegate is None
  # Interactive dismissal can arrive without an activity callback.
  share.present(window,reports,lambda *a:done.append(a))
  share.presentation_delegate.presentationControllerDidDismiss_(None)
  fallback=loop.timers[-1][0];fallback()
  assert not share.active and done[-1]==(False,None)
  # A successful activity callback takes priority over the dismissal fallback.
  share.present(window,reports,lambda *a:done.append(a))
  share.presentation_delegate.presentationControllerDidDismiss_(None)
  fallback=loop.timers[-1][0]
  share.completion.fn(None,True,None,None);loop.run();fallback()
  assert not share.active and done[-1]==(True,None)
  # Old callbacks cannot dismiss a newly opened share sheet.
  share.present(window,reports,lambda *a:done.append(a));fallback()
  assert share.active
  share.completion.fn(None,False,None,None);loop.run()
  # The system can dismiss without notifying the activity or its delegate.
  # The transparent share window must then stop intercepting menu touches.
  for phone_idiom in (0,1):
   idiom[0]=phone_idiom
   share.present(window,reports,lambda *a:done.append(a))
   host=share.host_window;controller=share.controller;presenter=host.rootViewController
   delegate=share.presentation_delegate
   assert delegate.adaptivePresentationStyleForPresentationController_(None)==(-1 if phone_idiom else 0)
   presenter.presentedViewController=controller;controller.presentingViewController=presenter
   share.presentation_completion.fn()
   watch=loop.timers[-1][0];watch()
   assert share.active and not host.isHidden()  # still open: no timeout cancels it
   assert all(Path(p).exists() for p in controller.items)
   # A different modal is still using the host: do not tear down its window.
   presenter.presentedViewController=object();controller.presentingViewController=None
   loop.timers[-1][0]()
   assert share.active and not host.isHidden()
   presenter.presentedViewController=None
   # UIKit may retain a stale presenting link after removing the actual view.
   controller.presentingViewController=presenter
   controller.view=SimpleNamespace(window=None)
   before=len(done)
   loop.timers[-1][0]();loop.timers[-1][0]()
   assert len(done)==before+1
   assert not share.active and host.isHidden() and host.rootViewController is None
   assert host.windowScene is None and not hasattr(host,"hidden")
   assert done[-1]==(False,None) and not any(Path(p).exists() for p in controller.items)
   # This presentation's old timer cannot close a new share window.
   share.present(window,reports,lambda *a:done.append(a));watch()
   assert share.active
   share.presentation_delegate.popoverPresentationControllerDidDismissPopover_(None)
   loop.timers[-1][0]()
   assert not share.active and done[-1]==(False,None)
  idiom[0]=0
  # An activity result can precede UIKit's native modal teardown. Keep the
  # host and exports until the native dismissal completion has returned.
  share.present(window,reports,lambda *a:done.append(a))
  host=share.host_window;controller=share.controller;presenter=host.rootViewController
  presenter.presentedViewController=controller
  native_dismissals=[]
  presenter.dismissViewControllerAnimated_completion_=lambda animated,block:native_dismissals.append(block)
  before=len(done)
  share.completion.fn(None,False,None,None);loop.run()
  assert len(native_dismissals)==1 and share.active and not host.isHidden()
  assert all(Path(p).exists() for p in controller.items) and len(done)==before
  presenter.presentedViewController=None
  native_dismissals[0].fn()
  assert share.active  # don't release the block from inside its native callback
  loop.run()
  assert not share.active and host.isHidden() and host.windowScene is None
  assert len(done)==before+1
  # UIKit never calls the dismissal completion: the menu and Share come back anyway.
  share.present(window,reports,lambda *a:done.append(a))
  host=share.host_window;controller=share.controller;presenter=host.rootViewController
  presenter.presentedViewController=controller
  presenter.dismissViewControllerAnimated_completion_=lambda animated,block:None
  before=len(done)
  share.completion.fn(None,True,None,None);loop.run()
  assert share.active and len(done)==before
  overdue=loop.timers[-1][0];overdue()
  assert not share.active and host.isHidden() and done[-1]==(True,None) and len(done)==before+1
  overdue();assert len(done)==before+1   # a late timer does nothing more
  # Failures after activating the share window must restore the menu too.
  prior_restores=len(restored_windows)
  with patch.object(Obj,'initWithActivityItems_applicationActivities_',side_effect=RuntimeError('native setup failed')):
   try:share.present(window,reports,lambda *a:None);raise AssertionError('expected setup failure')
   except RuntimeError:pass
  assert share.host_window is None and share.temporary is None and not share.active
  assert len(restored_windows)==prior_restores+1
  # A native getter exception and a stale UIKit link cannot wedge the app.
  share.present(window,reports,lambda *a:done.append(a))
  share.controller.isBeingDismissed=lambda:(_ for _ in ()).throw(AttributeError('getter unavailable'))
  share.completion.fn(None,False,None,None);loop.run()
  assert not share.active and done[-1]==(False,None)
  share.present(window,reports,lambda *a:done.append(a))
  share.controller.presentingViewController=native
  share.completion.fn(None,False,None,None);share._finish_deadline=0;loop.run()
  assert not share.active and done[-1]==(False,None)

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
