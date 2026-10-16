"""Keep cyclic UI-object collection on the app's main thread, outside trials."""
import gc
import threading


class MainThreadCollections:
    """App-scoped policy. Refcount releases still occur on their owning thread.

    Python's automatic cyclic collector may otherwise run on the demo worker
    and finalize detached Toga/UIKit trees there. Never apply this policy in
    the toolbox library; it belongs only to the GUI app.
    """
    def __init__(self, loop, idle, interval=30):
        self._check_thread()
        self.loop, self.idle, self.interval = loop, idle, interval
        self.was_enabled = gc.isenabled()
        self.closed = False
        self.timer = None
        gc.disable()
        try:self.timer = loop.call_later(interval, self.tick)
        except BaseException:
            if self.was_enabled:gc.enable()
            raise

    @staticmethod
    def _check_thread():
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError('UI collection must run on the main thread.')

    def collect(self):
        self._check_thread()
        if not self.closed and self.idle():
            gc.collect()

    def tick(self):
        self.collect()
        if not self.closed:
            self.timer = self.loop.call_later(self.interval, self.tick)

    def close(self):
        self._check_thread()
        if self.closed:
            return
        self.closed = True
        if self.timer is not None:
            self.timer.cancel()
        gc.collect()
        if self.was_enabled:
            gc.enable()
