"""App result routing and navigation with lightweight UI doubles (not an iOS UI test)."""
import io
import sys
from types import ModuleType, SimpleNamespace

class Widget:
    def __init__(self,*args,**kwargs):
        self.children=[]
        self.args=args
        self.__dict__.update(kwargs)
    def add(self,widget): self.children.append(widget)
    def remove(self,widget):self.children.remove(widget)
    def set_content(self,url,content): self.loaded=(url,content)
    def show(self): pass

toga=ModuleType('toga')
for name in ('App','Box','Label','Button','ScrollContainer','MultilineTextInput','MainWindow','WebView','Switch','ImageView','Slider'):
    setattr(toga,name,Widget)
pack=ModuleType('toga.style.pack');pack.COLUMN='column';pack.ROW='row';pack.Pack=lambda **kwargs:SimpleNamespace(**kwargs)
sys.modules.update({'toga':toga,'toga.style':ModuleType('toga.style'),'toga.style.pack':pack})
from psychmetaldemos.app import PsychMetalDemos, Kept
app=PsychMetalDemos(); app.formal_name='Demo'; app.startup()
assert not app.report_button.enabled and app.main_window.content is app.page
assert not app.diagnostic_host.children
assert all(button in app.diagnostic_section.children for button in
           (app.report_button,app.output_button,app.environment_button,app.share_button))
assert not any(button.enabled for button in
               (app.report_button,app.output_button,app.environment_button,app.share_button))
app.diagnostic_switch.value=True;app.diagnostic_changed(app.diagnostic_switch)
calls=[]
app.loop=SimpleNamespace(call_soon_threadsafe=lambda *a:calls.append(a))
app.streams=(sys.stdout,sys.stderr)
app.kept=(Kept(io.StringIO()),Kept(io.StringIO()))
app.run_diagnostics=True
app.finished('Frame timing',None,dict(report_html='<html>Report</html>'))
assert app.main_window.content is app.page and len(calls)==1 # worker did not touch UI
fn,*args=calls.pop();fn(*args)
assert app.main_window.content is app.report_page and app.report_button.enabled
assert app.report_page.children[1].loaded==('about:blank','<html>Report</html>')
app.back_to_demos(); assert app.main_window.content is app.page
app.show_report(); assert app.main_window.content is app.report_page
app.back_to_demos(); app.show('ordinary demo')
assert app.main_window.content is app.page and app.last_report=='<html>Report</html>'
try:raise ValueError('test error')
except ValueError as raised:failure=raised
app.finished('Failure',failure)
fn,*args=calls.pop();fn(*args)
assert 'test error' in app.last_output and all(b.enabled for b in app.buttons if b not in app.diagnostic_buttons)
import psychmetaldemos.app as shown_module
inside=shown_module._BUNDLE+'app/psychmetaldemos/frame_timing.py'
for path in (inside, '/private'+inside if not inside.startswith('/private') else inside.removeprefix('/private')):
    line=f'{path}:232: UserWarning: PsychMetal:Debugger\n  File "{path}", line 9'
    assert shown_module.bundle_relative(line)=='app/psychmetaldemos/frame_timing.py:232: UserWarning: PsychMetal:Debugger\n  File "app/psychmetaldemos/frame_timing.py", line 9'
# A native view failure must leave both the menu and reopen button available.
real=toga.WebView
class Broken(Widget):
    def set_content(self,*args): raise RuntimeError('native view failure')
toga.WebView=Broken
app.show_report()
assert app.main_window.content is app.page and app.report_button.enabled
assert 'native view failure' in ' '.join(app.printed.text.split()) and app.last_report
# Retry creates a fresh view, rather than a cached, partially built page.
toga.WebView=real
app.show_report(); assert app.main_window.content is app.report_page
assert app.report_page.children[1].loaded[1]==app.last_report
print('PASS: report result reaches main thread, graph page opens, Back/reopen works, ordinary/error results remain usable.')

