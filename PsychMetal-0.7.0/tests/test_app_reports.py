"""App result routing and navigation with lightweight UI doubles (not an iOS UI test)."""
import io
import sys
from types import ModuleType, SimpleNamespace

class Widget:
    def __init__(self,*args,**kwargs):
        self.children=[]
        self.__dict__.update(kwargs)
    def add(self,widget): self.children.append(widget)
    def set_content(self,url,content): self.loaded=(url,content)
    def show(self): pass

toga=ModuleType('toga')
for name in ('App','Box','Label','Button','ScrollContainer','MultilineTextInput','MainWindow','WebView'):
    setattr(toga,name,Widget)
pack=ModuleType('toga.style.pack');pack.COLUMN='column';pack.Pack=lambda **kwargs:kwargs
sys.modules.update({'toga':toga,'toga.style':ModuleType('toga.style'),'toga.style.pack':pack})
from psychmetaldemos.app import PsychMetalDemos, Kept
app=PsychMetalDemos(); app.formal_name='Demo'; app.startup()
assert not app.report_button.enabled and app.main_window.content is app.page
calls=[]
app.loop=SimpleNamespace(call_soon_threadsafe=lambda *a:calls.append(a))
app.streams=(sys.stdout,sys.stderr)
app.kept=(Kept(io.StringIO()),Kept(io.StringIO()))
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
assert 'test error' in app.printed.value and all(b.enabled for b in app.buttons)
print('PASS: report result reaches main thread, graph page opens, Back/reopen works, ordinary/error results remain usable.')
