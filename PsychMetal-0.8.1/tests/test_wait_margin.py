#!/usr/bin/env python3
"""pm::waitUntil's spin margin, against a simulated clock: it grows after a late
wake-up and shrinks back after punctual ones, so one late wake-up does not leave
a long busy-spin on every later wait."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'PsychMetalEngine.mm').read_text()
start = source.index('double pm::waitUntil(double untilTime) {')
function = source[start:source.index('\n}\n', start) + 3]
code = r'''
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
static void mach_wait_until(uint64_t ticks) { asked = ticks * 1e-9; clock_now = asked + late; }
static double CACurrentMediaTime() { return clock_now += 1e-6; }   // the spin advances time
[[noreturn]] static void fail(const char *s) { throw std::runtime_error(s); }
namespace pm { double waitUntil(double); }
''' + function + r'''
static double margin() { double until = clock_now + 0.1; pm::waitUntil(until); return until - asked; }
int main() {
    late = 0.0001;
    assert(std::fabs(margin() - 0.004) < 1e-6);            // starts at 4 ms
    late = 0.008; margin();                                  // one wake-up 8 ms late
    late = 0.0001;
    double grown = margin();
    assert(grown > 0.0159 && grown <= 0.020);                // the margin grew to cover it
    double m = grown;
    for (int i = 0; i < 40; i++) m = margin();
    assert(m < 0.0045 && m >= 0.004);                        // and decays back to the floor
    late = 0.030; margin(); late = 0.0001;
    assert(margin() <= 0.020 + 1e-9);                        // never above 20 ms
    std::puts("PASS: waitUntil spin margin grows after a late wake-up and decays back to 4 ms.");
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d)
    (p / 'wait.cpp').write_text(code)
    subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', str(p / 'wait.cpp'), '-o', str(p / 'wait')], check=True)
    subprocess.run([str(p / 'wait')], check=True)
