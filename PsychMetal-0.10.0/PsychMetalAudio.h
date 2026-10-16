// PsychMetal scheduled sound: the host-independent core. Plain C++17, no Apple
// headers, so it is tested on any machine with simulated buffer timestamps.
// SPDX-License-Identifier: MIT
//
// The audio callback calls Mixer::render once per output buffer. It takes no
// lock, allocates nothing and frees nothing: commands arrive, and events leave,
// through fixed single-producer/single-consumer rings, and a sound is released
// by the host only after the voice playing it has reported its end.
//
// Time is GetSecs time throughout. render is told when the buffer's first
// sample leaves the device (`onset`, which includes the device's latency) and
// how many samples the device plays per second of that clock. Sample i of the
// buffer then plays at onset + i / samplesPerSecond; a sound due at time t
// starts on the sample nearest to it. The conversion runs either way, so a
// capture callback could stamp its input with the same functions.
//
// A voice can be amplitude-modulated: its samples are multiplied by
//     m(t) = 1 - depth * (1 - cos(2 pi hz t + phase)) / 2,
// t the GetSecs time of each sample, so m runs from 1 down to 1 - depth. A
// change of modulation takes effect on the sample nearest its time, mid-buffer
// if need be, and the cosine is computed per sample from that sample's time:
// the phase is exact at any change and never drifts.
#ifndef PSYCHMETAL_AUDIO_H
#define PSYCHMETAL_AUDIO_H

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <thread>
#include <vector>

