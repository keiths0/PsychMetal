"""queueResults, extracted from the engine: a frame is forgotten only once its
outcome has been reported. A wait that times out reports the frame as pending
and keeps it, so the next call can say what became of it."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'PsychMetalEngine.mm').read_text()
a = s.index('static std::vector<pm::QueuedFrame> queueResults(bool wait) {'); b = s.index('\n}\n', a) + 3
body = s[a:b].replace('pm::QueuedFrame', 'QueuedFrame')
source = r'''
#include <cassert>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>
struct Record { uint64_t token; int status, done; double requestedTime, presented; };
struct QueuedFrame { uint64_t token; double requested, presented; int status; };
using std::isfinite;
#define PM_QUEUE_LOST 10.0
static Record rec[8];
static int device = 1, lock = 0;
static bool closing = false, locked = false;
static double now = 100;
static std::vector<uint64_t> queuedTokens;
[[noreturn]] static void fail(const char *m) { throw std::runtime_error(m); }
static void pthread_mutex_lock(int *) { assert(!locked); locked = true; }
static void pthread_mutex_unlock(int *) { assert(locked); locked = false; }
static double CACurrentMediaTime() { return now; }
static Record *recordFor(uint64_t t) { Record *r = &rec[t % 8]; return r->token == t ? r : nullptr; }
// No callback ever arrives while waiting: the wait runs to its deadline.
static int waitRelative(double deadline) { assert(locked); now = deadline; return ETIMEDOUT; }
''' + body + r'''
int main() {
    rec[1] = {1, 0, 1, 100.1, 100.1};      // shown
    rec[2] = {2, 2, 0, 100.2, 0};          // handed to the display; no report yet
    rec[3] = {3, 2, 0, 100.3, 0};
    queuedTokens = {1, 2, 3};
    auto out = queueResults(false);        // without waiting: only what is finished
    assert(out.size() == 1 && out[0].token == 1 && out[0].status == 0 && out[0].presented == 100.1);
    assert(queuedTokens == std::vector<uint64_t>({2, 3}) && !locked);
    out = queueResults(true);              // the wait times out, two seconds past the last frame's time
    assert(now == 102.3 && out.size() == 2 && out[0].token == 2 && out[0].status == 2 && std::isnan(out[0].presented));
    assert(queuedTokens == std::vector<uint64_t>({2, 3}) && !locked);     // still owed their outcomes
    rec[2].status = 0; rec[2].done = 1; rec[2].presented = 102.4;         // the reports arrive late
    rec[3].status = 1; rec[3].done = 1;
    out = queueResults(true);
    assert(out.size() == 2 && out[0].token == 2 && out[0].status == 0 && out[0].presented == 102.4);
    assert(out[1].token == 3 && out[1].status == 1 && std::isnan(out[1].presented));
    assert(queuedTokens.empty() && !locked);
    assert(queueResults(true).empty() && queueResults(false).empty());    // each outcome is reported once
    rec[4] = {4, 2, 0, 103.0, 0}; queuedTokens = {4}; rec[4].token = 12;  // a record reused: nothing to report
    assert(queueResults(false).empty() && queuedTokens.empty());
    // A frame the display never reports on is given up on ten seconds after its time,
    // so that it cannot make every later wait run to its deadline.
    rec[5] = {5, 2, 0, 200.0, 0}; queuedTokens = {5}; now = 200.5;
    out = queueResults(true);
    assert(now == 202.5 && out.size() == 1 && out[0].status == 2 && queuedTokens.size() == 1);
    now = 209.9; assert(queueResults(false).empty() && queuedTokens.size() == 1);
    now = 210.0; out = queueResults(false);
    assert(out.size() == 1 && out[0].token == 5 && out[0].status == 2 && queuedTokens.empty());
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 'test.cpp').write_text(source)
    subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', str(p / 'test.cpp'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
print('PASS: queueResults: finished frames reported once; a timed-out wait reports pending frames and keeps them; late outcomes delivered; a frame never reported on is given up on.')
