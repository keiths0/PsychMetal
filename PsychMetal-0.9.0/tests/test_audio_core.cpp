// Scheduled-sound core against simulated buffer timestamps: sample-exact starts
// and stops, buffer boundaries, late and immediate starts, repeats, mixing,
// clipping, capacity, and the rings under real threads (build with TSan too).
#include "PsychMetalAudio.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <functional>
#include <random>
#include <thread>
#include <cstdlib>
#include <chrono>
#include <vector>

using namespace pm::audio;

static const double kRate = 48000;

struct Device {
    Mixer mixer;
    uint32_t channels;
    double start, sps;
    uint64_t played = 0;                       // samples rendered so far
    std::vector<std::vector<float>> recording; // everything rendered, per channel
    explicit Device(uint32_t c = 2, double t0 = 100.0, double sps = kRate)
        : channels(c), start(t0), sps(sps), recording(c) {}
    double now() const { return sampleTime(start, (double)played, sps); }
    void render(uint32_t frames) {
        std::vector<std::vector<float>> buffers(channels, std::vector<float>(frames, 7.f));
        std::vector<float *> out(channels);
        for (uint32_t c = 0; c < channels; c++) out[c] = buffers[c].data();
        mixer.render(out.data(), channels, frames, now(), sps);
        for (uint32_t c = 0; c < channels; c++)
            recording[c].insert(recording[c].end(), buffers[c].begin(), buffers[c].end());
        played += frames;
    }
    std::vector<Event> events() {
        std::vector<Event> all;
        Event e;
        while (mixer.events.pop(e)) all.push_back(e);
        return all;
    }
    void play(uint64_t voice, const Sound &s, double when, float gain = 1, uint32_t repeats = 1) {
        Command c; c.kind = Command::Play; c.voice = voice; c.sound = &s; c.when = when; c.gain = gain; c.repeats = repeats;
        assert(mixer.commands.push(c));
    }
    void stop(uint64_t voice, double when, bool all = false) {
        Command c; c.kind = all ? Command::StopAll : Command::Stop; c.voice = voice; c.when = when;
        assert(mixer.commands.push(c));
    }
    void modulate(uint64_t voice, double when, double hz, double phase, float depth) {
        Command c; c.kind = Command::Modulate; c.voice = voice; c.when = when;
        c.modulation.hz = hz; c.modulation.phase = phase; c.modulation.depth = depth;
        assert(mixer.commands.push(c));
    }
    double at(uint64_t sample) const { return sampleTime(start, (double)sample, sps); }
};
// The modulation at GetSecs time t.
static double envelope(double t, double hz, double phase, double depth) {
    return 1 - depth * (1 - std::cos(2 * M_PI * hz * t + phase)) / 2;
}

static Sound make(std::vector<float> samples, uint32_t channels = 1) {
    Sound s;
    s.channels = channels;
    s.frames = samples.size() / channels;
    s.samples = std::move(samples);
    return s;
}
static Sound ramp(uint64_t n) {
    std::vector<float> v(n);
    for (uint64_t i = 0; i < n; i++) v[i] = float(i + 1) / 1024.f;
    return make(v);
}
static bool near(double a, double b) { return std::fabs(a - b) < 1e-9; }


// --- input ---------------------------------------------------------------------------------------
struct Input {
    Recorder rec;
    uint32_t channels;
    double start, sps;
    uint64_t seen = 0;
    std::function<float(uint64_t, uint32_t)> signal;   // the input's sample at an absolute index
    explicit Input(uint32_t c = 1, double t0 = 50.0, double sps = kRate) : channels(c), start(t0), sps(sps) {
        signal = [](uint64_t i, uint32_t) { return float(i) / 1e6f; };
    }
    double at(uint64_t sample) const { return sampleTime(start, (double)sample, sps); }
    void capture(uint32_t frames) {
        std::vector<std::vector<float>> buffers(channels, std::vector<float>(frames));
        std::vector<const float *> in(channels);
        for (uint32_t c = 0; c < channels; c++) {
            for (uint32_t i = 0; i < frames; i++) buffers[c][i] = signal(seen + i, c);
            in[c] = buffers[c].data();
        }
        rec.capture(in.data(), channels, frames, at(seen), sps);
        seen += frames;
    }
    void send(InputCommand::Kind kind, uint64_t id, double when, float threshold = 0, uint32_t window = 1, uint32_t minimum = 1) {
        InputCommand c; c.kind = kind; c.id = id; c.when = when; c.threshold = threshold; c.window = window; c.minimum = minimum;
        assert(rec.commands.push(c));
    }
    std::vector<InputEvent> events() {
        std::vector<InputEvent> all; InputEvent e;
        while (rec.events.pop(e)) all.push_back(e);
        return all;
    }
};

