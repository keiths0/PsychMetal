"""A GPU failure in a command buffer that renders without presenting (a queued
frame's store, an offscreen window's draws or first contents) is reported.
renderFinished, storeState and abandonFrameLocked are the engine's own, extracted
and run; that the presenter thread acts on storeState before it takes a frame is
checked in its source, since that thread cannot run without Metal."""
from pathlib import Path
import re, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'PsychMetalEngine.mm').read_text()
a = s.index('static void renderFinished('); b = s.index('\n}\n', a) + 3
c = s.index('enum { PM_STORE_RENDERING'); d = s.index('\n}\n', c) + 3
e = s.index('static void abandonFrameLocked('); f = s.index('\n}\n', e) + 3
source = r'''
#include <cassert>
#include <cstdint>
#include <vector>
struct Record { uint64_t token; int status, done, renderDone, gpuDone; };
struct PMQueuedFrame { uint64_t token; double when; int store; };
static std::vector<int> frameStores;
static Record rec[4];
static int lock = 0, cond = 0, broadcasts = 0;
static bool locked = false, asynchronousGpuFailure = false;
static uint64_t sessionEpoch = 7;
static void pthread_mutex_lock(int *) { assert(!locked); locked = true; }
static void pthread_mutex_unlock(int *) { assert(locked); locked = false; }
static void pthread_cond_broadcast(int *) { assert(locked); broadcasts++; }
static Record *recordFor(uint64_t t) { Record *r = &rec[t % 4]; return r->token == t ? r : nullptr; }
''' + s[a:b] + s[c:d] + s[e:f] + r'''
int main() {
    rec[1] = {1, 2, 0, 0};
    renderFinished(7, 1, false);                    // a queued frame's store rendered
    assert(rec[1].renderDone == 1 && rec[1].status == 2 && !asynchronousGpuFailure && broadcasts == 1 && !locked);
    rec[2] = {2, 2, 0, 0};
    renderFinished(6, 2, true);                     // a failure from a session since closed: ignored
    assert(rec[2].renderDone == 0 && rec[2].status == 2 && !asynchronousGpuFailure);
    renderFinished(7, 2, true);                     // the GPU failed to render this frame's store
    assert(rec[2].renderDone == 1 && rec[2].status == 3 && asynchronousGpuFailure && !locked);
    asynchronousGpuFailure = false;
    renderFinished(7, 0, false);                    // an offscreen window's draws rendered
    assert(!asynchronousGpuFailure);
    renderFinished(7, 0, true);                     // and failed: the session has failed
    assert(asynchronousGpuFailure && rec[1].status == 2 && !locked);
    rec[3] = {3, 0, 1, 0, 0};
    renderFinished(7, 3, true);                     // a late failure overrides what the display reported
    assert(rec[3].status == 3 && rec[3].done == 1);
    // What the presenter does with the frame at the head of the queue.
    Record r = {5, 2, 0, 0, 0};
    assert(storeState(&r) == PM_STORE_RENDERING);   // queued, its store not yet rendered: wait
    r.renderDone = 1; assert(storeState(&r) == PM_STORE_READY);
    r.status = 3; assert(storeState(&r) == PM_STORE_FAILED);
    r.renderDone = 0; assert(storeState(&r) == PM_STORE_FAILED);
    assert(storeState(nullptr) == PM_STORE_READY);
    // A frame that is abandoned is done and its store idle; a GPU failure is not hidden by a cancellation.
    rec[1] = {1, 2, 0, 1, 0}; abandonFrameLocked({1, 0.0, 11}, 5);
    assert(rec[1].status == 5 && rec[1].done == 1 && frameStores == std::vector<int>({11}));
    rec[2] = {2, 3, 0, 1, 0}; abandonFrameLocked({2, 0.0, 12}, 5);
    assert(rec[2].status == 3 && rec[2].done == 1 && frameStores.size() == 2);
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 'test.cpp').write_text(source)
    subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', str(p / 'test.cpp'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

# Every command buffer the engine commits reports its status: the presented ones
# through attachHandlers, the others through watchRender. (The one exception
# commits a buffer whose frame has already failed, to run its handlers.)
commits = len(re.findall(r'\[cb commit\];', s))
watched = len(re.findall(r'watchRender\(cb, \w+\);\s*\[cb commit\];', s))
attached = len(re.findall(r'attachHandlers\(cb, ', s))
assert watched == 3 and attached == 3 and commits + len(re.findall(r'commitPresentation\(cb,', s)) == watched + attached + 1, (commits, watched, attached)
# The presenter acts on storeState before it takes a frame from the queue: it waits
# while the store is being rendered and abandons the frame if that failed. The
# display's report on a frame never clears a GPU error.
presenter = s[s.index('static void *presenterMain'):s.index('static pm::QueueResult queueFrame')]
decide, take = presenter.index('storeState(recordFor(frameQueue.front().token))'), presenter.index('frameQueue.pop_front();')
assert decide < presenter.index('if (store == PM_STORE_RENDERING) {') < take
assert re.search(r'if \(store == PM_STORE_RENDERING\) \{\s*pthread_cond_wait\(&cond, &lock\);[^}]*continue;', presenter)
assert re.search(r'if \(store == PM_STORE_FAILED\) \{\s*abandonFrameLocked\(f, 3\);[^}]*continue;', presenter)
assert 'if(q->status!=3) q->status = (pt > 0) ? 0 : 1;' in s
print('PASS: a failed render-only command buffer fails the session and its frame; the presenter waits for a store and does not '
      'show one that failed; a cancellation does not hide the failure; every committed buffer is watched.')