namespace pm { namespace audio {

// Where time t falls in a buffer whose first sample is at `onset`, in samples.
inline double samplePosition(double t, double onset, double samplesPerSecond) {
    return (t - onset) * samplesPerSecond;
}
// The time of sample `index` of that buffer.
inline double sampleTime(double onset, double index, double samplesPerSecond) {
    return onset + index / samplesPerSecond;
}

// A fixed ring for one producer thread and one consumer thread.
template <class T, size_t N>
class Ring {
    static_assert(N >= 2 && (N & (N - 1)) == 0, "Ring capacity must be a power of two.");
    std::array<T, N> slots_{};
    alignas(64) std::atomic<size_t> head_{0};   // next write; producer only
    alignas(64) std::atomic<size_t> tail_{0};   // next read; consumer only
public:
    bool push(const T &value) noexcept {
        size_t h = head_.load(std::memory_order_relaxed);
        if (h - tail_.load(std::memory_order_acquire) == N) return false;
        slots_[h & (N - 1)] = value;
        head_.store(h + 1, std::memory_order_release);
        return true;
    }
    bool pop(T &value) noexcept {
        size_t t = tail_.load(std::memory_order_relaxed);
        if (t == head_.load(std::memory_order_acquire)) return false;
        value = slots_[t & (N - 1)];
        tail_.store(t + 1, std::memory_order_release);
        return true;
    }
};

// A preloaded sound: planar float samples at the device's rate. One channel
// plays on every output channel; otherwise channels match the output.
struct Sound {
    std::vector<float> samples;   // channel c, frame i at samples[c * frames + i]
    uint32_t channels = 0;
    uint64_t frames = 0;
};

// A voice's modulation; depth 0 is none.
struct Modulation {
    double hz = 0, phase = 0;
    float depth = 0;
};

struct Command {
    enum Kind : uint8_t { Play, Stop, StopAll, Modulate } kind = Play;
    uint64_t generation = 0;      // interruption epoch when the host issued Play
    uint64_t voice = 0;           // Play: the new voice's id; Stop, Modulate: the voice
    const Sound *sound = nullptr; // Play: kept alive by the host until the voice ends
    double when = NAN;            // GetSecs time; NaN: at once
    float gain = 1;
    uint32_t repeats = 1;         // 0: until stopped
    Modulation modulation;        // Modulate: from `when` on; a timed change replaces a timed one not yet due
};

struct Event {
    enum Kind : uint8_t { Start, End } kind = Start;
    enum Status : uint8_t {
        OnTime,     // Start: within half a sample of the requested time, or at once as asked
        Late,       // Start: its time had passed; it started on the buffer's first sample
        Finished,   // End: played to the end
        Stopped,    // End: stopped, before or while playing
        Interrupted, // End: an interruption invalidated this voice
        Refused,    // End: no free voice; never played
    } status = OnTime;
    uint64_t voice = 0;
    double requested = NAN;       // the time asked for (NaN: at once)
    double time = NAN;            // Start: its first sample; End: just after its last
};

// A copy of what the mixer played, for a movie's sound track: the first two
// channels (one channel copied to both), interleaved, in blocks with the time
// their first sample is heard. The audio callback fills it; one other thread
// empties it. A block that does not fit is counted, never waited for.
struct TapBlock {
    static constexpr uint32_t kFrames = 1024;
    double onset = 0, rate = 0;
    uint32_t frames = 0;
    float samples[2 * kFrames];
};
class Tap {
public:
    Ring<TapBlock, 256> blocks;
    std::atomic<uint64_t> lostFrames{0};
    void capture(const float *const *out, uint32_t channels, uint32_t frames, double onset, double rate) noexcept {
        if (!channels) return;
        for (uint32_t at = 0; at < frames; at += TapBlock::kFrames) {
            const uint32_t n = frames - at < TapBlock::kFrames ? frames - at : TapBlock::kFrames;
            block_.onset = onset + at / rate;
            block_.rate = rate;
            block_.frames = n;
            const float *left = out[0] + at, *right = (channels > 1 ? out[1] : out[0]) + at;
            for (uint32_t i = 0; i < n; i++) { block_.samples[2 * i] = left[i]; block_.samples[2 * i + 1] = right[i]; }
            if (!blocks.push(block_)) lostFrames.fetch_add(n, std::memory_order_relaxed);
        }
    }
private:
    TapBlock block_;    // the callback's own: no large copy on its stack
};

// Recorder-thread backlog, not an audio-callback object. Before the first
// video frame, keep only recent sound: waiting for a first Flip must not grow
// memory forever. Discarded samples after the video's origin count as lost.
class TapBacklog {
public:
    static constexpr size_t kBlocks = 256;
    uint64_t push(const TapBlock &block, double first) {
        uint64_t lost = 0;
        if (blocks_.size() == kBlocks) {
            const TapBlock &old = blocks_.front();
            if (std::isfinite(first) && old.rate > 0) {
                const double skipped = std::clamp(std::round((first - old.onset) * old.rate),
                                                 0.0, (double)old.frames);
                lost = old.frames - (uint64_t)skipped;
            }
            blocks_.pop_front();
        }
        blocks_.push_back(block);
        return lost;
    }
    bool empty() const { return blocks_.empty(); }
    size_t size() const { return blocks_.size(); }
    const TapBlock &front() const { return blocks_.front(); }
    void pop_front() { blocks_.pop_front(); }
private:
    std::deque<TapBlock> blocks_;
};

// Host detaches before deleting a tap. The callback announces its read before
// loading the pointer; sequential consistency ensures detach cannot miss a
// reader that obtained the old pointer. Only the host waits, never the callback.
class TapConnection {
public:
    void attach(Tap *tap) noexcept { value_.store(tap); }
    void detach(Tap *tap) noexcept {
        Tap *expected = tap;
        if (!value_.compare_exchange_strong(expected, nullptr)) return;
        while (readers_.load() != 0) std::this_thread::yield();
    }
    template<class F> void withTap(F &&f) noexcept {
        readers_.fetch_add(1);
        if (Tap *tap = value_.load()) f(*tap);
        readers_.fetch_sub(1);
    }
private:
    static_assert(std::atomic<Tap *>::is_always_lock_free &&
                  std::atomic<unsigned>::is_always_lock_free, "Audio tap requires lock-free atomics");
    std::atomic<Tap *> value_{nullptr};
    std::atomic<unsigned> readers_{0};
};

class Mixer {
public:
    // While a movie is recorded: what is played is also copied here.
    TapConnection tap;
    std::atomic<uint64_t> interruptionGeneration{0};
    void interrupt(double when) noexcept {
        interruptedAt_.store(when);
        interruptionGeneration.fetch_add(1);
    }
    void resumed() noexcept { restarted_.store(true); }
    static constexpr size_t kVoices = 256;
    static constexpr size_t kRing = 1024;

