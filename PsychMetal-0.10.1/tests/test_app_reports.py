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
assert app.main_window.content.children[2].children[0].on_press
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
# Launch stays fixed; full-width settings precede notes in the scroll area.
assert page.children[2].children[0].args[0]=='Start demo'
assert page.children[2].style.direction=='column'
assert not hasattr(page.children[2].children[0].style,'width')
assert all(x in list(walk(page.children[-1].content.children[0])) for x in sliders)
assert all(x.style.flex==1 for x in sliders)
assert page.children[-1].content.children[1].args[0]=='How to use'
sliders[0].value,sliders[1].value=3.0,4.9999
sliders[0].on_change(sliders[0])
assert any(' '.join(getattr(x,'text','').split())=='Noise speed (pixels per frame): 3' for x in walk(page))
started=[]
original_start=app.start
app.start=lambda *a: started.append(a)
page.children[2].children[0].on_press(None)
app.start=original_start
assert started and started[0][1]=='hidden_ring_demo' and started[0][3]==dict(speed=3,cell=5)
assert set(CHOICES)<={e[0] for e in entries}
app.back_to_demos()
print('PASS: Hidden ring is one entry, with speed and cell size chosen below the full-width Start button with live value labels.')
hdr=next(e for e in entries if e[0]=='HDR brightness')
app.starter(*hdr)(None);page=app.main_window.content
sliders=[x for x in walk(page) if 'tick_count' in x.__dict__]
assert not sliders and 'HDR brightness' not in CHOICES
started=[];app.start=lambda *a: started.append(a)
page.children[2].children[0].on_press(None);app.start=original_start
assert started[0][1]=='hdr_demo' and started[0][3]==dict(flicker_hz=16)
app.back_to_demos()
print('PASS: HDR starts at its default target without a start-page slider; rate controls belong to the running demo.')
groups=dict(__import__('psychmetaldemos.catalogue',fromlist=['GROUPS']).GROUPS)
assert 'Noise and hidden boundaries' not in groups
assert {e[0] for e in groups['Noise']}=={'Changing noise','Hidden ring'}
assert any(e[0]=='Ring of rectangles' for e in groups['Shapes and textures'])
noise=next(e for e in entries if e[0]=='Changing noise')
app.starter(*noise)(None);page=app.main_window.content
sliders=[x for x in walk(page) if 'tick_count' in x.__dict__]
assert [(x.min,x.max,x.tick_count,x.value) for x in sliders]==[(1,5,5,1),(1,60,60,1)]
sliders[0].value=3;sliders[1].value=7;started=[]
app.start=lambda *a:started.append(a)
page.children[2].children[0].on_press(None);app.start=original_start
assert started[0][3]==dict(cell=3,frames_per_update=7,noise_type='grayscale')
noise_button=next(x for x in walk(page) if getattr(x,'args',()) and x.args[0]=='2. Grayscale noise')
for label,kind in [('3. Colored noise','colored'),('1. Binary noise','binary'),('2. Grayscale noise','grayscale')]:
    noise_button.on_press(noise_button)
    assert noise_button.text==label
    started=[];app.start=lambda *a:started.append(a)
    page.children[2].children[0].on_press(None);app.start=original_start
    assert started[0][3]==dict(cell=3,frames_per_update=7,noise_type=kind)
app.back_to_demos()
print('PASS: Ring of rectangles is in Shapes; Noise contains two demos and Changing noise forwards cell size/update frames.')


for entry in entries:
    app.starter(*entry)(None)
    teaching=app.main_window.content
    launch=teaching.children[2].children[0]
    assert launch.args[0]==('Create movie' if entry[1]=='export_demo' else 'Start demo')
    assert launch.style.height>=60 and launch.style.background_color=='#146C66'
    assert hasattr(teaching.children[-1],'content')
    assert not hasattr(teaching.children[2],'content')
app.back_to_demos()
print('PASS: all demo pages show a prominent launch action before scrolling instructions.')

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
assert listing.style.background_color == '#DDE2E0'
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
assert '0.10.1' in menu_labels and not any('BETA' in t for t in menu_labels)
assert '0.10.1 beta' not in help_html
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
    active=False
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
app.main_window.content.children[2].children[0].on_press(None)
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

app.diagnostic_switch.value=False; app.diagnostic_changed(app.diagnostic_switch)
app.run_diagnostics=False
app.streams=(sys.stdout,sys.stderr); app.kept=(Kept(io.StringIO()),Kept(io.StringIO()))
app.finished('Sound recorder',RuntimeError('microphone test failure'))
fn,*args=calls.pop(); fn(*args)
assert app.main_window.content is not app.page
assert 'microphone test failure' in app.main_window.content.children[-1].loaded[1]
app.back_to_demos()
assert app.main_window.content is app.page and not app.running
print('PASS: failed demos open readable error output with diagnostic mode off.')