static void inputTests() {
    {   // A recording starts and stops on the exact samples, across buffers of changing size.
        Input in;
        in.rec.allocate(1, 1000);
        in.send(InputCommand::Record, 1, in.at(10));
        in.send(InputCommand::StopRecording, 1, in.at(110));
        in.capture(64); in.capture(17); in.capture(64);
        assert(in.rec.recorded.load() == 100);
        for (int i = 0; i < 100; i++) assert(in.rec.channel(0)[i] == float(10 + i) / 1e6f);
        auto e = in.events();
        assert(e.size() == 2 && e[0].kind == InputEvent::RecordStart && e[0].status == InputEvent::OnTime && near(e[0].time, in.at(10)));
        assert(e[1].kind == InputEvent::RecordEnd && e[1].status == InputEvent::Stopped && e[1].frames == 100 && near(e[1].time, in.at(110)));
    }
    {   // Memory full: it stops there and says so. Late: starts on the buffer's first sample.
        Input in;
        in.rec.allocate(1, 50);
        in.capture(64);
        in.send(InputCommand::Record, 2, in.at(3));
        in.capture(32); in.capture(32);
        auto e = in.events();
        assert(e[0].status == InputEvent::Late && near(e[0].time, in.at(64)));
        assert(e[1].status == InputEvent::Full && e[1].frames == 50 && near(e[1].time, in.at(114)));
        assert(in.rec.channel(0)[49] == float(113) / 1e6f);
    }
    {   // A stop before the start records nothing; one input channel fills both recorded channels.
        Input in;
        in.rec.allocate(2, 100);
        in.send(InputCommand::Record, 3, in.at(80));
        in.send(InputCommand::StopRecording, 3, in.at(40));
        in.capture(128);
        auto e = in.events();
        assert(e.size() == 1 && e[0].kind == InputEvent::RecordEnd && e[0].frames == 0);
        in.send(InputCommand::Record, 4, NAN);
        in.capture(8);
        assert(in.rec.channel(0)[3] == in.rec.channel(1)[3] && in.rec.channel(1)[3] == float(131) / 1e6f);
    }
    {   // Voice key: a single-sample click is ignored when 10 of 48 samples are required;
        // the burst that follows triggers at its first sample, even across a buffer boundary.
        Input in;
        in.signal = [](uint64_t i, uint32_t) { return (i == 500 || (i >= 1022 && i < 1200)) ? 0.8f : 0.01f; };
        in.send(InputCommand::ArmKey, 9, NAN, 0.5f, 48, 10);
        while (in.seen < 1280) in.capture(64);
        auto e = in.events();
        assert(e.size() == 1 && e[0].kind == InputEvent::Key && near(e[0].time, in.at(1022)));
        assert(e[0].level == 0.8f && e[0].frames == InputEvent::kNone);
    }
    {   // A trigger in the final input buffer still belongs to the recording,
        // whether it ended by StopRecording or by reaching its memory limit.
        for (bool full : {false, true}) {
            Input in;
            in.rec.allocate(1, full ? 40 : 100);
            in.signal = [](uint64_t i, uint32_t) { return i >= 30 ? .8f : 0.f; };
            in.send(InputCommand::Record, 1, in.at(10));
            if (!full) in.send(InputCommand::StopRecording, 1, in.at(50));
            in.send(InputCommand::ArmKey, 2, NAN, .5f);
            in.capture(64);
            auto e = in.events();
            assert(e.size() == 3 && e.back().kind == InputEvent::Key);
            assert(e.back().frames == 20 && near(e.back().time, in.at(30)));
            // A later trigger outside the saved prefix has no recording index.
            in.send(InputCommand::ArmKey, 3, NAN, .5f);
            in.capture(64);
            e = in.events();
            assert(e.size() == 1 && e[0].frames == InputEvent::kNone);
        }
    }
    {   // With minimum 1 the click itself triggers; a key armed later ignores what came before.
        Input in;
        in.signal = [](uint64_t i, uint32_t c) { return (c == 1 && (i == 500 || i == 900)) ? -0.9f : 0.f; };
        in.channels = 2;
        in.send(InputCommand::ArmKey, 1, NAN, 0.5f);
        while (in.seen < 640) in.capture(64);
        auto e = in.events();
        assert(e.size() == 1 && near(e[0].time, in.at(500)) && e[0].level == 0.9f);
        in.send(InputCommand::ArmKey, 2, in.at(700), 0.5f);
        while (in.seen < 1024) in.capture(64);
        e = in.events();
        assert(e.size() == 1 && e[0].id == 2 && near(e[0].time, in.at(900)));
    }
    {   // A key during a recording reports the frame of the recording that holds it.
        Input in;
        in.rec.allocate(1, 4096);
        in.signal = [](uint64_t i, uint32_t) { return i >= 700 ? 0.6f : 0.f; };
        in.send(InputCommand::Record, 1, in.at(200));
        in.send(InputCommand::ArmKey, 2, NAN, 0.5f);
        while (in.seen < 1024) in.capture(64);
        auto e = in.events();
        assert(e.size() == 2 && e[1].kind == InputEvent::Key && e[1].frames == 500);
        assert(in.rec.channel(0)[500] == 0.6f && in.rec.channel(0)[499] == 0.f);
    }
    puts("PASS: recordings start and stop on exact samples, fill and late cases, voice key windows, arming time, frame within a recording.");

    {   // A host thread reads a recording while the capture thread writes it.
        Recorder rec;
        rec.allocate(1, 48000);
        std::atomic<bool> done{false};
        std::thread capture([&] {
            float buffer[64];
            const float *in[1] = {buffer};
            for (uint64_t seen = 0; !done.load(); seen += 64) {
                for (int i = 0; i < 64; i++) buffer[i] = float((seen + i) % 1000);
                rec.capture(in, 1, 64, seen / kRate, kRate);
            }
        });
        InputCommand c; c.kind = InputCommand::Record; c.id = 1; c.when = NAN;
        assert(rec.commands.push(c));
        uint64_t checked = 0;
        InputEvent e;
        bool ended = false;
        while (!ended) {
            uint64_t n = rec.recorded.load(std::memory_order_acquire);
            for (; checked + 1 < n; checked++)
                assert(std::fmod(rec.channel(0)[checked + 1] - rec.channel(0)[checked] + 1000, 1000) == 1);
            while (rec.events.pop(e)) if (e.kind == InputEvent::RecordEnd) ended = true;
        }
        done = true;
        capture.join();
        assert(rec.recorded.load() == 48000 && rec.lostEvents.load() == 0);
    }
    puts("PASS: a recording is read safely while it is being written.");

    {   // The monitor holds the newest input whether or not a recording runs.
        Input in;
        float last[100];
        double end = 0;
        assert(in.rec.recent(last, 100, end) == 0);             // not enough yet
        in.capture(64); in.capture(64);
        assert(in.rec.recent(last, 100, end) == 128 && near(end, in.at(128)));
        for (int i = 0; i < 100; i++) assert(last[i] == float(28 + i) / 1e6f);
        assert(in.rec.recent(last, Recorder::kMonitor, end) == 0);   // more than may be asked for
    }
    {   // Reading the monitor while the capture thread writes it, as fast as it can:
        // every read is whole and ordered or refused, and reads still succeed.
        // The largest allowed read runs against a writer paced at about 60 times
        // a real device (64 frames each 1.3 ms); flat out, any writer can lap a
        // slow enough reader. A deadline, not a hang, if reads never succeed.
        Recorder rec;
        std::atomic<bool> done{false};
        std::atomic<int> pause{0};          // microseconds between buffers
        std::thread capture([&] {
            float buffer[64];
            const float *in[1] = {buffer};
            for (uint64_t seen = 0; !done.load(); seen += 64) {
                for (int i = 0; i < 64; i++) buffer[i] = float((seen + i) % 4096);
                rec.capture(in, 1, 64, seen / kRate, kRate);
                if (int us = pause.load()) std::this_thread::sleep_for(std::chrono::microseconds(us));
            }
        });
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
        for (size_t n : {size_t(1024), size_t(Recorder::kMonitor / 2)}) {
            pause = n > 1024 ? 20 : 0;
            std::vector<float> got(n);
            int whole = 0;
            while (whole < 200 && std::chrono::steady_clock::now() < deadline) {
                double endTime = 0;
                uint64_t end = rec.recent(got.data(), n, endTime);
                if (!end) continue;
                assert(near(endTime, end / kRate));
                for (size_t i = 0; i < n; i++) assert(got[i] == float((end - n + i) % 4096));
                whole++;
            }
            if (whole < 200) { fprintf(stderr, "FAIL: %d whole reads of %zu samples in 20 s\n", whole, n); abort(); }
        }
        done = true;
        capture.join();
    }
    puts("PASS: the input monitor gives the newest samples, safely, while they are written.");
}

