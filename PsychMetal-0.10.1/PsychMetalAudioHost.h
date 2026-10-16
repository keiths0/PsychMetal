// PsychMetal audio: the host side of a session, between the engine's audio
// calls and the real-time core. Plain C++17 with no Apple headers: the Core
// Audio engine and the scripted test engine both use it, so the tests run this
// code, not a copy of it.
// SPDX-License-Identifier: MIT
//
// A Session owns the mixer and recorder that the device callbacks drive, the
// loaded sounds, the voices still playing, and the events not yet reported. Its
// methods run on the caller's thread, one at a time (the front ends hold an
// audio lock); the callbacks touch only the core's rings and atomics.
#ifndef PSYCHMETAL_AUDIO_HOST_H
#define PSYCHMETAL_AUDIO_HOST_H

#include "PsychMetalAudio.h"
#include "PsychMetalEngine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <deque>
#include <cstring>
#include <limits>
#include <functional>
#include <memory>
#include <map>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace pm { namespace audio {

// What a session needs from the engine around it.
struct Platform {
    // A queued or prepared frame's projected presentation time; NaN if unknown.
    std::function<double(uint64_t)> frameProjected;
    // Actual device target when frameProjected is a logical export time.
    std::function<double(uint64_t)> framePhysical;
    // A frame's confirmed presentation time; NaN until the display reports it.
    std::function<double(uint64_t)> framePresented;
    // Converts planar samples from one rate to another, once, off the callback.
    std::function<std::vector<float>(const std::vector<float> &, uint32_t channels, uint64_t frames,
                                     double from, double to, uint64_t &outFrames)> convertRate;
    // Takes "the device or route changed" since it was last asked.
    std::function<bool()> takeLost;
    std::function<double()> now;
    std::function<double(double)> outputTime; // logical requests -> physical device time during export
    std::function<bool()> playable; // false while iOS has interrupted/deactivated the session
    std::function<void(const char *id, const char *message)> warn;
};

[[noreturn]] inline void sessionFail(const std::string &what) { throw pm::Error(pm::kErrAudio, what); }

class Session {
public:
    Mixer mixer;
    Recorder recorder;
    AudioInfo info;
    // Host-thread observer for generated movie audio; never called by Core Audio.
    std::function<void(const Command &, std::shared_ptr<const Sound>, bool frameKeyed)> observeOutput;

    explicit Session(Platform platform) : platform_(std::move(platform)) {}

    void allocateInput(uint32_t channels, double seconds) {
        recorder.allocate(channels, (uint64_t)std::ceil(seconds * info.inputRate));
    }

    AudioStatus status() {
        collect();
        AudioStatus s;
        s.open = true;
        s.info = info;
        s.sounds = sounds_.size();
        s.voices = voices_.size();
        s.clippedSamples = mixer.clippedSamples.load();
        s.lostEvents = mixer.lostEvents.load() + recorder.lostEvents.load();
        s.recording = recordingOpen_;
        s.recordedFrames = info.input && recordingApplied() ? recorder.recorded.load(std::memory_order_acquire) : 0;
        return s;
    }

