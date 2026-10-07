"""pm::flipStatus, extracted from the engine: what the display has reported of the
last flip's frame is read when it is asked for, so a report that arrives after
Flip has returned is not lost, and the session's count is the engine's own."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'PsychMetalEngine.mm').read_text()
a = s.index('pm::FlipStatus pm::flipStatus() {'); b = s.index('\n}\n', a) + 3
body = s[a:b].replace('pm::FlipStatus pm::flipStatus()', 'FlipStatus flipStatus()').replace('pm::FlipStatus', 'FlipStatus')
source = r'''
#include <cassert>
#include <cstdint>
#include <stdexcept>
struct Record { uint64_t token; int status, done; double presented; };
struct FlipStatus { bool confirmed, dropped; uint64_t droppedFrames; };
static Record rec[4];
static int device = 1, lock = 0;
static bool closing = false, locked = false;
static uint64_t lastFlipToken = 0, missingPresentedCount = 0;
[[noreturn]] static void fail(const char *m) { throw std::runtime_error(m); }
static void pthread_mutex_lock(int *) { assert(!locked); locked = true; }
static void pthread_mutex_unlock(int *) { assert(locked); locked = false; }
static Record *recordFor(uint64_t t) { Record *r = &rec[t % 4]; return r->token == t ? r : nullptr; }
''' + body + r'''
int main() {
    FlipStatus f = flipStatus();                       // no flip yet
    assert(!f.confirmed && !f.dropped && f.droppedFrames == 0 && !locked);
    rec[1] = {1, 2, 0, 0}; lastFlipToken = 1;          // Flip has returned; nothing reported
    f = flipStatus(); assert(!f.confirmed && !f.dropped);
    rec[1].status = 1; rec[1].done = 1; missingPresentedCount = 1;   // the report arrives: never shown
    f = flipStatus(); assert(!f.confirmed && f.dropped && f.droppedFrames == 1);
    rec[2] = {2, 0, 1, 12.5}; lastFlipToken = 2;       // the next frame is shown; the count stays
    f = flipStatus(); assert(f.confirmed && !f.dropped && f.droppedFrames == 1);
    missingPresentedCount = 4;                         // queued frames reported dropped meanwhile
    f = flipStatus(); assert(f.confirmed && f.droppedFrames == 4);
    rec[2].token = 6;                                  // the record has been reused
    f = flipStatus(); assert(!f.confirmed && !f.dropped && !locked);
    closing = true; bool raised = false;
    try { flipStatus(); } catch (...) { raised = true; }
    assert(raised && !locked);
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 'test.cpp').write_text(source)
    subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', str(p / 'test.cpp'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
print('PASS: flipStatus: nothing reported, a drop reported after Flip returned, a shown frame, the session count, a reused record, a closed session.')