int main() {
    inputTests();
    // Time and position are each other's inverse.
    assert(near(sampleTime(5, samplePosition(5.25, 5, kRate), kRate), 5.25));

    const Sound click = make({1.f});
    {   // Mid-buffer start, on the exact sample, on every channel; the buffer is overwritten.
        Device d;
        d.play(1, click, d.at(10));
        d.render(64);
        for (int c = 0; c < 2; c++)
            for (int i = 0; i < 64; i++) assert(d.recording[c][i] == (i == 10 ? 1.f : 0.f));
        auto e = d.events();
        assert(e.size() == 2 && e[0].kind == Event::Start && e[0].status == Event::OnTime && near(e[0].time, d.at(10)));
        assert(e[1].kind == Event::End && e[1].status == Event::Finished && near(e[1].time, d.at(11)));
    }
    {   // Due in a later buffer; a time between samples goes to the nearest one.
        Device d;
        d.play(1, click, d.at(70) + 0.4 / kRate);
        d.render(64);
        assert(d.events().empty());
        d.render(64);
        for (int i = 0; i < 128; i++) assert(d.recording[0][i] == (i == 70 ? 1.f : 0.f));
        d.play(2, click, d.now() + 0.6 / kRate);
        d.render(64);
        assert(d.recording[0][129] == 1.f && d.recording[0][128] == 0.f);
    }
    {   // Past its time: starts on the first sample, reported late with its real start.
        Device d;
        d.render(64);
        d.play(1, click, d.at(10));
        d.render(64);
        assert(d.recording[0][64] == 1.f);
        auto e = d.events();
        assert(e[0].status == Event::Late && near(e[0].time, d.at(64)) && near(e[0].requested, d.at(10)));
    }
    {   // At once (NaN): the next buffer's first sample, on time.
        Device d;
        d.play(1, click, NAN);
        d.render(32);
        assert(d.recording[0][0] == 1.f && d.events()[0].status == Event::OnTime);
    }
    {   // A sound across buffers, with buffers of changing size, sample for sample.
        Device d;
        Sound r = ramp(100);
        d.play(1, r, d.at(50));
        d.render(64); d.render(17); d.render(64); d.render(8);
        for (int i = 0; i < 153; i++) {
            float want = (i >= 50 && i < 150) ? float(i - 50 + 1) / 1024.f : 0.f;
            assert(d.recording[0][i] == want);
        }
        auto e = d.events();
        assert(e.size() == 2 && near(e[1].time, d.at(150)) && e[1].status == Event::Finished);
    }
    {   // Repeats are seamless; the end comes after the last repeat.
        Device d;
        Sound r = ramp(10);
        d.play(1, r, d.at(5), 1, 3);
        d.render(64);
        for (int i = 0; i < 64; i++) {
            float want = (i >= 5 && i < 35) ? float((i - 5) % 10 + 1) / 1024.f : 0.f;
            assert(d.recording[0][i] == want);
        }
        assert(near(d.events()[1].time, d.at(35)));
    }
    {   // Until stopped, then stopped on the exact sample of a later buffer.
        Device d;
        Sound r = ramp(10);
        d.play(1, r, d.at(0), 1, 0);
        d.render(64);
        d.stop(1, d.at(100));
        d.render(64);
        for (int i = 0; i < 128; i++) assert((d.recording[0][i] != 0.f) == (i < 100));
        auto e = d.events();
        assert(e.size() == 2 && e[1].status == Event::Stopped && near(e[1].time, d.at(100)));
        d.render(64);
        assert(d.events().empty());
    }
    {   // A stop due before the start: never heard, no start event.
        Device d;
        d.play(1, click, d.at(200));
        d.stop(1, d.at(150));
        d.render(64); d.render(64);
        for (float v : d.recording[0]) assert(v == 0.f);
        auto e = d.events();
        assert(e.size() == 1 && e[0].kind == Event::End && e[0].status == Event::Stopped && near(e[0].time, d.at(150)));
    }
    {   // Stop everything at once.
        Device d;
        Sound r = ramp(1000);
        d.play(1, r, NAN); d.play(2, r, NAN);
        d.render(16);
        d.stop(0, NAN, true);
        d.render(16);
        for (int i = 16; i < 32; i++) assert(d.recording[0][i] == 0.f);
        auto e = d.events();
        assert(e.size() == 4 && e[2].status == Event::Stopped && e[3].status == Event::Stopped && near(e[3].time, d.at(16)));
    }
    {   // Voices sum with their gains; beyond +-1 is clipped and counted.
        Device d;
        Sound loud = make({0.75f, 0.75f, -0.75f});
        d.play(1, loud, d.at(0), 1);
        d.play(2, loud, d.at(0), 0.5f);
        d.play(3, loud, d.at(1), 1);
        d.render(8);
        // sample 0: 0.75 + 0.375 = 1.125; 1: 0.75 + 0.375 + 0.75; 2: -0.75 - 0.375 + 0.75; 3: -0.75
        assert(d.recording[0][0] == 1.f && d.recording[0][1] == 1.f);
        assert(d.recording[0][2] == -0.375f && d.recording[0][3] == -0.75f && d.recording[1][3] == -0.75f);
        assert(d.mixer.clippedSamples.load() == 4);              // two samples on each of two channels
    }
    {   // Stereo sounds keep their channels; mono plays on both.
        Device d;
        Sound stereo = make({0.25f, 0.5f}, 2);                   // planar: left 0.25, right 0.5
        d.play(1, stereo, d.at(3));
        d.play(2, click, d.at(5), 0.5f);
        d.render(8);
        assert(d.recording[0][3] == 0.25f && d.recording[1][3] == 0.5f);
        assert(d.recording[0][5] == 0.5f && d.recording[1][5] == 0.5f);
    }
    {   // More voices than slots: the extra one is refused, never played.
        Device d;
        for (uint64_t v = 1; v <= Mixer::kVoices + 1; v++) d.play(v, click, d.at(1000));
        d.render(8);
        auto e = d.events();
        assert(e.size() == 1 && e[0].status == Event::Refused && e[0].voice == Mixer::kVoices + 1);
    }
    {   // A device clock that runs slightly fast or slow, and random buffer sizes:
        // every click lands on the sample nearest its time, over a long run.
        std::mt19937 rng(7);
        for (double sps : {kRate * (1 + 37e-6), kRate * (1 - 52e-6)}) {
            Device d(1, 5000.0, sps);
            std::vector<uint64_t> want;
            for (int k = 0; k < 250; k++) {   // all pending at once: fewer than the 256 voices
                double t = d.at(0) + 0.01 + k * 0.0123457 + (rng() % 1000) * 1e-9;
                d.play(k + 1, click, t);
                want.push_back((uint64_t)std::llround(samplePosition(t, d.start, sps)));
            }
            while (d.played < want.back() + 64) d.render(1 + rng() % 512);
            uint64_t found = 0;
            for (uint64_t i = 0; i < d.played; i++)
                if (d.recording[0][i] != 0.f) { assert(found < want.size() && i == want[found]); found++; }
            assert(found == want.size());
        }
    }
    {   // Modulation from the first sample, on GetSecs time, through repeats and buffers of
        // any size, at a large clock value; a timed change mid-buffer, exact from its sample.
        std::mt19937 rng(7);
        for (double t0 : {100.0, 1.0e6}) {
            Device d(2, t0);
            Sound flat = make(std::vector<float>(480, 0.5f));
            d.play(1, flat, d.at(200), 1.f, 0);
            d.modulate(1, NAN, 10, 0.3, 1);                  // before the voice starts: from its first sample
            uint64_t change = 30011;
            d.modulate(1, d.at(5000), 99, 0, 1);             // replaced before it is due
            d.modulate(1, d.at(change) + 0.3 / kRate, 3.5, -1, 0.5f);
            while (d.played < 60000) d.render(1 + rng() % 700);
            for (uint64_t i = 0; i < 60000; i++) {
                double want = i < 200 ? 0 : 0.5 * (i < change ? envelope(d.at(i), 10, 0.3, 1)
                                                              : envelope(d.at(i), 3.5, -1, 0.5));
                for (int c = 0; c < 2; c++)
                    if (!(std::fabs(d.recording[c][i] - want) < 2e-6)) {
                        fprintf(stderr, "t0 %g sample %llu channel %d: %.9f, want %.9f\n", t0, (unsigned long long)i, c, d.recording[c][i], want);
                        abort();
                    }
            }
        }
    }
    {   // Depth 0 ends modulation exactly; gain still applies; a stereo sound keeps its channels;
        // a voice that does not exist is ignored.
        Device d;
        Sound two = make({0.25f, 0.5f, 0.25f, 0.5f}, 2);     // channel 0: 0.25 0.5; channel 1: 0.25 0.5
        d.play(1, two, NAN, 2.f, 0);
        d.modulate(1, NAN, 40, 1, 1);
        d.modulate(77, NAN, 40, 1, 1);
        d.render(64);
        d.modulate(1, d.at(100), 0, 0, 0);
        d.render(64);
        for (uint64_t i = 0; i < 128; i++) {
            double m = i < 100 ? envelope(d.at(i), 40, 1, 1) : 1;
            for (int c = 0; c < 2; c++) {
                double src = i % 2 ? 0.5 : 0.25;
                assert(std::fabs(d.recording[c][i] - 2 * src * m) < 2e-6);
            }
        }
        for (uint64_t i = 100; i < 128; i++) assert(d.recording[0][i] == (i % 2 ? 1.f : 0.5f));
    }
    puts("PASS: modulation on GetSecs time from a voice's first sample, timed changes on the exact sample, replacement, depth 0, gain, channels.");
    puts("PASS: sample-exact starts and stops across buffers, late and immediate starts, repeats, mixing, clipping, capacity, clock-rate drift.");
    {   // A gap between callbacks: contiguous buffers (even a little early or late) set
        // nothing; one that starts more than 50 ms after the last ended does.
        Mixer m;
        float l[64], r[64];
        float *out[2] = {l, r};
        double onset = 100;
        for (int i = 0; i < 50; i++, onset += 64 / kRate + (i % 2 ? 1e-4 : -1e-4)) m.render(out, 2, 64, onset, kRate);
        assert(!m.gap.load());
        m.render(out, 2, 64, onset + 0.049, kRate);
        assert(!m.gap.load());
        m.render(out, 2, 64, onset + 0.049 + 64 / kRate + 0.051, kRate);
        assert(m.gap.exchange(false) && !m.gap.load());
        puts("PASS: a stop in the output is found from the gap between callbacks; contiguous buffers report none.");
    }

    {   // Real threads: a host thread schedules and collects; the audio thread renders.
        Mixer mixer;
        const int n = 3000;
        std::atomic<bool> done{false};
        std::thread audio([&] {
            float left[64], right[64];
            float *out[2] = {left, right};
            for (uint64_t played = 0; !done.load(); played += 64)
                mixer.render(out, 2, 64, played / kRate, kRate);
        });
        int starts = 0, ends = 0, retired = 0;
        std::vector<int> seen(n + 1, 0), gone(n + 1, 0);
        auto drain = [&] {                         // as the host does: retirements, then events
            uint64_t id;
            while (mixer.retired.pop(id)) { retired++; gone[id]++; }
            Event e;
            while (mixer.events.pop(e)) { (e.kind == Event::Start ? starts : ends)++; seen[e.voice]++; }
        };
        for (int k = 1; k <= n; ) {
            Command c; c.kind = Command::Play; c.voice = k; c.sound = &click; c.when = NAN;
            if (k - ends < 200 && mixer.commands.push(c)) k++;   // fewer in flight than voices
            drain();
        }
        while (ends < n || retired < n) drain();
        done = true;
        audio.join();
        assert(mixer.lostEvents.load() == 0);
        assert(starts == n && ends == n && retired == n);
        for (int k = 1; k <= n; k++) assert(seen[k] == 2 && gone[k] == 1);
    }
    puts("PASS: command, event and retirement rings between a host thread and an audio thread lose nothing.");
}
