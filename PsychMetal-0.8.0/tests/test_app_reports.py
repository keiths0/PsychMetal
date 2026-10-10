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
    def set_content(self,url,content): self.loaded=(url,content)
    def show(self): pass

toga=ModuleType('toga')
for name in ('App','Box','Label','Button','ScrollContainer','MultilineTextInput','MainWindow','WebView','Switch','ImageView'):
    setattr(toga,name,Widget)
pack=ModuleType('toga.style.pack');pack.COLUMN='column';pack.ROW='row';pack.Pack=lambda **kwargs:SimpleNamespace(**kwargs)
sys.modules.update({'toga':toga,'toga.style':ModuleType('toga.style'),'toga.style.pack':pack})
from psychmetaldemos.app import PsychMetalDemos, Kept
app=PsychMetalDemos(); app.formal_name='Demo'; app.startup()
assert not app.report_button.enabled and app.main_window.content is app.page
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
app.finished('Failure',ValueError('test error'))
fn,*args=calls.pop();fn(*args)
assert 'test error' in app.last_output and all(b.enabled for b in app.buttons if b not in app.diagnostic_buttons)
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
app.run_diagnostics=False
app.finished('Quiet demo',None,dict(report_html='unwanted report'))
fn,*args=calls.pop();fn(*args)
assert app.last_report!='unwanted report'
app.start('Frame timing','psychmetaldemos.frame_timing','frame_timing',{})
assert not app.running and 'Turn on Diagnostic mode' in app.printed.text
app.diagnostic_switch.value=True; app.diagnostic_changed(app.diagnostic_switch)
assert all(b.enabled for b in app.diagnostic_buttons)
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
assert len(app.diagnostic_buttons) == 2
app.diagnostic_switch.value=True; app.diagnostic_changed(app.diagnostic_switch)
assert app.diagnostic_section.style.display == 'pack'
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
assert '0.8.0' in menu_labels and not any('BETA' in t for t in menu_labels)
assert '0.8.0 beta' not in help_html
assert 'Diagnostics do not capture images.' in (documents / 'privacy.html').read_text()
assert 'without capturing images or pausing' in (phone / 'store/REVIEW-NOTES.md').read_text()
print('PASS: public version label, synchronized support/privacy pages and current diagnostic review instructions.')

app.running=False
app.diagnostic_switch.value=False
app.start('Native timeline','timeline_demo','timeline_demo',{})
assert not app.running and 'Turn on Diagnostic mode' in app.printed.text
print('PASS: native timeline is gated by Diagnostic mode.')
