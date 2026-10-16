"""Native recorder admission/completion under a delayed GPU and concurrent Stop."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'PsychMetalRecord.h').read_text()
def function(start):
    a = source.index(start)
    return source[a:source.index('\n}\n', a) + 3]

reserve = function('static bool reserveRecordingFrame(')
release = function('static void releaseRecordingFrame(')
preamble = r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
struct PMRecorder {
    std::mutex mutex;
    std::condition_variable changed;
    bool accepting = true;
    int pending = 0;
    std::string failure;
};
static void finishRecordingInput(PMRecorder *,bool) {}
'''
tests = r'''
int main() {
    auto session = std::make_shared<PMRecorder>();
    std::weak_ptr<PMRecorder> observed = session;
    std::atomic<bool> entered{false}, finish{false};
    std::thread gpu([owner = session, &entered, &finish] {
        assert(reserveRecordingFrame(owner.get()));
        entered.store(true);
        while (!finish.load()) std::this_thread::yield();
        releaseRecordingFrame(owner.get());
    });
    while (!entered.load()) std::this_thread::yield();
    auto stopping = std::atomic_exchange(&session, std::shared_ptr<PMRecorder>{});
    {
        std::unique_lock<std::mutex> held(stopping->mutex);
        stopping->accepting = false;
        stopping->changed.notify_all();
        assert(stopping->pending == 1);
        assert(!stopping->changed.wait_for(held, std::chrono::milliseconds(5),
                                          [&] { return stopping->pending == 0; }));
    }
    assert(!reserveRecordingFrame(stopping.get()));
    stopping.reset(); // Simulated timeout: GPU still owns the session, no leak/UAF.
    assert(!observed.expired());
    finish.store(true); gpu.join();
    assert(observed.expired());

    PMRecorder r;
    for (int i = 0; i < 6; ++i) assert(reserveRecordingFrame(&r));
    std::atomic<bool> waiting{false}, done{false};
    std::thread producer([&] {
        waiting.store(true);
        assert(!reserveRecordingFrame(&r));
        done.store(true);
    });
    while (!waiting.load()) std::this_thread::yield();
    { std::lock_guard<std::mutex> held(r.mutex); r.accepting = false; r.changed.notify_all(); }
    producer.join(); assert(done.load());
    for (int i = 0; i < 6; ++i) releaseRecordingFrame(&r);
    assert(r.pending == 0);

    // Concurrent producers reserve/release while Stop closes admission.
    for (int round = 0; round < 20; ++round) {
        PMRecorder r;
        std::vector<std::thread> workers;
        for (int i = 0; i < 8; ++i) workers.emplace_back([&] {
            while (reserveRecordingFrame(&r)) releaseRecordingFrame(&r);
        });
        { std::lock_guard<std::mutex> held(r.mutex); r.accepting = false; r.changed.notify_all(); }
        for (auto &worker : workers) worker.join();
        assert(r.pending == 0);
    }
}
'''
assert 'r.release()' not in source
assert 'owner.get(); // GPU and writer completions retain this session' in source
with tempfile.TemporaryDirectory(prefix='psychmetal-recording-lifetime-') as temp:
    p = Path(temp)
    (p / 'test.cpp').write_text(preamble + reserve + release + tests)
    for sanitizer in ('address,undefined', 'thread'):
        subprocess.run(['clang++', '-std=c++17', '-pthread', '-Wall', '-Wextra',
                        '-fsanitize=' + sanitizer, str(p / 'test.cpp'), '-o', str(p / 'test')], check=True)
        subprocess.run([str(p / 'test')], check=True, timeout=30)
print('PASS: native recording admission/Stop races, delayed-GPU ownership and timeout cleanup under ASan/UBSan/TSan.')