# Quiet output must not reach either the terminal or the retained report.
sink=io.StringIO(); quiet=Kept(sink,False)
assert quiet.write('timing details')==14 and not sink.getvalue() and not quiet.parts
app.diagnostic_switch.value=False; app.diagnostic_changed(app.diagnostic_switch)
assert all(not b.enabled for b in app.diagnostic_buttons)
assert not app.diagnostic_host.children
assert not any(b.enabled for b in (app.report_button,app.output_button,app.environment_button,app.share_button))
saved=app.report_store.data.copy()
app.diagnostic_changed(app.diagnostic_switch)
assert app.report_store.data==saved and not app.diagnostic_host.children
app.run_diagnostics=False
app.finished('Quiet demo',None,dict(report_html='unwanted report'))
fn,*args=calls.pop();fn(*args)
assert app.last_report!='unwanted report'
app.start('Frame timing','psychmetaldemos.frame_timing','frame_timing',{})
assert not app.running and 'Turn on Diagnostic mode' in app.printed.text
app.diagnostic_switch.value=True; app.diagnostic_changed(app.diagnostic_switch)
assert all(b.enabled for b in app.diagnostic_buttons)
assert app.diagnostic_host.children==[app.diagnostic_section]
print('PASS: diagnostic mode defaults off, suppresses stdout/reports, gates timing tests, and retains errors.')
# A run snapshots the switch and restores controls on completion/failure.
import psychmetaldemos.app as app_module
started=[]
original_start=app_module.pm.start
app_module.pm.start=lambda demo,done: started.append((demo,done))
app.start('Blob array','blob_array_demo','blob_array_demo',{})
assert app.running and not app.diagnostic_switch.enabled
assert all(not b.enabled for b in app.buttons)
assert app.run_diagnostics
import blob_array_demo
from unittest.mock import patch
with patch.object(blob_array_demo, 'blob_array_demo') as invoke:
    started[0][0]()
    invoke.assert_called_once_with(diagnostic=True, inspect_frames=False)
app.start('duplicate','blob_array_demo','blob_array_demo',{})
assert len(started)==1
started[0][1](None,ValueError('run failed'))
fn,*args=calls.pop();fn(*args)
assert not app.running and app.diagnostic_switch.enabled
assert 'run failed' in app.last_output
app_module.pm.start=original_start
print('PASS: switch locks during runs, duplicate starts are refused, and failures restore controls.')

app.diagnostic_switch.value=False
app_module.pm.start=lambda demo,done: started.append((demo,done))
app.start('Blob array','blob_array_demo','blob_array_demo',{})
with patch.object(blob_array_demo,'blob_array_demo') as invoke:
    started[-1][0]()
    invoke.assert_called_once_with(diagnostic=False,inspect_frames=False)
started[-1][1](None,None)
fn,*args=calls.pop();fn(*args)
app_module.pm.start=original_start
print('PASS: Diagnostic mode collects timing without enabling frame capture.')
# Public menu shows teaching notes before launching; privacy is available offline.
from psychmetaldemos.catalogue import GROUPS
entries=[e for _,group in GROUPS for e in group]
assert not any(e[1] in ('inventory_test','readback_test','display_test','kb_demo','kb_queue_demo','gamma_calibration') for e in entries)
first=entries[0]
app.starter(*first)(None)
assert app.main_window.content is not app.page and not app.running
assert app.main_window.content.children[-1].on_press
app.show_help()
assert 'Getting started' in app.main_window.content.children[-1].loaded[1]
app.show_document('privacy.html')
assert 'Privacy policy' in app.main_window.content.children[-1].loaded[1]
app.back_to_demos()
app.streams=(sys.stdout,sys.stderr);app.kept=(Kept(io.StringIO()),Kept(io.StringIO()))
app.finished('Demo',KeyboardInterrupt())
fn,*args=calls.pop();fn(*args)
assert 'Stopped.' in app.last_output and 'could not finish' not in app.last_output
print('PASS: public catalogue, teaching page, offline privacy/help, and Escape treated as a normal stop.')
# A demo with settings shows one picker each on its start page, set to the
# catalogue's defaults, and starts with what was picked.
from psychmetaldemos.catalogue import CHOICES
ring=[e for e in entries if e[0]=='Hidden ring']
assert len(ring)==1 and not [e for e in entries if 'ring' in e[0].lower() and e[0] not in ('Hidden ring','Ring of rectangles')]
app.starter(*ring[0])(None)
def walk(widget):
    yield widget
    for child in getattr(widget,'children',[]): yield from walk(child)
    if hasattr(widget,'content'): yield from walk(widget.content)
