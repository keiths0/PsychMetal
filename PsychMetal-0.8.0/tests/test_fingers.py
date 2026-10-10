#!/usr/bin/env python3
"""The iPhone's rules for fingers (PsychMetalIOS.h, with the engine's touch buffer
from PsychMetalEngine.mm): one finger is the pointer, a second down is button
1, a third is Escape, and every finger is reported as it is."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
e = (root / 'PsychMetalEngine.mm').read_text()
h = (root / 'PsychMetalIOS.h').read_text()
ring = e[e.index('#define PM_TOUCH_EVENTS'):e.index('static PMTouchRing touchRing;') + len('static PMTouchRing touchRing;')]
rules = h[h.index('static std::mutex iosInputLock;'):h.index("// --- end of the fingers' rules")]
source = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <vector>
namespace pm {
struct MouseEvent { double time; int button; bool pressed; double x, y; };
struct TouchEvent { double time; int finger; int phase; double x, y; };
struct TouchEvents { std::vector<TouchEvent> events; uint64_t dropped; };
}
''' + ring + rules + r'''
int main() {
    int a, b, c, d;                 // four fingers: their addresses are their identities
    iosPointerX = 400; iosPointerY = 300; iosPointerListening = true;
    // One finger is the pointer, and no button.
    iosNoteFinger(&a, 0, 100, 200, 1.0);
    assert(iosPointerX == 100 && iosPointerY == 200 && !iosClick && !iosEscape && iosPointerCount == 0);
    iosNoteFinger(&a, 1, 110, 205, 1.1);
    assert(iosPointerX == 110 && iosPointerY == 205 && !iosClick);
    // A second finger is button 1, pressed where the pointer is: it does not move the pointer.
    iosNoteFinger(&b, 0, 500, 500, 1.2);
    assert(iosClick && !iosEscape && iosPointerX == 110 && iosPointerCount == 1);
    assert(iosPointerEvents[0].pressed && iosPointerEvents[0].time == 1.2 && iosPointerEvents[0].x == 110 &&
           iosPointerEvents[0].y == 205 && iosPointerEvents[0].button == 1);
    iosNoteFinger(&b, 1, 510, 500, 1.25);
    assert(iosPointerX == 110);
    iosNoteFinger(&a, 1, 120, 205, 1.3);
    assert(iosPointerX == 120);     // the pointer still follows the first finger
    // A third finger is Escape, and the button stays down.
    iosNoteFinger(&c, 0, 600, 600, 1.4);
    assert(iosClick && iosEscape && iosEscapeTime == 1.4 && iosPointerCount == 1);
    iosNoteFinger(&d, 0, 700, 700, 1.45);
    assert(iosEscape && iosDown == 4);
    iosNoteFinger(&d, 2, 700, 700, 1.5);
    assert(iosEscape);
    iosNoteFinger(&c, 2, 600, 600, 1.6);
    assert(iosClick && !iosEscape && iosEscapeTime == 1.6);
    // The pointer's finger lifts: the pointer stays, and with one finger left the button is up.
    iosNoteFinger(&a, 2, 125, 210, 1.7);
    assert(!iosClick && iosPointerX == 125 && iosPointerY == 210 && iosPointerFinger == 0 && iosPointerCount == 2);
    assert(!iosPointerEvents[1].pressed && iosPointerEvents[1].time == 1.7);
    iosNoteFinger(&b, 1, 520, 500, 1.8);
    assert(iosPointerX == 125);     // the finger left over is not the pointer
    iosNoteFinger(&b, 3, 520, 500, 1.9);
    assert(iosDown == 0);
    // The next finger down is the pointer again, and takes the lowest free number.
    iosNoteFinger(&c, 0, 50, 60, 2.0);
    assert(iosPointerX == 50 && iosPointerY == 60 && iosPointerFinger == 1 && !iosClick);
    iosNoteFinger(&d, 1, 9, 9, 2.1);        // a finger not seen going down is not a finger
    assert(iosDown == 1 && iosPointerX == 50);
    // Every finger is reported as it is, once.
    pm::TouchEvents t = touchRing.take();
    assert(t.events.size() == 13 && t.dropped == 0 && touchRing.take().events.empty());
    const int finger[] = {1, 1, 2, 2, 1, 3, 4, 4, 3, 1, 2, 2, 1}, phase[] = {0, 1, 0, 1, 1, 0, 0, 2, 2, 2, 1, 3, 0};
    for (int i = 0; i < 13; i++) assert(t.events[i].finger == finger[i] && t.events[i].phase == phase[i]);
    assert(t.events[2].x == 500 && t.events[2].time == 1.2);
    // A full buffer loses the oldest and says how many.
    for (int i = 0; i < PM_TOUCH_EVENTS + 5; i++) iosNoteFinger(&c, 1, i, 0, 3.0);
    t = touchRing.take();
    assert(t.events.size() == PM_TOUCH_EVENTS && t.dropped == 5 && t.events[0].x == 5);
    puts("PASS: fingers on an iPhone: one is the pointer, a second down is button 1 at the pointer, a third is Escape; "
         "every finger is reported once, and a full buffer says what it lost.");
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 'test.cpp').write_text(source)
    subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', str(p / 'test.cpp'),
                    '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