    uint64_t makeSound(const ArrayView &v, double rate) {
        collect();
        if (v.type != ScalarType::Float64 && v.type != ScalarType::Float32)
            sessionFail("Sound samples must be double or single precision.");
        if (v.ndim < 1 || v.ndim > 2 || !v.data) sessionFail("Sound samples must be a vector or a frames x channels matrix.");
        uint64_t frames = v.shape[0];
        uint32_t channels = v.ndim == 2 ? (uint32_t)v.shape[1] : 1;
        if (frames == 0 || channels == 0) sessionFail("A sound needs at least one sample.");
        if (channels != 1 && channels != info.channels)
            sessionFail("A sound has one channel, or as many as the audio output (" + std::to_string(info.channels) + ").");
        if (!(rate == 0 || (rate >= 1000 && rate <= 384000))) sessionFail("rate must be 0 (the output's) or 1000 to 384000.");
        if (frames > (uint64_t)(std::max(rate, info.rate) * 3600)) sessionFail("A sound may be at most an hour long.");
        std::vector<float> planar((size_t)channels * frames);
        const char *base = static_cast<const char *>(v.data);
        for (uint32_t c = 0; c < channels; c++)
            for (uint64_t i = 0; i < frames; i++) {
                const char *p = base + (ptrdiff_t)i * v.strides[0] + (v.ndim == 2 ? (ptrdiff_t)c * v.strides[1] : 0);
                // NumPy permits strided arrays whose samples are not naturally aligned.
                double x;
                if (v.type == ScalarType::Float64) std::memcpy(&x, p, sizeof(x));
                else { float f; std::memcpy(&f, p, sizeof(f)); x = f; }
                if (!std::isfinite(x) || std::fabs(x) > std::numeric_limits<float>::max())
                    sessionFail("Sound samples must be finite and representable in single precision.");
                if (std::fabs(x) > 1) sessionFail("Sound samples must be normalized to -1..1; use gain to amplify playback.");
                planar[(size_t)c * frames + i] = (float)x;
            }
        auto sound = std::make_shared<Sound>();
        sound->channels = channels;
        if (rate > 0 && std::fabs(rate - info.rate) > 1e-9) {
            uint64_t converted = 0;
            sound->samples = platform_.convertRate(planar, channels, frames, rate, info.rate, converted);
            sound->frames = converted;
            if (!converted) sessionFail("The sound is too short to convert to the output's rate.");
        } else {
            sound->samples = std::move(planar);
            sound->frames = frames;
        }
        uint64_t handle = newId(nextSound_, "Sound handles");
        sounds_.emplace(handle, std::move(sound));
        return handle;
    }

    bool hasActiveStreams() {
        collect();for(const auto &v:voices_)if(v.second.sound->stream)return true;return false;
    }
    uint64_t makeStream(uint64_t frames,uint32_t channels) {
        collect();
        if(frames<16 || frames>16777216 || channels<1 || channels>32 || (channels!=1 && channels!=info.channels) ||
           frames>256ull*1024*1024/(sizeof(float)*std::max<uint32_t>(1,channels)))
            sessionFail("Stream needs 16..16777216 frames, mono or output channels, at most 256 MiB.");
        auto sound=std::make_shared<Sound>();sound->channels=channels;sound->frames=frames;
        sound->stream=std::make_shared<Stream>(channels,frames);
        uint64_t id=newId(nextSound_,"Sound handles");sounds_.emplace(id,std::move(sound));return id;
    }
    Stream &streamFor(uint64_t id) {
        auto found=sounds_.find(id);
        if(found==sounds_.end() || !found->second->stream) sessionFail("Invalid refillable audio stream handle.");
        return *found->second->stream;
    }
    AudioStreamStatus streamStatus(uint64_t id) {
        collect();auto &s=streamFor(id);
        // Only this host publishes head. Consumer may release more space after
        // this snapshot, which conservatively understates available capacity.
        auto h=s.head.load(std::memory_order_relaxed),t=s.tail.load(std::memory_order_acquire);
        return {s.capacity,h-t,s.capacity-(h-t),h,t,s.underflowFrames.load(),s.sealed.load()};
    }
    uint64_t refill(uint64_t id,const ArrayView &v,bool final) {
        collect();auto &s=streamFor(id);
        if(s.sealed.load()) sessionFail("The stream is already sealed.");
        if((v.type!=ScalarType::Float32 && v.type!=ScalarType::Float64) || (!v.data && v.shape[0]) ||
           v.ndim<1 || v.ndim>2 || (v.ndim==2?v.shape[1]:1)!=s.channels)
            sessionFail("Refill needs real single/double frames x stream channels at the output rate.");
        uint64_t n=v.shape[0],h=s.head.load(std::memory_order_relaxed),t=s.tail.load(std::memory_order_acquire);
        if(n>s.capacity-(h-t)) sessionFail("Refill exceeds free stream capacity; query AudioStreamStatus first.");
        auto sample=[&](uint64_t i,uint32_t c) {
            const char *p=(const char*)v.data+(ptrdiff_t)i*v.strides[0]+(v.ndim==2?(ptrdiff_t)c*v.strides[1]:0);
            double x;if(v.type==ScalarType::Float64)std::memcpy(&x,p,8);else {float f;std::memcpy(&f,p,4);x=f;}
            if(!std::isfinite(x)||std::abs(x)>1)sessionFail("Refill samples must be finite and normalized to -1..1.");
            return (float)x;
        };
        // Validate the entire block first; a rejected refill publishes nothing.
        for(uint32_t c=0;c<s.channels;c++)for(uint64_t i=0;i<n;i++) (void)sample(i,c);
        for(uint32_t c=0;c<s.channels;c++)for(uint64_t i=0;i<n;i++)
            s.samples[(uint64_t)c*s.capacity+(h+i)%s.capacity]=sample(i,c);
        s.head.store(h+n,std::memory_order_release);
        if(final)s.sealed.store(true,std::memory_order_release);
        return n;
    }

