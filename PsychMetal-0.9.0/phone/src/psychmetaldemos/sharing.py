"""Main-thread UIKit share sheet; no network call or destination chosen here."""
import ctypes
import tempfile
import threading
import time


_phone_delegate_type=None


def phone_delegate_type():
    """Create the native delegate once; UIKit keeps only a weak reference to it."""
    global _phone_delegate_type
    if _phone_delegate_type is None:
        from rubicon.objc import ObjCClass, ObjCProtocol, objc_method, objc_property

        class PsychMetalPhoneShareDelegate(ObjCClass('NSObject'),
                protocols=(ObjCProtocol('UIPopoverPresentationControllerDelegate'),)):
            owner=objc_property(object)

            @objc_method
            def adaptivePresentationStyleForPresentationController_(self, controller) -> ctypes.c_long:
                return -1 if self.owner is None or self.owner.is_ipad else 0  # none on iPad, full screen on phone

            @objc_method
            def adaptivePresentationStyleForPresentationController_traitCollection_(self, controller, traits) -> ctypes.c_long:
                return -1 if self.owner is None or self.owner.is_ipad else 0

            @objc_method
            def presentationControllerDidDismiss_(self, controller) -> None:
                if self.owner is not None:self.owner.dismissed()

            @objc_method
            def popoverPresentationControllerDidDismissPopover_(self, controller) -> None:
                if self.owner is not None:self.owner.dismissed()

        _phone_delegate_type=PsychMetalPhoneShareDelegate
    return _phone_delegate_type