    // Every voice that ends, however it ends, is also reported here, apart from
    // the events: the host releases a voice's sound on this, so losing events to a
    // full ring never keeps a sound alive. The host keeps at most kRetired voices
    // outstanding, so this ring cannot fill.
    static constexpr size_t kRetired = 2048;

    Ring<Command, kRing> commands;   // host -> callback
    Ring<Event, kRing> events;       // callback -> host
    Ring<uint64_t, kRetired> retired;  // callback -> host: ids of voices that ended
    std::atomic<uint64_t> clippedSamples{0};
    std::atomic<uint64_t> lostEvents{0};
    // Set when a callback's onset is later than the previous one's end by more
    // than kGap: the output stopped for a while (an interruption the system did
    // not report, a stalled device). The host takes and clears it.
    std::atomic<bool> gap{false};
    static constexpr double kGap = 0.050;

    // The audio callback. out[c] receives `frames` samples for channel c.
    void render(float *const *out, uint32_t channels, uint32_t frames,
                double onset, double samplesPerSecond) noexcept {
        if (restarted_.exchange(false)) expectedOnset_ = NAN;
        if (onset - expectedOnset_ > kGap) {
            gap.store(true, std::memory_order_relaxed);
            interrupt(expectedOnset_);
        }
        syncInterruption();
        expectedOnset_ = onset + frames / samplesPerSecond;
        Command c;
        // Bound work even when the host keeps replenishing the queue.
        for (size_t i = 0; i < kRing && commands.pop(c); ++i) apply(c);
        for (uint32_t ch = 0; ch < channels; ch++)
            for (uint32_t i = 0; i < frames; i++) out[ch][i] = 0;
        for (Voice &v : voices_)
            if (v.sound) mix(v, out, channels, frames, onset, samplesPerSecond);
        uint64_t clipped = 0;
        for (uint32_t ch = 0; ch < channels; ch++)
            for (uint32_t i = 0; i < frames; i++) {
                float &s = out[ch][i];
                if (s > 1) { s = 1; clipped++; }
                else if (s < -1) { s = -1; clipped++; }
            }
        if (clipped) clippedSamples.fetch_add(clipped, std::memory_order_relaxed);
        tap.withTap([&](Tap &t) { t.capture(out, channels, frames, onset, samplesPerSecond); });
    }

private:
    struct Voice {
        const Sound *sound = nullptr;   // null: free
        uint64_t id = 0;
        double when = NAN, stopAt = NAN;
        float gain = 1;
        uint32_t repeats = 1;
        bool started = false, stopping = false;
        uint64_t position = 0;          // samples played, across repeats
        Modulation modulation;          // in effect
        Modulation next;                // due at nextAt, when changing
        double nextAt = NAN;
        bool changing = false;
    };
    std::array<Voice, kVoices> voices_{};
    std::atomic<bool> restarted_{false};
    std::atomic<double> interruptedAt_{NAN};
    uint64_t interruptionSeen_ = 0;
    void syncInterruption() noexcept {
        const uint64_t generation = interruptionGeneration.load();
        if (generation == interruptionSeen_) return;
        const double at = interruptedAt_.load();
        for (Voice &v : voices_) if (v.sound) end(v, Event::Interrupted, at);
        interruptionSeen_ = generation;
    }
    double expectedOnset_ = NAN;   // where the next callback should start

