#!/usr/bin/env python3
"""pm::waitUntil, against a simulated clock and scheduler: the thread is a
time-constraint thread while it sleeps and has its own policy back after; the
spin margin grows after a late wake-up and shrinks back after punctual ones, so
one late wake-up does not leave a long busy-spin on every later wait."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'PsychMetalEngine.mm').read_text()
start = source.index('struct PMRealtimeWait {')
function = source[start:source.index('\n}\n', start) + 3]
code = r'''
#include "PsychMetalRecordingClock.h"
static pm::recording::Clock recordingClock;
static bool exportSession=false;
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
using std::fmin; using std::fmax;
struct mach_timebase_info_data_t { uint32_t numer, denom; };
static void mach_timebase_info(mach_timebase_info_data_t *t) { t->numer = t->denom = 1; }
static double clock_now = 100, late = 0, asked = 0;    // seconds
typedef unsigned thread_port_t, thread_policy_flavor_t, mach_msg_type_number_t, boolean_t;
typedef int *thread_policy_t;
enum { KERN_SUCCESS = 0, THREAD_STANDARD_POLICY = 1, THREAD_TIME_CONSTRAINT_POLICY = 2 };
struct thread_time_constraint_policy_data_t { uint32_t period, computation, constraint; boolean_t preemptible; };
struct thread_standard_policy_data_t { unsigned no_data; };
#define THREAD_TIME_CONSTRAINT_POLICY_COUNT 4u
#define THREAD_STANDARD_POLICY_COUNT 0u
#include <pthread.h>
// The Mac's pthread.h declares the real one; the engine's call goes to this stand-in.
static thread_port_t stubMachThread(pthread_t) { return 7; }
#define pthread_mach_thread_np stubMachThread
static int policy = THREAD_STANDARD_POLICY, sleeps = 0;   // the thread's, as the scheduler holds it
static int thread_policy_get(thread_port_t, thread_policy_flavor_t, thread_policy_t, mach_msg_type_number_t *, boolean_t *standard) {
    *standard = policy == THREAD_STANDARD_POLICY; return KERN_SUCCESS;
}
static int thread_policy_set(thread_port_t, thread_policy_flavor_t f, thread_policy_t p, mach_msg_type_number_t) {
    if (f == THREAD_TIME_CONSTRAINT_POLICY) {
        auto *c = (thread_time_constraint_policy_data_t *)p;
        assert(c->period == 0 && c->computation > 0 && c->computation <= c->constraint && c->preemptible);
    }
    policy = (int)f; return KERN_SUCCESS;
}
static void mach_wait_until(uint64_t ticks) {
    assert(policy == THREAD_TIME_CONSTRAINT_POLICY);           // real-time while it sleeps
    ++sleeps; asked = ticks * 1e-9; clock_now = asked + late;
}
static double CACurrentMediaTime() { return clock_now += 1e-6; }   // the spin advances time
[[noreturn]] static void fail(const char *s) { throw std::runtime_error(s); }
namespace pm { double waitUntil(double); double now() noexcept { return CACurrentMediaTime(); } }
''' + function + r'''
static double margin() { double until = clock_now + 0.1; pm::waitUntil(until); return until - asked; }
int main() {
    late = 0.00001;
    assert(std::fabs(margin() - 0.0005) < 1e-6);           // starts at half a millisecond
    assert(sleeps == 1 && policy == THREAD_STANDARD_POLICY);  // and the thread has its own policy back
    late = 0.008; margin();                                  // one wake-up 8 ms late
    late = 0.00001;
    double grown = margin();
    assert(grown > 0.0159 && grown <= 0.020);                // the margin grew to cover it
    double m = grown;
    for (int i = 0; i < 100; i++) m = margin();
    assert(m < 0.00055 && m >= 0.0005);                      // and decays back to the floor
    late = 0.030; margin(); late = 0.00001;
    assert(margin() <= 0.020 + 1e-9);                        // never above 20 ms
    std::puts("PASS: waitUntil sleeps as a time-constraint thread, restores its policy, and its spin margin grows after a late wake-up and decays back to 0.5 ms.");
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    (p / 'wait.cpp').write_text(code)
    subprocess.run(['clang++', '-std=c++17', '-iquote',str(root), '-fsanitize=address,undefined', str(p / 'wait.cpp'), '-o', str(p / 'wait')], check=True)
    subprocess.run([str(p / 'wait')], check=True)