class ShareSheet:
    def __init__(self, loop):
        self.loop=loop
        self.active=False
        self.temporary=self.controller=self.completion=self.presentation_completion=None
        self.dismissal_completion=None
        self.presentation_delegate=None
        self._completion_received=False
        self._done=None
        self.dismissal_fallback=None
        self.dismissal_watch=None
        self.host_window=self.menu_window=None

    def present(self, window, reports, done):
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError('Sharing requires the main thread.')
        if self.active:raise RuntimeError('A share sheet is already open.')
        # Lazy import keeps portable tests and toolbox installs independent of UIKit.
        from rubicon.objc import ObjCClass, ObjCInstance, Block
        from rubicon.objc.runtime import objc_id, send_message
        from rubicon.objc.types import CGRect
        self.temporary=tempfile.TemporaryDirectory(prefix='psychmetal-report-')
        try:
            files=reports.export(self.temporary.name)
            if not files:raise ValueError('No report to share.')
            items=ObjCClass('NSMutableArray').array()
            for path in files:
                items.addObject_(ObjCClass('NSURL').fileURLWithPath_(str(path)))
            presenter=window._impl.native.rootViewController
            if presenter.presentedViewController is not None:
                raise RuntimeError('Close the current dialog before sharing.')
            # Toga creates its window before the scene is connected. Use the
            # same scene-aware window lifecycle as the stimulus engine, so the
            # system share service has complete geometry on the first launch.
            self.menu_window=window._impl.native
            scene=self.menu_window.windowScene
            if scene is None:raise RuntimeError('Sharing requires an active window scene.')
            self.host_window=ObjCClass('UIWindow').alloc().initWithWindowScene_(scene)
            self.host_window.setWindowLevel_(self.menu_window.windowLevel+1)
            presenter=ObjCClass('UIViewController').alloc().init()
            self.host_window.setRootViewController_(presenter)
            self.host_window.makeKeyAndVisible()
            self.host_window.layoutIfNeeded();presenter.view.layoutIfNeeded()
            self.controller=ObjCClass('UIActivityViewController').alloc().initWithActivityItems_applicationActivities_(items,None)
            # Explicit selectors avoid Rubicon's inferred read-only properties.
            def object_result(receiver, selector):
                pointer=send_message(receiver,selector,restype=objc_id,argtypes=[])
                return ObjCInstance(pointer) if pointer else None
            device=object_result(ObjCClass('UIDevice'),'currentDevice')
            idiom=int(send_message(device,'userInterfaceIdiom',restype=ctypes.c_long,argtypes=[]))
            is_ipad=self.is_ipad=idiom==1
            # The device log confirms UIActivityViewController keeps style 7
            # (popover) even after a modal-style setter. Configure its actual
            # presentation controller and explicitly adapt on phones, including
            # the cold-launch path before any Metal window has existed.
            self.controller.setModalPresentationStyle_(7)
            popover=object_result(self.controller,'popoverPresentationController')
            if popover is not None:
                view=presenter.view
                popover.sourceView=view
                bounds=view.bounds
                popover.sourceRect=CGRect((bounds.size.width/2,bounds.size.height/2),(1,1))
                popover.permittedArrowDirections=0
                self.presentation_delegate=phone_delegate_type().alloc().init()
                self.presentation_delegate.owner=self
                popover.delegate=self.presentation_delegate
            elif not is_ipad:
                raise RuntimeError('The system share presentation controller is unavailable.')
            self._completion_received=False
            self._done=done
            def completed(activity, successful, returned, error):
                # Release the controller, block and temporary files after this
                # native callback returns. Cancellation follows the same path.
                message=str(ObjCInstance(error).localizedDescription) if error else None
                self._completion_received=True
                self._finish_deadline=time.monotonic()+2.0
                self.loop.call_soon_threadsafe(self._finish,bool(successful),message,done)
            self.completion=Block(completed,None,objc_id,ctypes.c_bool,objc_id,objc_id)
            self.controller.completionWithItemsHandler=self.completion
            self.active=True
            controller=self.controller
            def presented():
                if not self.active or self.controller is not controller:return
                # Some system share-sheet cancellation paths do not call either
                # completion handler. Observe UIKit's presentation links only
                # after the presentation animation has completed.
                self.dismissal_watch=self.loop.call_later(.1,lambda:self._watch_dismissal(controller))
            self.presentation_completion=Block(presented,None)
            presenter.presentViewController_animated_completion_(self.controller,True,self.presentation_completion)
        except BaseException:
            self._clear();raise

    def _watch_dismissal(self, controller):
        if not self.active or self.controller is not controller or self._completion_received:return
        try:
            presenter=self.host_window.rootViewController
            closed=(presenter.presentedViewController is None
                    and not controller.isBeingDismissed()
                    and (controller.presentingViewController is None
                         or controller.view.window is None))
        except Exception as failure:
            print('PsychMetal Share: presentation observation failed: '+str(failure))
            closed=False
        if closed:
            self.dismissed()
        else:
            # Runs only while sharing, never during timed stimulus playback.
            self.dismissal_watch=self.loop.call_later(.1,lambda:self._watch_dismissal(controller))

    def dismissed(self):
        # Some system cancellation paths signal the presentation delegate instead
        # of the activity completion block. Restore controls in either case.
        if not self.active or self._completion_received:return
        controller=self.controller
        def fallback():
            # Give the activity completion block priority over a generic dismiss.
            if not self.active or self.controller is not controller or self._completion_received:return
            self._completion_received=True
            self._finish_deadline=time.monotonic()+2.0
            self._finish(False,None,self._done)
        self.dismissal_fallback=self.loop.call_later(.05,fallback)

    def _clear(self):
        if self.dismissal_watch is not None:self.dismissal_watch.cancel()
        self.dismissal_watch=None
        if self.dismissal_fallback is not None:self.dismissal_fallback.cancel()
        self.dismissal_fallback=None
        if self.presentation_delegate is not None:self.presentation_delegate.owner=None
        self.presentation_delegate=None
        self._done=None
        self.controller=self.completion=self.presentation_completion=None
        self.dismissal_completion=None
        host,menu=self.host_window,self.menu_window
        self.host_window=self.menu_window=None
        try:
            if host is not None:
                # Rubicon can silently store an unknown property as a Python
                # attribute. Use native selectors for every teardown operation.
                # Detaching from the scene also removes this window from routing.
                host.setHidden_(True)
                host.setRootViewController_(None)
                host.setWindowScene_(None)
        finally:
            if menu is not None:menu.makeKeyAndVisible()
        temporary=self.temporary
        self.temporary=None;self.active=False
        if temporary is not None:temporary.cleanup()

    def _finish(self, successful, error, done):
        if not self.active or self.dismissal_completion is not None:return
        # UIKit's activity callback may precede dismissal. A getter failure or
        # stale presentation link must never permanently disable demos/sharing.
        try:
            waiting=(self.controller.isBeingDismissed()
                     or (self.controller.presentingViewController is not None
                         and self.controller.view.window is not None))
            if waiting and time.monotonic()<self._finish_deadline:
                self.loop.call_later(.05,lambda:self._finish(successful,error,done))
                return
        except Exception as failure:
            print('PsychMetal Share: dismissal observation failed: '+str(failure))
        # Complete UIKit's own modal teardown before disconnecting its window.
        # An activity result is not a guarantee that dismissal has completed.
        presenter=self.host_window.rootViewController
        if presenter.presentedViewController is not None:
            from rubicon.objc import Block
            controller=self.controller
            def dismissed():
                if self.active and self.controller is controller:
                    self.loop.call_soon_threadsafe(self._restore,successful,error,done)
            self.dismissal_completion=Block(dismissed,None)
            presenter.dismissViewControllerAnimated_completion_(False,self.dismissal_completion)
            # UIKit does not promise this completion. Without it the sheet would
            # stay active and Share reports disabled until the app restarted.
            def overdue():
                if self.active and self.controller is controller:
                    print('PsychMetal Share: dismissal did not complete; restoring the menu.')
                    self._restore(successful,error,done)
            self.dismissal_fallback=self.loop.call_later(1.0,overdue)
            return
        self._restore(successful,error,done)

    def _restore(self, successful, error, done):
        if not self.active:return
        try:
            self._clear()
        finally:
            done(successful,error)