page=app.main_window.content
sliders=[x for x in walk(page) if 'tick_count' in x.__dict__]
assert [(x.min,x.max,x.tick_count,x.value) for x in sliders]==[(0,5,6,1),(1,5,5,1)]
numbered=[[c.args[0] for c in x.children if c.args] for x in walk(page)
          if x.children and any(c.args for c in x.children) and all(str(c.args[0]).isdigit() for c in x.children if c.args)]
assert numbered==[['0','1','2','3','4','5'],['1','2','3','4','5']]
sliders[0].value,sliders[1].value=3.0,4.9999
sliders[0].on_change(sliders[0])
assert any(getattr(x,'text',None)=='Noise speed (pixels per frame): 3' for x in walk(page))
started=[]
original_start=app.start
app.start=lambda *a: started.append(a)
page.children[-1].on_press(None)
app.start=original_start
assert started and started[0][1]=='hidden_ring_demo' and started[0][3]==dict(speed=3,cell=5)
assert set(CHOICES)<={e[0] for e in entries}
app.back_to_demos()
print('PASS: Hidden ring is one entry, with speed and cell size chosen by sliders numbered at each stop.')
# Status output belongs to the scrollable menu, never a footer below the screen.
assert len(app.page.children)==1
assert app.printed in app.page.children[0].content.children
print('PASS: bottom status and timing controls remain inside the scrollable menu.')

# Full output lives in a dedicated scrollable WebView and survives navigation.
app.show('first line\n' + 'line\n' * 500 + '<last & line>')
app.show_output()
output_page = app.main_window.content
assert output_page is not app.page
content = output_page.children[1].loaded[1]
assert 'line\n' * 500 in content and '&lt;last &amp; line&gt;' in content
assert '<last & line>' not in content and 'pre-wrap' in content
output_page.children[0].on_press(None)
assert app.main_window.content is app.page
app.show_output()
assert app.main_window.content is not output_page
assert app.main_window.content.children[1].loaded[1] == content
app.diagnostic_switch.value=False; app.diagnostic_changed(app.diagnostic_switch)
assert app.diagnostic_section.style.display == 'none'
assert not app.diagnostic_host.children
assert len(app.diagnostic_buttons) == 2
app.diagnostic_switch.value=True; app.diagnostic_changed(app.diagnostic_switch)
assert app.diagnostic_section.style.display == 'pack'
assert app.diagnostic_host.children==[app.diagnostic_section]
app.diagnostic_changed(app.diagnostic_switch)
assert app.diagnostic_host.children==[app.diagnostic_section]
print('PASS: full output wraps, retains the final line, escapes HTML, reopens, and timing test stays hidden until enabled.')

# Gallery cards preserve every demo action; thumbnails are bundled static art.
assert len(app.buttons) == len(entries)
assert all(b.on_press for b in app.buttons)
listing = app.page.children[0].content
assert listing.style.background_color == '#F3F5F4'
assert app.printed.text.count('\n') <= 2  # full report never expands the menu
print('PASS: gallery keeps all demo actions, readable status, and native scrolling navigation.')

assert not any(e[2] == 'presentation_compare' or e[3].get('presentation') == 'direct' for e in entries)
print('PASS: phone catalogue has one timing test and no presentation-backend comparisons.')

# Store copy must describe the shipped UI, including the no-capture diagnostics.
from pathlib import Path
phone = Path(__file__).resolve().parents[1] / 'phone'
documents = phone / 'src/psychmetaldemos/documents'
help_html = (documents / 'help.html').read_text()
assert (phone / 'store/site/index.html').read_text() == help_html.replace(
    '</body>', '<p><a href="privacy.html">Privacy policy</a></p></body>')
