"""Exercise the recorder's actual readiness loop with a failed/stalled writer.

Only Apple property syntax and the timeout duration are adapted for the fixture;
the decisions, cancellation check and failure propagation come from the engine.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'PsychMetalRecord.h').read_text()
start = source.index('static bool recordingInputReady(')
loop = source[start:source.index('\n}\n', start) + 3]
assert 'std::chrono::seconds(10)' in loop
loop = loop.replace('std::chrono::seconds(10)', 'std::chrono::milliseconds(20)')
loop = loop.replace('input.readyForMoreMediaData', 'input->readyForMoreMediaData')
preamble = r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
constexpr int AVAssetWriterStatusWriting = 1;
struct AVAssetWriterInput { std::atomic<bool> readyForMoreMediaData{false}; };
struct PMRecorder {
    AVAssetWriterInput *soundInput=nullptr;
    struct { std::atomic<int> status{AVAssetWriterStatusWriting}; } writer;
    std::mutex mutex;
    std::condition_variable changed;
    std::string failure;
};
'''
tests = r'''
int main() {
    AVAssetWriterInput input;
    { // A healthy ready writer proceeds without inventing an error.
        PMRecorder r; input.readyForMoreMediaData.store(true);
        assert(recordingInputReady(&r, &input) && r.failure.empty());
    }
    { // A failed writer cannot proceed even if its input claims readiness.
        PMRecorder r; r.writer.status.store(3);
        assert(!recordingInputReady(&r, &input) && !r.failure.empty());
    }
    { // A stalled writer terminates within a bounded interval.
        PMRecorder r; input.readyForMoreMediaData.store(false);
        auto started = std::chrono::steady_clock::now();
        assert(!recordingInputReady(&r, &input));
        auto elapsed = std::chrono::steady_clock::now() - started;
        assert(elapsed >= std::chrono::milliseconds(20));
        assert(elapsed < std::chrono::seconds(2));
        assert(r.failure.find("Timed out") != std::string::npos);
    }
    { // A failure from the other media thread ends the wait and stays intact.
        PMRecorder r;
        std::thread other([&] {
            std::lock_guard<std::mutex> held(r.mutex);
            r.failure = "sound failed";
        });
        other.join();
        assert(!recordingInputReady(&r, &input) && r.failure == "sound failed");
    }
    { // Normal temporary backpressure is allowed to recover.
        PMRecorder r;
        std::thread encoder([&] { input.readyForMoreMediaData.store(true); });
        assert(recordingInputReady(&r, &input));
        encoder.join();
        assert(r.failure.empty());
    }
}
'''
with tempfile.TemporaryDirectory(prefix='psychmetal-recording-writer-') as temp:
    p = Path(temp)
    (p / 'test.cpp').write_text(preamble + loop + tests)
    subprocess.run(['clang++', '-std=c++17', '-pthread', '-Wall', '-Wextra',
                    '-fsanitize=address,undefined', str(p / 'test.cpp'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=10)
print('PASS: recorder writer readiness handles stalls, failures, backpressure and preserves the first error.')