    void emit(const Event &e) noexcept {
        if (!events.push(e)) lostEvents.fetch_add(1, std::memory_order_relaxed);
    }
    // The event first, then the retirement: a host that sees a voice retired has
    // its End event in the ring already, unless the ring was full.
    void retire(uint64_t voice) noexcept {
        if (!retired.push(voice)) lostEvents.fetch_add(1, std::memory_order_relaxed);
    }
    void end(Voice &v, Event::Status status, double time) noexcept {
        emit(Event{Event::End, status, v.id, v.when, time});
        retire(v.id);
        v = Voice{};
    }
    void apply(const Command &c) noexcept {
        if (c.kind == Command::Play) {
            syncInterruption();
            if (c.generation != interruptionSeen_) {
                emit(Event{Event::End, Event::Interrupted, c.voice, c.when, interruptedAt_.load()});
                retire(c.voice);
                return;
            }
            for (Voice &v : voices_)
                if (!v.sound) {
                    v = Voice{};
                    v.sound = c.sound;
                    v.id = c.voice;
                    v.when = c.when;
                    v.gain = c.gain;
                    v.repeats = c.repeats;
                    return;
                }
            emit(Event{Event::End, Event::Refused, c.voice, c.when, NAN});
            retire(c.voice);
            return;
        }
        if (c.kind == Command::Modulate) {
            for (Voice &v : voices_)
                if (v.sound && v.id == c.voice) {
                    if (std::isnan(c.when)) {        // at once: from this buffer, or the voice's first sample
                        v.modulation = c.modulation;
                    } else {                         // timed: replaces a timed change not yet due
                        v.next = c.modulation;
                        v.nextAt = c.when;
                        v.changing = true;
                    }
                }
            return;
        }
        for (Voice &v : voices_)
            if (v.sound && (c.kind == Command::StopAll || v.id == c.voice)) {
                v.stopping = true;
                v.stopAt = c.when;
            }
    }
    // Where a time falls in this buffer, as a whole sample: NaN means "now" (0).
    static int64_t sampleAt(double t, double onset, double sps) noexcept {
        if (std::isnan(t)) return 0;
        double x = samplePosition(t, onset, sps);
        if (x > 9.0e18) return INT64_MAX;
        if (x < -9.0e18) return INT64_MIN;
        return (int64_t)std::llround(x);
    }

    void mix(Voice &v, float *const *out, uint32_t channels, uint32_t frames,
             double onset, double sps) noexcept {
        int64_t first = 0;
        if (!v.started) {
            int64_t k = sampleAt(v.when, onset, sps);
            // A stop due no later than the start ends the voice unheard.
            if (v.stopping && sampleAt(v.stopAt, onset, sps) <= std::max<int64_t>(k, 0)) {
                end(v, Event::Stopped, std::isnan(v.stopAt) ? onset : v.stopAt);
                return;
            }
            if (k >= (int64_t)frames) return;            // due in a later buffer
            bool late = k < 0;
            first = late ? 0 : k;
            v.started = true;
            emit(Event{Event::Start, late ? Event::Late : Event::OnTime, v.id, v.when,
                       sampleTime(onset, (double)first, sps)});
        }
        int64_t last = frames;                           // one past the last sample to play here
        bool stopsHere = false;
        if (v.stopping) {
            int64_t s = sampleAt(v.stopAt, onset, sps);
            if (s < (int64_t)frames) { last = std::max(s, first); stopsHere = true; }
        }
        const Sound &snd = *v.sound;
        if (snd.frames == 0) { end(v, Event::Finished, sampleTime(onset, (double)first, sps)); return; }
        uint64_t total = v.repeats ? snd.frames * v.repeats : UINT64_MAX;
        uint64_t remaining = total - v.position;
        if ((uint64_t)(last - first) > remaining) { last = first + (int64_t)remaining; stopsHere = false; }
        int64_t i = first;
        if (v.changing) {                                // a change due here: play up to it, then switch
            int64_t at = std::max(sampleAt(v.nextAt, onset, sps), first);
            if (at < last) {
                add(v, out, channels, i, at, onset, sps);
                i = at;
                v.modulation = v.next;
                v.changing = false;
            }
        }
        add(v, out, channels, i, last, onset, sps);
        if (v.position == total)
            end(v, Event::Finished, sampleTime(onset, (double)last, sps));
        else if (stopsHere)
            end(v, Event::Stopped, sampleTime(onset, (double)last, sps));
    }

