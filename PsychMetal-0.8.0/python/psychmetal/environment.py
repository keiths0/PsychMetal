"""Explicit environment capture and portable JSON export, outside render loops."""
import json
import math
import platform
from pathlib import Path


def _json_value(value):
    # Diagnostic dictionaries contain NumPy scalars/arrays and unmeasured NaNs.
    # Export valid JSON (null for unknown), never JavaScript-only NaN literals.
    if isinstance(value, dict):
        return {str(k): _json_value(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(v) for v in value]
    if hasattr(value, 'tolist'):
        return _json_value(value.tolist())
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise TypeError('Unsupported report value: ' + type(value).__name__)


def collect(pm, window=None):
    """Collect engine/OS/GPU/interpreter metadata. May wait if window is supplied.

    Run before or after a trial, never once per frame. No network access, hostname,
    user name or file paths are collected. Window diagnostics may drain GPU work.
    """
    report=dict(pm._core.environment())
    report.update(schemaVersion=1, interpreter='Python',
                  interpreterVersion=platform.python_version(),
                  architecture=platform.machine(), numpyVersion=pm._np.__version__)
    if window is not None:
        report['window']=pm.diagnostic(window)['summary']
    return _json_value(report)


def export(report, path):
    """Write explicit caller-supplied report to a NEW UTF-8 JSON file."""
    data=json.dumps(_json_value(report),allow_nan=False,indent=2,sort_keys=True)+'\n'
    target=Path(path).expanduser()
    with target.open('x',encoding='utf-8') as stream:
        stream.write(data)
    return target


class Capture:
    """Explicit close-time metadata capture for an app-owned worker session.

    No per-frame callbacks. Only one capture may be installed; the caller owns
    the PsychMetal worker. Diagnostic collection happens after the trial, before
    closing the window. Collection errors are retained without blocking close.
    """
    def __init__(self, pm):
        self.pm=pm;self.report=None;self.error=None

    def __enter__(self):
        if self.pm._environment_observer is not None:
            raise RuntimeError('Environment capture is already active.')
        self.pm._environment_observer=self.collect
        return self

    def collect(self, window):
        try:self.report=collect(self.pm,window)
        except Exception as error:self.error=str(error)

    def __exit__(self,*exception):
        self.pm._environment_observer=None