    void closeSound(uint64_t handle) {
        collect();
        if (!sounds_.erase(handle)) sessionFail("Invalid or closed sound handle.");
    }

    uint64_t play(uint64_t handle, double when, uint64_t frame, double offset, double gain, uint32_t repeats) {
        collect();
        if (platform_.playable && !platform_.playable())
            sessionFail("Audio is interrupted; wait for the system to permit resuming, or close and reopen audio.");
        auto found = sounds_.find(handle);
        if (found == sounds_.end()) sessionFail("Invalid or closed sound handle.");
        if (!std::isfinite(gain) || gain < 0 || gain > 1000) sessionFail("gain must be 0 to 1000.");
        if (!std::isfinite(offset) || std::fabs(offset) > 3600) sessionFail("offset must be finite, within an hour.");
        checkWhen(when);
        double physicalFrame=NAN;
        if (frame) {
            if (!std::isnan(when)) sessionFail("Give a time or a frame, not both.");
            double projected = platform_.frameProjected(frame);
            if (!std::isfinite(projected))
                sessionFail("That frame is not queued; use a token from QueueFlip.");
            when = projected + offset;
            if(platform_.framePhysical) {
                physicalFrame=platform_.framePhysical(frame)+offset;
                if(!std::isfinite(physicalFrame)) sessionFail("That frame is no longer available.");
            }
        } else if (offset != 0) {
            if (std::isnan(when)) sessionFail("offset needs a time or a frame.");
            when += offset;
        }
        if (voices_.size() >= Mixer::kRetired)
            sessionFail("Too many sounds are playing or waiting to play (" + std::to_string(Mixer::kRetired) +
                        "); let some end, or stop them, first.");
        auto stream=found->second->stream;
        if(stream && (stream->played || repeats!=1 || observeOutput))
            sessionFail("Streams play once with repeats=1; virtual-clock recording cannot consume live streams.");
        uint64_t voice = newId(nextVoice_, "Voice ids");
        Command c;
        c.kind = Command::Play;
        c.generation = mixer.interruptionGeneration.load();
        c.voice = voice;
        c.sound = found->second.get();
        c.when = when;
        c.gain = (float)gain;
        c.repeats = repeats;
        voices_.emplace(voice, Voice{found->second, frame});     // kept until the voice ends
        try { pushOutput(c,physicalFrame); }
        catch (...) { voices_.erase(voice); throw; }
        if(stream) stream->played=true;
        if (observeOutput) observeOutput(c, found->second,frame!=0);
        return voice;
    }