    // Adds the voice's samples for buffer samples [from, to), across repeats,
    // at its gain and modulation.
    static void add(Voice &v, float *const *out, uint32_t channels, int64_t from, int64_t to,
                    double onset, double sps) noexcept {
        const Sound &snd = *v.sound;
        const Modulation &m = v.modulation;
        const double kTwoPi = 6.283185307179586;
        // The phase at `from`, from that sample's time: whole cycles removed
        // before multiplying by 2 pi keep it exact at large GetSecs times.
        double cycles = m.hz * sampleTime(onset, (double)from, sps);
        double theta = kTwoPi * (cycles - std::floor(cycles)) + m.phase;
        double step = kTwoPi * m.hz / sps;
        double half = 0.5 * m.depth;
        for (int64_t i = from; i < to; ) {
            // Up to the end of the current repeat in one run.
            uint64_t at = v.position % snd.frames;
            int64_t run = std::min<int64_t>(to - i, (int64_t)(snd.frames - at));
            if (m.depth == 0) {
                for (uint32_t ch = 0; ch < channels; ch++) {
                    if (snd.channels != 1 && ch >= snd.channels) continue;
                    const float *src = snd.samples.data() + (snd.channels == 1 ? 0 : (uint64_t)ch * snd.frames) + at;
                    float *dst = out[ch] + i;
                    for (int64_t j = 0; j < run; j++) dst[j] += v.gain * src[j];
                }
            } else {
                for (int64_t j = 0; j < run; j++, theta += step) {
                    float g = v.gain * (float)(1 - half * (1 - std::cos(theta)));
                    for (uint32_t ch = 0; ch < channels; ch++) {
                        if (snd.channels != 1 && ch >= snd.channels) continue;
                        const float *src = snd.samples.data() + (snd.channels == 1 ? 0 : (uint64_t)ch * snd.frames) + at;
                        out[ch][i + j] += g * src[j];
                    }
                }
            }
            i += run;
            v.position += (uint64_t)run;
        }
    }
};


// Input: one recording at a time into memory allocated before input starts,
// and a voice key. The capture callback, like render, takes no lock and
// allocates nothing. It is told when the buffer's first sample reached the
// device's input (its host time less the input latency).
struct InputCommand {
    enum Kind : uint8_t { Record, StopRecording, ArmKey, DisarmKey } kind = Record;
    uint64_t generation = 0;      // interruption epoch when Record/ArmKey was issued
    uint64_t id = 0;              // the recording's or key's id, echoed in its events
    double when = NAN;            // GetSecs time; NaN: at once
    float threshold = 0;          // ArmKey: absolute amplitude, 0..1
    uint32_t window = 1;          // ArmKey: trigger when `minimum` of the last `window`
    uint32_t minimum = 1;         //   samples reach the threshold
};

struct InputEvent {
    static constexpr uint64_t kNone = UINT64_MAX;
    enum Kind : uint8_t { RecordStart, RecordEnd, Key } kind = RecordStart;
    enum Status : uint8_t {
        OnTime,     // RecordStart: on the sample nearest the requested time, or at once as asked
        Late,       // RecordStart: its time had passed; it started on the buffer's first sample
        Stopped,    // RecordEnd: stopped as asked
        Full,       // RecordEnd: the memory allocated for recording is full
        Interrupted, // RecordEnd: input was interrupted
        Triggered,  // Key: the first sample of the qualifying window
    } status = OnTime;
    uint64_t id = 0;
    double requested = NAN;
    double time = NAN;            // RecordStart/Key: that sample; RecordEnd: just after the last
    uint64_t frames = 0;          // RecordEnd: frames recorded; Key: its frame in the current
                                  //   recording, or kNone when no recording holds it
    float level = 0;              // Key: the triggering sample's absolute amplitude
};

class Recorder {
public:
    std::atomic<uint64_t> interruptionGeneration{0};
    void interrupt(double when) noexcept {
        interruptedAt_.store(when);
        interruptionGeneration.fetch_add(1);
    }
    static constexpr size_t kRing = 256;
    static constexpr uint32_t kMaxWindow = 16384;   // a third of a second at 48 kHz

