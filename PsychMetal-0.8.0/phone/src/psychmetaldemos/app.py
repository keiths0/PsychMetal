"""PsychMetal Demos: a list of what the psychmetal package can show, and a page
for what each run printed.

A button starts its demo on a thread of its own, because on a phone the main
thread belongs to the app; the engine puts its window over this one and takes
it away when the demo ends. What the demo printed, which on a Mac goes to the
terminal, is kept and shown here.
"""
import html
import importlib
import io
import json
import sys
import textwrap
import traceback
from pathlib import Path

import toga
from toga.style.pack import COLUMN, ROW, Pack

import psychmetal as pm

from .catalogue import GROUPS
from .reports import Reports
from .sharing import ShareSheet
from .lifecycle import MainThreadCollections


class Kept(io.TextIOBase):
    """Text written here goes on to where it was going, and is kept."""

    def __init__(self, onward, enabled=True):
        self.onward, self.parts = onward, []
        self.enabled = enabled

    def write(self, text):
        if self.enabled:
            self.parts.append(text)
            return self.onward.write(text)
        return len(text)

    def flush(self):
        self.onward.flush()


class PsychMetalDemos(toga.App):
    def startup(self):
        self.buttons = []
        self.diagnostic_buttons = []
        self.running = False
        self.run_diagnostics = False
        self.last_report = None
        self.report_page = None
        self.last_output = None
        self.report_store = Reports(self.paths.data/'reports' if sys.platform=='ios' else None)
        self.last_report=self.report_store.data['timingHTML']
        self.last_output=self.report_store.data['output']
        self.last_environment=self.report_store.data['environment']
        self.gc_policy=None
        self.share_sheet=None
        # Static artwork belongs only to the menu, never the timed Metal window.
        ink, muted, accent, paper = '#172231', '#536371', '#146C66', '#F3F5F4'
        art = Path(__file__).parent / 'art'
        self.diagnostic_section = toga.Box(style=Pack(direction=COLUMN))
        listing = toga.Box(style=Pack(direction=COLUMN, background_color=paper, margin_bottom=28))

        def label(text, size=15, color=ink, margin=(0, 20, 8, 20), bold=False, wrap=40):
            return toga.Label(textwrap.fill(text, wrap), style=Pack(
                margin=margin, font_size=size, color=color,
                font_weight='bold' if bold else 'normal'))

        brand = toga.Box(style=Pack(direction=ROW, align_items='center', margin=(20, 20, 12, 20)))
        brand.add(toga.Label('PsychMetal', style=Pack(flex=1, font_size=32, font_weight='bold', color=ink)))
        brand.add(toga.Label('0.8.0', style=Pack(font_size=11, font_weight='bold', color=accent)))
        listing.add(brand)
        artwork = toga.Box(style=Pack(direction=ROW, margin=(0, 20, 16, 20)))
        artwork.add(toga.ImageView(art / 'hero.png', style=Pack(flex=1, height=104)))
        listing.add(artwork)
        listing.add(label('See perception in motion.', size=23, bold=True, wrap=28))
        listing.add(label('Visual presentation for psychophysics, powered by native Metal.', color=muted))
        listing.add(label('The same stimuli on iPhone and Apple Silicon Macs. Python, Octave and MATLAB on the Mac.', size=13, color=muted, wrap=44))
        listing.add(label('Three fingers returns to the menu. Some demos include rapid flicker.', size=12, color=muted, margin=(4,20,12,20), wrap=44))

        previews = {
            'minimal_demo': ('rectangle', 'Shape & colour'),
            'mouse_rect_demo': ('rectangle', 'Touch & positioning'),
            'texture_demo': ('textures', 'Rotation & colour'),
            'blob_array_demo': ('array', 'Flicker & frequency · drag to move'),
            'timeline_demo': ('array', 'Native frame-counted playback'),
            'blob_demo': ('blob', 'Contrast · touch to move'),
            'gabor_demo': ('gabor', 'Orientation & motion'),
            'dot_demo': ('dots', 'Motion in a field of dots'),
            'masked_image_demo': ('textures', 'One image · four apertures'),
            'shader_demo': ('gabor', 'Custom Metal · shared source'),
            'stimulus_demo': ('noise', 'Reveal a soft boundary'),
            'noise_demo': ('noise', 'Random patterns in time'),
            'psychmetaldemos.noise_annulus': ('ring', 'Motion reveals a hidden ring'),
            'psychmetaldemos.finger_ring': ('dots', 'Touch & rotation'),
            'psychmetaldemos.frame_timing': ('gabor', 'Presentation timing'),
        }
        # Put the signature demos first; every catalogue entry keeps its action.
        ordered = sorted(GROUPS, key=lambda item: {'Contrast and motion':0, 'Shapes and textures':1,
                        'Noise and hidden boundaries':2, 'Optional diagnostics':3}[item[0]])
        for group, entries in ordered:
            target = self.diagnostic_section if group == 'Optional diagnostics' else listing
            target.add(label(group.upper(), size=12, color=muted, bold=True, margin=(20,20,8,20)))
            for title, module, function, arguments, about in entries:
                picture, caption = previews[module]
                card = toga.Box(style=Pack(direction=ROW, align_items='center',
                                          background_color='#FFFFFF', margin=(0,20,8,20)))
                card.add(toga.ImageView(art / (picture + '.png'), style=Pack(width=52, height=52, margin=12)))
                detail = toga.Box(style=Pack(direction=COLUMN, flex=1, margin=(12,0,12,0)))
                detail.add(label(title, size=16, bold=True, margin=(0,0,4,0), wrap=20))
                detail.add(label(caption, size=12, color=muted, margin=0, wrap=23))
                card.add(detail)
                button = toga.Button('Open', on_press=self.starter(title,module,function,arguments,about),
                                     style=Pack(width=52, height=48, margin=(8,8,8,4), font_size=14, color=accent))
                if group == 'Optional diagnostics':
                    self.diagnostic_buttons.append(button)
                    button.enabled = False
                self.buttons.append(button)
                card.add(button)
                target.add(card)

        listing.add(label('TOOLS & INFORMATION', size=12, color=muted, bold=True, margin=(24,20,8,20)))
        self.diagnostic_switch = toga.Switch('Diagnostic mode', value=False,
            on_change=self.diagnostic_changed, style=Pack(margin=(8,20,8,20), color=ink, font_size=15))
        listing.add(self.diagnostic_switch)
        listing.add(label('Show the timing test and collect reports.', size=12, color=muted, wrap=44))
        listing.add(self.diagnostic_section)
        self.diagnostic_section.style.display = 'none'
        self.report_button = toga.Button('View last timing report', on_press=self.show_report, enabled=False,
            style=Pack(margin=(4,20,4,20), height=48, color=accent, background_color='#FFFFFF'))
        self.output_button = toga.Button('View last demo output', on_press=self.show_output, enabled=False,
            style=Pack(margin=(4,20,4,20), height=48, color=accent, background_color='#FFFFFF'))
        self.report_button.style.display = 'none'
        self.output_button.style.display = 'none'
        listing.add(self.report_button)
        listing.add(self.output_button)
        self.environment_button=toga.Button('Device & presentation report',on_press=self.show_environment,
            style=Pack(margin=(4,20,4,20),height=48,color=accent))
        self.share_button=toga.Button('Share reports',on_press=self.share_reports,
            enabled=any(self.report_store.data.get(k) for k in ('output','timingHTML','environment')),
            style=Pack(margin=(4,20,4,20),height=48,color=accent))
        listing.add(self.environment_button)
        listing.add(self.share_button)
        listing.add(toga.Button('About, help & privacy' , on_press=self.show_help,
            style=Pack(margin=(4,20,12,20), height=48, color=accent)))
        # A short status only. Complete output is retained in its dedicated page.
        self.printed = toga.Label('Choose a demonstration to begin.',
            style=Pack(margin=(0,20,8,20), font_size=12, color=muted))
        listing.add(self.printed)
        page = toga.Box(style=Pack(direction=COLUMN, background_color=paper))
        page.add(toga.ScrollContainer(content=listing, horizontal=False, style=Pack(flex=1, background_color=paper)))
        self.page = page
        self.main_window = toga.MainWindow(title=self.formal_name)
        self.main_window.content = page
        self.main_window.show()
        self.report_button.enabled=self.last_report is not None
        self.output_button.enabled=self.last_output is not None
        self.report_button.style.display='pack' if self.last_report is not None else 'none'
        self.output_button.style.display='pack' if self.last_output is not None else 'none'
        if sys.platform=='ios':
            self.gc_policy=MainThreadCollections(self.loop,lambda:not self.running)
            self.on_exit=self.prepare_exit

    def diagnostic_changed(self, widget, **kwargs):
        self.diagnostic_section.style.display = "pack" if widget.value else "none"
        for button in self.diagnostic_buttons:
            button.enabled = bool(widget.value) and not self.running

    def starter(self, title, module, function, arguments, about=''):
        def press(widget, **kwargs):
            page = toga.Box(style=Pack(direction=COLUMN))
            page.add(toga.Button('Back to demos', on_press=self.back_to_demos, style=Pack(margin=12, height=48)))
            content = toga.Box(style=Pack(direction=COLUMN))
            content.add(toga.Label(title, style=Pack(margin=16, font_size=24, font_weight='bold')))
            for paragraph in (about, 'Tap with three fingers together to return to the menu at any time.',
                              'Turn your device before starting to choose portrait or landscape. The demonstration keeps that orientation.'):
                content.add(toga.Label(textwrap.fill(paragraph, 40), style=Pack(margin=16, font_size=16)))
            page.add(toga.ScrollContainer(content=content, horizontal=False, style=Pack(flex=1)))
            page.add(toga.Button('Start demonstration', on_press=lambda widget, **kw: self.start(title, module, function, arguments),
                                 style=Pack(margin=16, height=52)))
            self.main_window.content = page
        return press

    def show_help(self, widget=None, **kwargs):
        self.show_document('help.html')

    def show_document(self, name):
        # These documents are bundled, readable offline, and contain no scripts.
        text = (Path(__file__).parent / 'documents' / name).read_text(encoding='utf-8')
        page = toga.Box(style=Pack(direction=COLUMN))
        page.add(toga.Button('Back to demos', on_press=self.back_to_demos, style=Pack(margin=8, height=48)))
        for title, document in [('Help', 'help.html'), ('Privacy', 'privacy.html'), ('Licenses', 'licenses.html')]:
            page.add(toga.Button(title, on_press=lambda widget, name=document, **kw: self.show_document(name), style=Pack(margin=4, height=44)))
        web = toga.WebView(style=Pack(flex=1))
        page.add(web)
        self.main_window.content = page
        web.set_content('about:blank', text)

    def start(self, title, module, function, arguments):
        if self.running:
            return
        if self.share_sheet is not None and self.share_sheet.active:
            return
        if self.gc_policy is not None:self.gc_policy.collect()
        self.run_diagnostics = bool(self.diagnostic_switch.value)
        if module in ("psychmetaldemos.frame_timing", "timeline_demo") and not self.run_diagnostics:
            self.printed.text = f"Turn on Diagnostic mode to run {title}."
            return
        self.main_window.content = self.page
        self.running = True
        self.diagnostic_switch.enabled = False
        for button in self.buttons:
            button.enabled = False
        self.report_button.enabled = False
        self.output_button.enabled = False
        self.environment_button.enabled=self.share_button.enabled=False
        self.printed.text = f'{title}: running...'
        self.kept = Kept(sys.stdout, self.run_diagnostics), Kept(sys.stderr)
        self.streams = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = self.kept

        def demo():
            options = dict(arguments)
            if module == "blob_array_demo":
                options["diagnostic"] = self.run_diagnostics
                options["inspect_frames"] = False
            invoke=getattr(importlib.import_module(module),function)
            if not self.run_diagnostics:return invoke(**options)
            from psychmetal.environment import Capture
            with Capture(pm) as capture:
                try:return invoke(**options)
                finally:self.run_environment=capture


        self.run_environment=None
        try:
            pm.start(demo, done=lambda result, error: self.finished(title, error, result))
        except Exception as error:
            self.finished(title, error)

    def finished(self, title, error, result=None):
        """Called on the demo's thread: the page is changed on the main one."""
        sys.stdout, sys.stderr = self.streams
        text = title
        try:
            text += '\n\n' + ''.join(self.kept[0].parts + self.kept[1].parts).strip()
            if isinstance(error, KeyboardInterrupt):
                text += '\n\nStopped.'
            elif error is not None:
                text += '\n\nThe demonstration could not finish. Please try again.\n' + str(error)
                if self.run_diagnostics:
                    text += '\n' + ''.join(traceback.format_exception(error)[-8:]).strip()
            else:
                text += '\n\nFinished. Choose another demonstration to explore.'
        finally:
            report = result.get("report_html") if self.run_diagnostics and isinstance(result, dict) else None
            capture=getattr(self,'run_environment',None)
            environment=capture.report if capture is not None else None
            if capture is not None and capture.error:text+='\nEnvironment report unavailable: '+capture.error
            self.loop.call_soon_threadsafe(self.show, text.strip(), report if isinstance(report, str) else None,environment)

    def show(self, text, report=None, environment=None):
        self.last_output = text
        self.output_button.enabled = True
        self.output_button.style.display = 'pack'
        self.printed.text = textwrap.fill(text.split('\n',1)[0] + ' — output ready.', 42)
        self.running = False
        self.diagnostic_switch.enabled = True
        for button in self.buttons:
            button.enabled = True
        self.diagnostic_changed(self.diagnostic_switch)
        if report:
            self.last_report = report
        # Enable reopening before attempting native WebView creation; a failed
        # HTML view must never leave the report button disabled.
        self.report_button.enabled = self.last_report is not None
        self.report_button.style.display = 'pack' if self.last_report is not None else 'none'
        if environment:self.last_environment=environment
        self.environment_button.enabled=True
        try:self.report_store.update(output=text,timing=report,environment=environment)
        except OSError as error:self.printed.text='Report kept for this session; saving failed: '+str(error)
        self.share_button.enabled=True
        if report:
            self.show_report()
        if self.gc_policy is not None:self.gc_policy.collect()

    def show_output(self, widget=None, **kwargs):
        if self.last_output is None:
            return
        try:
            page = toga.Box(style=Pack(direction=COLUMN))
            page.add(toga.Button("Back to demos", on_press=self.back_to_demos,
                                 style=Pack(margin=8, height=48)))
            web = toga.WebView(style=Pack(flex=1))
            page.add(web)
            self.main_window.content = page
            # One native scrolling surface: no fixed-height text field nested
            # inside another scroll view. Wrap long lines and retain all output.
            document = ('<!doctype html><html><head><meta name="viewport" '
                        'content="width=device-width,initial-scale=1">'
                        '<style>html{color-scheme:light dark}body{margin:0;padding:20px 16px 48px;'
                        'font:16px -apple-system,sans-serif}pre{white-space:pre-wrap;'
                        'overflow-wrap:anywhere;font:14px ui-monospace,monospace;line-height:1.5}'
                        '</style></head><body><h1>Demo output</h1><pre>'
                        + html.escape(self.last_output) + '</pre></body></html>')
            web.set_content("about:blank", document)
        except Exception as error:
            self.main_window.content = self.page
            self.printed.text = "Could not open the output: " + str(error)

    def show_report(self, widget=None, **kwargs):
        if self.last_report is None:
            self.printed.text = "No timing report yet. Run Frame timing first."
            return
        try:
            # Build a fresh native view when reopening. Attach it before loading
            # HTML instead of reusing a detached WKWebView across page swaps.
            web = toga.WebView(style=Pack(flex=1))
            page = toga.Box(style=Pack(direction=COLUMN))
            page.add(toga.Button("Back to demos", on_press=self.back_to_demos,
                                 style=Pack(margin=8, height=48)))
            page.add(web)
            self.report_page = page
            self.main_window.content = page
            web.set_content("about:blank", self.last_report)
        except Exception as error:
            self.main_window.content = self.page
            self.report_page = None
            self.printed.text = textwrap.fill("Could not open the graph: " + str(error) + ". Try View last timing report again.", 42)

    def show_environment(self, widget=None, **kwargs):
        if self.running:return
        try:
            if self.last_environment is None:
                self.last_environment=pm.environment_report()
                self.report_store.update(environment=self.last_environment)
            text=json.dumps(self.last_environment,allow_nan=False,indent=2)
            page=toga.Box(style=Pack(direction=COLUMN))
            page.add(toga.Button('Back to demos',on_press=self.back_to_demos,style=Pack(margin=8,height=48)))
            web=toga.WebView(style=Pack(flex=1));page.add(web);self.main_window.content=page
            web.set_content('about:blank','<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{padding:16px}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style><h1>Device &amp; presentation</h1><pre>'+html.escape(text)+'</pre>')
            self.share_button.enabled=True
        except Exception as error:self.printed.text='Could not open device report: '+str(error)

    def share_reports(self, widget=None, **kwargs):
        if self.running:return
        try:
            if self.share_sheet is None:self.share_sheet=ShareSheet(self.loop)
            self.share_sheet.present(self.main_window,self.report_store,self.shared)
            self.share_button.enabled=False
        except Exception as error:self.printed.text='Could not share reports: '+str(error)

    def shared(self, successful, error):
        self.share_button.enabled=True
        self.printed.text=('Could not share reports: '+error) if error else 'Reports shared.' if successful else 'Sharing cancelled. Reports are still available.'

    def prepare_exit(self, widget=None, **kwargs):
        if self.running:
            pm.stop();return False  # let native close run while the app loop lives
        if self.gc_policy is not None:self.gc_policy.close()
        return True

    def back_to_demos(self, widget=None, **kwargs):
        self.main_window.content = self.page
        self.report_page = None
        if self.gc_policy is not None:self.gc_policy.collect()


def main():
    return PsychMetalDemos()