    void stopSound(uint64_t voice, double when) {
        collect();
        checkWhen(when);
        if (voice && !voices_.count(voice)) {
            if (voice >= nextVoice_.load()) sessionFail("No sound was played with that voice id.");
            if (observeOutput) {
                Command c; c.kind=Command::Stop; c.voice=voice; c.when=when;
                observeOutput(c, {},false);
            }
            return;                                               // live voice ended; export may still be active
        }
        Command c;
        c.kind = voice ? Command::Stop : Command::StopAll;
        c.voice = voice;
        c.when = when;
        pushOutput(c);
        if (observeOutput) observeOutput(c, {},false);
    }

    void modulate(uint64_t voice, double hz, double phase, double depth, double when) {
        collect();
        checkWhen(when);
        if (!std::isfinite(hz) || hz < 0 || hz > info.rate / 2)
            sessionFail("hz must be 0 to half the output's rate.");
        if (!std::isfinite(phase) || std::fabs(phase) > 1e6) sessionFail("phase must be finite (radians).");
        if (!std::isfinite(depth) || depth < 0 || depth > 1) sessionFail("depth must be 0 to 1.");
        if (!voices_.count(voice)) {
            if (voice == 0 || voice >= nextVoice_.load()) sessionFail("No sound was played with that voice id.");
            if (observeOutput) {
                Command c; c.kind=Command::Modulate; c.voice=voice; c.when=when;
                c.modulation.hz=hz; c.modulation.phase=phase; c.modulation.depth=(float)depth;
                observeOutput(c, {},false);
            }
            return;                                               // live voice ended; export may still be active
        }
        Command c;
        c.kind = Command::Modulate;
        c.voice = voice;
        c.when = when;
        c.modulation.hz = hz;
        c.modulation.phase = phase;
        c.modulation.depth = (float)depth;
        pushOutput(c);
        if (observeOutput) observeOutput(c, {},false);
    }

    uint64_t startRecording(double when) {
        requireInput();
        collect();
        if (platform_.playable && !platform_.playable())
            sessionFail("Audio is interrupted; wait for the system to permit resuming, or close and reopen audio.");
        checkWhen(when);
        InputCommand c;
        c.kind = InputCommand::Record;
        c.generation = recorder.interruptionGeneration.load();
        c.id = newId(nextRecording_, "Recording ids");
        c.when = when;
        push(recorder.commands, c, "input");
        currentRecording_ = c.id;
        recordingOpen_ = true;
        recordingStart_ = NAN;
        return c.id;
    }

    void stopRecording(double when) {
        requireInput();
        collect();
        checkWhen(when);
        InputCommand c;
        c.kind = InputCommand::StopRecording;
        c.when = when;
        push(recorder.commands, c, "input");
    }

    Recording recording() {
        requireInput();
        collect();
        Recording r;
        r.channels = recorder.channels();
        r.rate = info.inputRate;
        // A queued restart may overwrite the previous recording. Until the
        // callback acknowledges this id, expose an empty new recording.
        bool applied = recordingApplied();
        r.frames = applied ? recorder.recorded.load(std::memory_order_acquire) : 0;
        r.firstSampleTime = r.frames ? recorder.firstSampleTime.load(std::memory_order_relaxed) : NAN;
        r.recording = recordingOpen_;
        r.samples.resize((size_t)r.channels * r.frames);
        for (uint32_t c = 0; c < r.channels; c++)
            std::copy_n(recorder.channel(c), r.frames, r.samples.data() + (size_t)c * r.frames);
        return r;
    }

    uint64_t voiceKey(double threshold, double when, double window, uint32_t minimum) {
        requireInput();
        collect();
        if (platform_.playable && !platform_.playable())
            sessionFail("Audio is interrupted; wait for the system to permit resuming, or close and reopen audio.");
        checkWhen(when);
        if (!(threshold > 0 && threshold <= 1)) sessionFail("threshold must be more than 0 and at most 1.");
        double frames = std::round(window * info.inputRate);
        if (!(window > 0) || frames < 1 || frames > Recorder::kMaxWindow)
            sessionFail("window must be at least one sample and at most a third of a second.");
        if (minimum < 1 || minimum > frames) sessionFail("minimum must be 1 to the window's length in samples.");
        InputCommand c;
        c.kind = InputCommand::ArmKey;
        c.generation = recorder.interruptionGeneration.load();
        c.id = newId(nextKey_, "Voice key ids");
        c.when = when;
        c.threshold = (float)threshold;
        c.window = (uint32_t)frames;
        c.minimum = minimum;
        push(recorder.commands, c, "input");
        return c.id;
    }