    Ring<InputCommand, kRing> commands;   // host -> capture callback
    Ring<InputEvent, kRing> events;       // capture callback -> host
    std::atomic<uint64_t> lostEvents{0};
    // The host must observe its latest requested id before reading samples.
    // This acknowledges a reset; subsequent writes only append to the published prefix.
    std::atomic<uint64_t> appliedRecording{0};
    std::atomic<double> firstSampleTime{NAN};
    std::atomic<uint64_t> recorded{0};    // frames of the current recording, readable while it grows

    // Every input sample of the first channel also goes into a short circular
    // monitor, whether or not a recording runs: for level meters and live
    // displays. `monitored` counts the samples written to it.
    static constexpr uint64_t kMonitor = 65536;
    std::atomic<uint64_t> monitored{0};
    std::atomic<double> monitorEnd{NAN};  // the time just after the newest monitored sample
    std::atomic<uint64_t> monitorSequence{0};  // odd while the two above change
    Recorder() : monitor_(new std::atomic<float>[kMonitor]) {
        for (uint64_t i = 0; i < kMonitor; i++) monitor_[i].store(0.f, std::memory_order_relaxed);
    }
    // Host: copies the newest n samples (n <= kMonitor / 2) into dst, oldest
    // first, with the time just after the last of them; returns the count of
    // samples monitored through it, or 0 if fewer than n have arrived or the
    // capture thread overwrote some of them while they were copied (call again).
    // Buffers arriving during the copy are harmless: the ring holds kMonitor
    // samples and a buffer writes at most kMonitor / 4 before it is published.
    uint64_t recent(float *dst, uint64_t n, double &endTime) const noexcept {
        if (n == 0 || n > kMonitor / 2) return 0;
        uint64_t end = 0;
        double time = NAN;
        for (int tries = 0;; tries++) {      // the count and its time, from one buffer
            if (tries == 64) return 0;
            uint64_t sequence = monitorSequence.load(std::memory_order_acquire);
            if (sequence & 1) continue;
            end = monitored.load(std::memory_order_relaxed);
            time = monitorEnd.load(std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (monitorSequence.load(std::memory_order_relaxed) == sequence) break;
        }
        if (end < n) return 0;
        for (uint64_t i = 0; i < n; i++)
            dst[i] = monitor_[(end - n + i) & (kMonitor - 1)].load(std::memory_order_relaxed);
        // A sample overwritten during the copy came from a buffer whose start,
        // the count before it, is now visible (the release fence in capture).
        std::atomic_thread_fence(std::memory_order_acquire);
        if (monitored.load(std::memory_order_relaxed) - end > kMonitor / 4) return 0;
        endTime = time;
        return end;
    }

    // Host only, before capture starts: memory for `seconds` of `channels`.
    void allocate(uint32_t channels, uint64_t frames) {
        channels_ = channels;
        capacity_ = frames;
        samples_.assign((size_t)channels * frames, 0.f);
    }
    uint32_t channels() const { return channels_; }
    uint64_t capacity() const { return capacity_; }
    // Channel c of the recording; frames [0, recorded) are final.
    const float *channel(uint32_t c) const { return samples_.data() + (size_t)c * capacity_; }

    // The capture callback. in[c] holds `frames` samples for channel c.
    void capture(const float *const *in, uint32_t channels, uint32_t frames,
                 double onset, double samplesPerSecond) noexcept {
        syncInterruption();
        InputCommand c;
        // Bound work even when the host keeps replenishing the queue.
        for (size_t i = 0; i < kRing && commands.pop(c); ++i) apply(c);
        double sps = samplesPerSecond;
        if (recording_) record(in, channels, frames, onset, sps);
        if (keyArmed_) listen(in, channels, frames, onset, sps);
        for (uint32_t done = 0; done < frames;) {   // at most kMonitor / 4 before each publish
            uint32_t chunk = (uint32_t)std::min<uint64_t>(frames - done, kMonitor / 4);
            std::atomic_thread_fence(std::memory_order_release);   // the count before these samples
            for (uint32_t i = 0; i < chunk; i++)
                monitor_[(captured_ + i) & (kMonitor - 1)].store(in[0][done + i], std::memory_order_relaxed);
            captured_ += chunk;
            done += chunk;
            monitorSequence.fetch_add(1, std::memory_order_relaxed);    // odd: changing
            std::atomic_thread_fence(std::memory_order_release);
            monitorEnd.store(sampleTime(onset, (double)done, sps), std::memory_order_relaxed);
            monitored.store(captured_, std::memory_order_relaxed);
            monitorSequence.fetch_add(1, std::memory_order_release);    // even: settled
        }
    }

private:
    std::atomic<double> interruptedAt_{NAN};
    uint64_t interruptionSeen_ = 0;
    void syncInterruption() noexcept {
        const uint64_t generation = interruptionGeneration.load();
        if (generation == interruptionSeen_) return;
        if (recording_) finishRecording(InputEvent::Interrupted, interruptedAt_.load());
        keyArmed_ = keyListening_ = false;
        interruptionSeen_ = generation;
    }
    std::unique_ptr<std::atomic<float>[]> monitor_;
    std::vector<float> samples_;
    uint32_t channels_ = 0;
    uint64_t capacity_ = 0;
    uint64_t captured_ = 0;                       // samples seen since capture began

    bool recording_ = false, recordStarted_ = false, recordStopping_ = false;
    uint64_t recordId_ = 0, recordFirst_ = 0;     // recordFirst_: index of the recording's first sample
    double recordWhen_ = NAN, recordStopAt_ = NAN;

    bool keyArmed_ = false, keyListening_ = false;
    uint64_t keyId_ = 0;
    double keyWhen_ = NAN;
    float threshold_ = 0;
    uint32_t window_ = 1, minimum_ = 1;
    struct Above { uint64_t index; float level; };
    std::array<Above, kMaxWindow> above_{};       // samples at or above threshold, oldest first
    uint32_t aboveHead_ = 0, aboveCount_ = 0;

    void emit(const InputEvent &e) noexcept {
        if (!events.push(e)) lostEvents.fetch_add(1, std::memory_order_relaxed);
    }
    void apply(const InputCommand &c) noexcept {
        syncInterruption();
        if ((c.kind == InputCommand::Record || c.kind == InputCommand::ArmKey) &&
            c.generation != interruptionSeen_) {
            if (c.kind == InputCommand::Record)
                emit(InputEvent{InputEvent::RecordEnd, InputEvent::Interrupted, c.id, c.when,
                                interruptedAt_.load(), 0, 0});
            return;
        }
        switch (c.kind) {
        case InputCommand::Record:
            if (recording_) finishRecording(InputEvent::Stopped, NAN);
            recording_ = true; recordStarted_ = false; recordStopping_ = false;
            recordId_ = c.id; recordWhen_ = c.when; recordStopAt_ = NAN;
            recorded.store(0, std::memory_order_relaxed);
            firstSampleTime.store(NAN, std::memory_order_relaxed);
            appliedRecording.store(c.id, std::memory_order_release);
            break;
        case InputCommand::StopRecording:
            if (recording_) { recordStopping_ = true; recordStopAt_ = c.when; }
            break;
        case InputCommand::ArmKey:
            keyArmed_ = true; keyListening_ = false; keyId_ = c.id; keyWhen_ = c.when;
            threshold_ = c.threshold;
            window_ = std::min<uint32_t>(std::max<uint32_t>(c.window, 1), kMaxWindow);
            minimum_ = std::min<uint32_t>(std::max<uint32_t>(c.minimum, 1), window_);
            aboveHead_ = aboveCount_ = 0;
            break;
        case InputCommand::DisarmKey:
            keyArmed_ = false;
            break;
        }
    }
    static int64_t sampleAt(double t, double onset, double sps) noexcept {
        if (std::isnan(t)) return 0;
        double x = samplePosition(t, onset, sps);
        if (x > 9.0e18) return INT64_MAX;
        if (x < -9.0e18) return INT64_MIN;
        return (int64_t)std::llround(x);
    }
    void finishRecording(InputEvent::Status status, double time) noexcept {
        uint64_t n = recorded.load(std::memory_order_relaxed);
        if (recordStarted_ || status == InputEvent::Stopped)
            emit(InputEvent{InputEvent::RecordEnd, status, recordId_, recordWhen_, time, n, 0});
        recording_ = false;
    }
    void record(const float *const *in, uint32_t channels, uint32_t frames, double onset, double sps) noexcept {
        int64_t first = 0;
        if (!recordStarted_) {
            int64_t k = sampleAt(recordWhen_, onset, sps);
            if (recordStopping_ && sampleAt(recordStopAt_, onset, sps) <= std::max<int64_t>(k, 0)) {
                finishRecording(InputEvent::Stopped, std::isnan(recordStopAt_) ? onset : recordStopAt_);
                return;
            }
            if (k >= (int64_t)frames) return;
            bool late = k < 0;
            first = late ? 0 : k;
            recordStarted_ = true;
            recordFirst_ = captured_ + (uint64_t)first;
            firstSampleTime.store(sampleTime(onset, (double)first, sps), std::memory_order_relaxed);
            emit(InputEvent{InputEvent::RecordStart, late ? InputEvent::Late : InputEvent::OnTime,
                            recordId_, recordWhen_, sampleTime(onset, (double)first, sps), 0, 0});
        }
        int64_t last = frames;
        bool stopsHere = false;
        if (recordStopping_) {
            int64_t s = sampleAt(recordStopAt_, onset, sps);
            if (s < (int64_t)frames) { last = std::max(s, first); stopsHere = true; }
        }
        uint64_t n = recorded.load(std::memory_order_relaxed);
        uint64_t room = capacity_ - n;
        if ((uint64_t)(last - first) > room) { last = first + (int64_t)room; stopsHere = false; }
        uint32_t used = std::min(channels, channels_);
        for (uint32_t ch = 0; ch < channels_; ch++) {
            float *dst = samples_.data() + (size_t)ch * capacity_ + n;
            const float *src = in[ch < used ? ch : 0];
            for (int64_t i = first; i < last; i++) dst[i - first] = src[i];
        }
        n += (uint64_t)(last - first);
        recorded.store(n, std::memory_order_release);
        if (stopsHere) finishRecording(InputEvent::Stopped, sampleTime(onset, (double)last, sps));
        else if (n == capacity_) finishRecording(InputEvent::Full, sampleTime(onset, (double)last, sps));
    }
    void listen(const float *const *in, uint32_t channels, uint32_t frames, double onset, double sps) noexcept {
        int64_t first = 0;
        if (!keyListening_) {
            int64_t k = sampleAt(keyWhen_, onset, sps);
            if (k >= (int64_t)frames) return;
            first = std::max<int64_t>(k, 0);
            keyListening_ = true;
        }
        for (int64_t i = first; i < (int64_t)frames; i++) {
            uint64_t index = captured_ + (uint64_t)i;
            while (aboveCount_ && above_[aboveHead_].index + window_ <= index) {   // left the window
                aboveHead_ = (aboveHead_ + 1) % kMaxWindow;
                aboveCount_--;
            }
            float peak = 0;
            for (uint32_t ch = 0; ch < channels; ch++) peak = std::max(peak, std::fabs(in[ch][i]));
            if (peak < threshold_) continue;
            above_[(aboveHead_ + aboveCount_) % kMaxWindow] = Above{index, peak};
            if (++aboveCount_ < minimum_) continue;
            const Above &at = above_[aboveHead_];
            // record() already processed this buffer and may have stopped or
            // filled the recording. Membership is determined by its saved
            // sample range, not whether capture will continue next time.
            uint64_t saved = recorded.load(std::memory_order_relaxed);
            bool held = recordStarted_ && at.index >= recordFirst_ && at.index - recordFirst_ < saved;
            emit(InputEvent{InputEvent::Key, InputEvent::Triggered, keyId_, keyWhen_,
                            sampleTime(onset, (double)at.index - (double)captured_, sps),
                            held ? at.index - recordFirst_ : InputEvent::kNone, at.level});
            keyArmed_ = false;
            return;
        }
    }
};

}}  // namespace pm::audio

#endif
