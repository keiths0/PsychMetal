"""Main-thread UIKit share sheet; no network call or destination chosen here."""
import ctypes
import tempfile
import threading


class ShareSheet:
    def __init__(self, loop):
        self.loop=loop
        self.active=False
        self.temporary=self.controller=self.completion=None

    def present(self, window, reports, done):
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError('Sharing requires the main thread.')
        if self.active:raise RuntimeError('A share sheet is already open.')
        # Lazy import keeps portable tests and toolbox installs independent of UIKit.
        from rubicon.objc import ObjCClass, ObjCInstance, Block
        from rubicon.objc.types import objc_id, CGRect
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
            self.controller=ObjCClass('UIActivityViewController').alloc().initWithActivityItems_applicationActivities_(items,None)
            popover=self.controller.popoverPresentationController
            if popover is not None:
                view=presenter.view
                popover.sourceView=view
                bounds=view.bounds
                popover.sourceRect=CGRect((bounds.size.width/2,bounds.size.height/2),(1,1))
                popover.permittedArrowDirections=0
            def completed(activity, successful, returned, error):
                # Release the controller, block and temporary files after this
                # native callback returns. Cancellation follows the same path.
                message=str(ObjCInstance(error).localizedDescription) if error else None
                self.loop.call_soon_threadsafe(self._finish,bool(successful),message,done)
            self.completion=Block(completed,None,objc_id,ctypes.c_bool,objc_id,objc_id)
            self.controller.completionWithItemsHandler=self.completion
            self.active=True
            presenter.presentViewController_animated_completion_(self.controller,True,None)
        except BaseException:
            self._clear();raise

    def _clear(self):
        self.controller=self.completion=None
        if self.temporary is not None:self.temporary.cleanup()
        self.temporary=None;self.active=False

    def _finish(self, successful, error, done):
        self._clear()
        done(successful,error)