    InputRecent recent(double seconds) {
        requireInput();
        InputRecent r;
        r.rate = info.inputRate;
        double n = std::round(seconds * r.rate);
        if (!(seconds > 0) || n < 1 || n > Recorder::kMonitor / 2)
            sessionFail("seconds must cover at least one sample and at most " +
                        std::to_string(Recorder::kMonitor / 2) + " samples.");
        r.samples.resize((size_t)n);
        for (int tries = 0; tries < 1000; tries++) {
            if (recorder.recent(r.samples.data(), (uint64_t)n, r.endTime)) return r;
            std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
        sessionFail("Audio input has not delivered that much yet; is the input running?");
    }

    struct VoiceTiming {double start=NAN,end=NAN;bool finished=false;};
    VoiceTiming timing(uint64_t voice) {
        collect();auto found=timings_.find(voice);return found==timings_.end()?VoiceTiming{}:found->second;
    }

    std::vector<AudioEvent> results() {
        collect();
        std::vector<AudioEvent> out(pending_.begin(), pending_.end());
        pending_.clear();
        // Input and output use independent rings. Merge them by sample time;
        // events with no timestamp keep their arrival order after timed events.
        std::stable_sort(out.begin(), out.end(), [](const AudioEvent &a, const AudioEvent &b) {
            double ta = std::isfinite(a.time) ? a.time : INFINITY;
            double tb = std::isfinite(b.time) ? b.time : INFINITY;
            return ta < tb;
        });
        for (auto &e : out)
            if (e.frameToken) e.framePresented = platform_.framePresented(e.frameToken);
        return out;
    }

    // Before closing: a route change or interruption since the last audio call
    // is reported now, so a program that made no audio call after it (a steady
    // tone, then Quit) still hears of it.
    void finish() { collect(); }

private:
    struct Voice { std::shared_ptr<const Sound> sound; uint64_t frame; };
    Platform platform_;
    std::unordered_map<uint64_t, std::shared_ptr<const Sound>> sounds_;
    std::unordered_map<uint64_t, Voice> voices_;
    std::vector<uint64_t> retiring_;      // read from the retired ring; reused, so collect allocates rarely
    std::deque<AudioEvent> pending_;
    std::map<uint64_t,VoiceTiming> timings_;
    // Ids count up for the whole process, not per session, so a handle kept across
    // CloseAudio and OpenAudio can never name a new sound, voice, recording or key.
    static inline std::atomic<uint64_t> nextSound_{1}, nextVoice_{1}, nextRecording_{1}, nextKey_{1};
    static uint64_t newId(std::atomic<uint64_t> &next, const char *what) {
        uint64_t id = next.fetch_add(1);
        if (id >= kMaxId) sessionFail(std::string(what) + " are exhausted.");
        return id;
    }
    uint64_t currentRecording_ = 0;
    bool recordingApplied() const {
        return recorder.appliedRecording.load(std::memory_order_acquire) == currentRecording_;
    }
    bool recordingOpen_ = false;          // asked for, and not yet ended
    double recordingStart_ = NAN;

    void pushOutput(Command c, double physical=NAN) {
        if(std::isfinite(physical)) c.when=physical;
        else if(platform_.outputTime && std::isfinite(c.when)) c.when=platform_.outputTime(c.when);
        push(mixer.commands,c,"output");
    }
    static void checkWhen(double when) {
        if (std::isinf(when)) sessionFail("when must be a GetSecs time, or NaN for at once.");
    }
    void requireInput() const {
        if (!info.input) sessionFail("Audio input is not open; open audio with input=true.");
    }
    template <class Ring, class C> static void push(Ring &ring, const C &c, const char *what) {
        for (int tries = 0; !ring.push(c); tries++) {
            if (tries > 2000) sessionFail(std::string("The audio ") + what + " is not taking commands; is the device running?");
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
    }

    static AudioEvent fromOutput(const Event &e) {
        AudioEventStatus status = e.status == Event::OnTime ? AudioEventStatus::OnTime
                                : e.status == Event::Late ? AudioEventStatus::Late
                                : e.status == Event::Finished ? AudioEventStatus::Finished
                                : e.status == Event::Stopped ? AudioEventStatus::Stopped
                                : e.status == Event::Interrupted ? AudioEventStatus::Interrupted : AudioEventStatus::Refused;
        return {e.kind == Event::Start ? AudioEventKind::SoundStart : AudioEventKind::SoundEnd,
                e.voice, e.requested, e.time, status, NAN, NAN, 0, NAN};
    }
    static AudioEvent fromInput(const InputEvent &e) {
        AudioEventStatus status = e.status == InputEvent::OnTime ? AudioEventStatus::OnTime
                                : e.status == InputEvent::Late ? AudioEventStatus::Late
                                : e.status == InputEvent::Stopped ? AudioEventStatus::Stopped
                                : e.status == InputEvent::Full ? AudioEventStatus::Full
                                : e.status == InputEvent::Interrupted ? AudioEventStatus::Interrupted : AudioEventStatus::Triggered;
        AudioEventKind kind = e.kind == InputEvent::RecordStart ? AudioEventKind::RecordStart
                            : e.kind == InputEvent::RecordEnd ? AudioEventKind::RecordEnd : AudioEventKind::Key;
        double frames = (e.kind == InputEvent::RecordStart || e.frames == InputEvent::kNone) ? NAN : (double)e.frames;
        return {kind, e.id, e.requested, e.time, status, frames, e.kind == InputEvent::Key ? (double)e.level : NAN, 0, NAN};
    }

    // Moves what the callbacks reported into the queue of events, and releases
    // the sounds of voices that have ended. Every call does this first. Voices
    // are released on their retirements, not their events, which can be lost to
    // a full ring; retirements are read first, and the mixer reports a voice's
    // End event before its retirement, so those events are in the ring by then.
    void collect() {
        uint64_t id;
        while (mixer.retired.pop(id)) retiring_.push_back(id);
        Event e;
        while (mixer.events.pop(e)) {
            auto &timing=timings_[e.voice];
            if(e.kind==Event::Start) timing.start=e.time;
            else {timing.end=e.time;timing.finished=e.status==Event::Finished;}
            while(timings_.size()>1024) timings_.erase(timings_.begin());
            AudioEvent out = fromOutput(e);
            auto voice = voices_.find(e.voice);
            if (voice != voices_.end()) out.frameToken = voice->second.frame;
            pending_.push_back(out);
        }
        for (uint64_t ended : retiring_) voices_.erase(ended);
        retiring_.clear();
        InputEvent in;
        while (recorder.events.pop(in)) {
            if (in.id == currentRecording_ && in.kind == InputEvent::RecordStart) recordingStart_ = in.time;
            if (in.id == currentRecording_ && in.kind == InputEvent::RecordEnd) recordingOpen_ = false;
            pending_.push_back(fromInput(in));
        }
        const bool lost = platform_.takeLost && platform_.takeLost();
        const bool stopped = mixer.gap.exchange(false, std::memory_order_relaxed);
        if (lost || stopped) {
            if (lost && platform_.now) {
                const double at = platform_.now();
                mixer.interrupt(at);
                if (info.input) recorder.interrupt(at);
            }
            info.timed = false; // rates and latency belong to the route opened originally
            platform_.warn(kWarnAudioRoute, "The audio device or route changed, the session was interrupted, "
                           "or the output stopped for a while. Sounds scheduled before then may be late or "
                           "silent; check AudioResults, and close and reopen audio for timed work.");
        }
    }
};

}}  // namespace pm::audio

#endif