import tempfile
from pathlib import Path
import movie_demo, record_demo, export_demo
with tempfile.TemporaryDirectory() as directory:
    app.paths=SimpleNamespace(data=Path(directory))
    app_module.pm.start=lambda demo,done: started.append((demo,done))
    for module, function in ((movie_demo,'movie_demo'),(record_demo,'record_demo'),(export_demo,'export_demo')):
        app.start('Video',module.__name__,function,{})
        with patch.object(module,function) as invoke:
            started[-1][0]()
            options=invoke.call_args.kwargs
            if module is movie_demo:
                assert options['path'].is_file() and options['path'].suffix=='.mp4'
            else:
                assert options['path']==Path(directory)/'movies/stimulus.mp4'
                assert options['path'].parent.is_dir()
                if module is record_demo:assert options['codec']=='h264' and options['scale']==0.5
                else:assert options==dict(path=Path(directory)/'movies/stimulus.mp4',seconds=3.0)
        started[-1][1](None,None)
        fn,*args=calls.pop(); fn(*args)
    app_module.pm.start=original_start
print('PASS: phone movies use a bundled sample and writable app-local recording path.')

with tempfile.TemporaryDirectory() as directory:
    app.movie_path=Path(directory)/'stimulus.mp4'
    app.movie_path.write_bytes(b'completed recording')
    app.diagnostic_switch.value=False
    app.diagnostic_changed(app.diagnostic_switch)
    assert app.movie_share_button.enabled and not app.diagnostic_host.children
    class MovieSheet:
        active=False
        def present(self, window, exporter, done):
            self.active=True
            self.files=exporter.export(Path(directory)/'shared')
            self.done=done
    app.share_sheet=MovieSheet()
    app.share_movie()
    assert not app.movie_share_button.enabled and app.share_sheet.active
    app.share_sheet.active=False;app.share_sheet.done(False,None)
    assert app.movie_share_button.enabled and 'cancelled' in app.printed.text
    assert app.movie_path.is_file() and not app.diagnostic_host.children
    app.running=True;app.diagnostic_changed(app.diagnostic_switch)
    assert not app.movie_share_button.enabled
    app.running=False;app.share_sheet=None
print('PASS: movie export works outside diagnostics, cancellation restores sharing, and running demos disable export.')
# Export has a visible success page even with Diagnostic mode off, and verifies
# the file before reporting success. Completion still dispatches UI to main.
with tempfile.TemporaryDirectory() as directory:
    app.movie_path=Path(directory)/'stimulus.mp4'
    app.movie_path.write_bytes(b'completed movie')
    result=dict(exportedMovie=True,path=str(app.movie_path),duration=3,frames=180,width=640,height=480)
    app.run_diagnostics=False;app.diagnostic_switch.value=False
    app.streams=(sys.stdout,sys.stderr);app.kept=(Kept(io.StringIO()),Kept(io.StringIO()))
    app.back_to_demos();app.running=True
    app.finished('Export a stimulus',None,result)
    assert app.main_window.content is app.page
    fn,*args=calls.pop();fn(*args)
    assert not app.running and app.main_window.content is not app.page
    content=app.main_window.content.children[0].content
    assert content.children[0].args[0]=='Movie ready'
    assert '180 frames' in content.children[1].args[0]
    assert app.export_share_button.enabled and not app.diagnostic_host.children
    assert 'Movie saved' in app.printed.text
    # Preview must use the exported file, not the bundled numbered sample.
    app_module.pm.start=lambda demo,done: started.append((demo,done))
    content.children[3].on_press(None)
    with patch.object(movie_demo,'movie_demo') as invoke:
        started[-1][0]()
        assert invoke.call_args.kwargs==dict(path=app.movie_path,sound='off')
    started[-1][1](None,None);fn,*args=calls.pop();fn(*args)
    app_module.pm.start=original_start
    # Both share buttons track an active sheet and recover after cancellation.
    app.show_movie_saved(result)
    app.share_sheet=MovieSheet()
    app.export_share_button.on_press(None)
    assert app.share_sheet.active and not app.export_share_button.enabled and not app.movie_share_button.enabled
    app.share_sheet.active=False;app.share_sheet.done(False,None)
    assert app.export_share_button.enabled and app.movie_share_button.enabled
    assert 'cancelled' in app.export_status.text
    app.share_sheet=None
    # Missing, empty and wrong-path files become visible errors, not success.
    for variant in ('missing','empty','wrong'):
        if app.movie_path.exists():app.movie_path.unlink()
        if variant=='empty':app.movie_path.touch()
        bad=dict(result)
        if variant=='wrong':bad['path']=str(Path(directory)/'other.mp4')
        app.finished('Export a stimulus',None,bad)
        fn,*args=calls.pop();fn(*args)
        assert 'readable saved movie' in app.last_output and app.main_window.content is not app.page
        assert app.main_window.content.children[1].loaded[1].find('readable saved movie')>=0
print('PASS: export success is visible without diagnostics, preview uses the saved clip, sharing recovers after cancel, and missing/empty/wrong files show errors.')