assert (phone / 'store/site/privacy.html').read_bytes() == (documents / 'privacy.html').read_bytes()
def labels(widget):
    return [a for a in widget.args if isinstance(a, str)] + [
        text for child in widget.children for text in labels(child)]
menu_labels = labels(app.page.children[0].content)
assert '0.9.0' in menu_labels and not any('BETA' in t for t in menu_labels)
assert '0.9.0 beta' not in help_html
assert f'<h1>PsychMetal {app_module.pm.version()}</h1>' in help_html
assert f'Version {app_module.pm.version()}.' in help_html
assert f'psychmetal-{app_module.pm.version()}.dist-info' in (documents / 'licenses.html').read_text()
assert 'Diagnostics do not capture images.' in (documents / 'privacy.html').read_text()
assert 'without capturing images or pausing' in (phone / 'store/REVIEW-NOTES.md').read_text()
print('PASS: public version label, synchronized support/privacy pages and current diagnostic review instructions.')

app.running=False
app.diagnostic_switch.value=False
app.start('Native timeline','timeline_demo','timeline_demo',{})
assert not app.running and 'Turn on Diagnostic mode' in app.printed.text
print('PASS: native timeline is gated by Diagnostic mode.')

# Sharing failures, including native completion errors, must remain fully readable.
# They must not replace the saved timing report or strand the Share button.
app.diagnostic_switch.value=True;app.diagnostic_changed(app.diagnostic_switch)
last_report=app.last_report
long_error="cannot import name 'objc_id' <dependency> " + 'very_long_module_path_'*40 + ' END-OF-ERROR'
class FailedShare:
    def present(self,*args): raise ImportError(long_error)
app.running=False;app.share_sheet=FailedShare()
app.share_reports()
error_page=app.main_window.content
assert error_page is not app.page and app.share_button.enabled
content=error_page.children[1].loaded[1]
assert 'END-OF-ERROR' in content and '&lt;dependency&gt;' in content
assert 'pre-wrap' in content and 'overflow-wrap:anywhere' in content
assert app.last_report==last_report
error_page.children[0].on_press(None);assert app.main_window.content is app.page
app.shared(False,long_error)
assert 'END-OF-ERROR' in app.main_window.content.children[1].loaded[1]
assert app.share_button.enabled and app.last_report==last_report
app.back_to_demos();toga.WebView=Broken
app.share_reports()
assert app.main_window.content is app.page and app.share_button.enabled
assert 'END-OF-ERROR' in app.printed.text and '\n' in app.printed.text
toga.WebView=real
print('PASS: share errors wrap and scroll completely, preserve reports, allow retry, and have a readable fallback.')

# Exercise the actual teaching-page Start button after sharing has completed.
app.share_sheet=SimpleNamespace(active=False)
app_module.pm.start=lambda demo,done:started.append((demo,done))
app.starter(*first)(None)
app.main_window.content.children[-1].on_press(None)
assert app.running and app.main_window.content is app.page
started[-1][1](None,None)
fn,*args=calls.pop();fn(*args)
assert not app.running and app.share_button.enabled
app_module.pm.start=original_start
print('PASS: Start demonstration launches after sharing completes and controls recover.')

with patch.object(app_module,'Reports',return_value=app.report_store):
    reopened=PsychMetalDemos();reopened.formal_name='Demo';reopened.startup()
assert reopened.last_report and reopened.last_output
assert not reopened.diagnostic_switch.value and not reopened.diagnostic_host.children
assert not any(b.enabled for b in (reopened.report_button,reopened.output_button,reopened.environment_button,reopened.share_button))
reopened.diagnostic_switch.value=True;reopened.diagnostic_changed(reopened.diagnostic_switch)
assert reopened.diagnostic_host.children==[reopened.diagnostic_section]
assert all(b.enabled for b in (reopened.report_button,reopened.output_button,reopened.environment_button,reopened.share_button))
print('PASS: optional tasks and every report tool detach with diagnostics off, including saved reports on launch; toggling restores them without duplicates or data loss.')
