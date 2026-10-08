"""PsychMetal Demos: a list of what the psychmetal package can show, and a page
for what each run printed.

A button starts its demo on a thread of its own, because on a phone the main
thread belongs to the app; the engine puts its window over this one and takes
it away when the demo ends. What the demo printed, which on a Mac goes to the
terminal, is kept and shown here.
"""
import importlib
import io
import platform
import sys
import textwrap
import traceback

import numpy as np
import toga
from toga.style.pack import COLUMN, Pack

import psychmetal as pm

from .catalogue import GROUPS


class Kept(io.TextIOBase):
    """Text written here goes on to where it was going, and is kept."""

    def __init__(self, onward):
        self.onward, self.parts = onward, []

    def write(self, text):
        self.parts.append(text)
        return self.onward.write(text)

    def flush(self):
        self.onward.flush()


class PsychMetalDemos(toga.App):
    def startup(self):
        self.buttons = []
        self.last_report = None
        self.report_page = None
        listing = toga.Box(style=Pack(direction=COLUMN))
        # A label is one line however long: lines are broken here, short enough
        # for a phone held upright.
        def lines(text):
            return toga.Label(textwrap.fill(text, 46), style=Pack(margin=(0, 16, 4, 16), font_size=11))

        listing.add(lines(f'psychmetal {pm.version()}, Python {platform.python_version()}, numpy {np.__version__}'))
        listing.add(lines('Usually: one finger is the pointer, a second clicks, a third is Escape. Blob array: hold one finger to drag; lift to release.'))
        for group, entries in GROUPS:
            listing.add(toga.Label(group, style=Pack(margin=(14, 12, 2, 12), font_weight='bold')))
            for title, module, function, arguments, about in entries:
                button = toga.Button(title, on_press=self.starter(title, module, function, arguments),
                                     style=Pack(margin=(4, 12, 0, 12)))
                self.buttons.append(button)
                listing.add(button)
                if about:
                    listing.add(lines(about))
        self.printed = toga.MultilineTextInput(readonly=True, placeholder='What a demo prints appears here.',
                                               style=Pack(flex=1, margin=8, font_family='monospace', font_size=10))
        page = toga.Box(style=Pack(direction=COLUMN))
        page.add(toga.ScrollContainer(content=listing, horizontal=False, style=Pack(flex=2)))
        page.add(self.printed)
        self.report_button = toga.Button("View last timing report", on_press=self.show_report, enabled=False,
                                         style=Pack(margin=8))
        page.add(self.report_button)
        self.page = page
        self.main_window = toga.MainWindow(title=self.formal_name)
        self.main_window.content = page
        self.main_window.show()

    def starter(self, title, module, function, arguments):
        def press(widget, **kwargs):
            self.start(title, module, function, arguments)
        return press

    def start(self, title, module, function, arguments):
        for button in self.buttons:
            button.enabled = False
        self.report_button.enabled = False
        self.printed.value = f'{title}: running...'
        self.kept = Kept(sys.stdout), Kept(sys.stderr)
        self.streams = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = self.kept

        def demo():
            return getattr(importlib.import_module(module), function)(**arguments)

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
                text += '\n\n' + ''.join(traceback.format_exception(error)[-8:]).strip()
        finally:
            report = result.get("report_html") if isinstance(result, dict) else None
            self.loop.call_soon_threadsafe(self.show, text.strip(), report if isinstance(report, str) else None)

    def show(self, text, report=None):
        self.printed.value = text
        for button in self.buttons:
            button.enabled = True
        if report:
            self.last_report = report
            self.report_page = None
            self.show_report()
        self.report_button.enabled = self.last_report is not None

    def show_report(self, widget=None, **kwargs):
        if self.last_report is None:
            return
        if self.report_page is None:
            web = toga.WebView(style=Pack(flex=1))
            web.set_content("about:blank", self.last_report)
            self.report_page = toga.Box(style=Pack(direction=COLUMN))
            self.report_page.add(toga.Button("Back to demos", on_press=self.back_to_demos, style=Pack(margin=8)))
            self.report_page.add(web)
        self.main_window.content = self.report_page

    def back_to_demos(self, widget=None, **kwargs):
        self.main_window.content = self.page


def main():
    return PsychMetalDemos()
