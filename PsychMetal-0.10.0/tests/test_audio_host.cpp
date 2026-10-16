// Exercise the actual host/core boundary, including recording reset while
// capture runs on a separate thread. Run under ASan/UBSan and TSan.
#include "PsychMetalAudioHost.h"
#include <cassert>
#include <cstdio>
#include <memory>
#include <thread>

using namespace pm::audio;
int main() {
    { // Timing observation must not consume the caller's AudioResults events.
        Session timingSession(Platform{});timingSession.info.rate=48000;timingSession.info.channels=1;
        std::vector<float> signal(8,.5f);pm::ArrayView v{};v.data=signal.data();v.ndim=1;
        v.shape[0]=signal.size();v.strides[0]=4;v.type=pm::ScalarType::Float32;
        auto sound=timingSession.makeSound(v,0);auto voice=timingSession.play(sound,100,0,0,1,1);
        float rendered[16];float *channels[]={rendered};timingSession.mixer.render(channels,1,16,100,48000);
        auto times=timingSession.timing(voice);
        assert(times.start==100&&times.finished&&std::abs(times.end-(100+8./48000))<1e-10);
        auto events=timingSession.results();assert(events.size()==2);
        assert(timingSession.timing(voice).start==100); // retained after draining events
    }
    bool routeChanged = false;
    Platform platform;
    platform.takeLost = [&] { bool lost = routeChanged; routeChanged = false; return lost; };
    platform.warn = [](const char *, const char *) {};
    Session s(std::move(platform));
    s.info.rate = s.info.inputRate = 48000;
    s.info.channels = 1;
    s.info.input = true;
    s.allocateInput(1, .1);
    float data[64];
    std::fill_n(data, 64, .25f);
    const float *input[] = {data};
    s.startRecording(NAN);
    s.recorder.capture(input, 1, 64, 100, 48000);
    auto first = s.recording();
    assert(first.frames == 64 && first.firstSampleTime == 100);
    s.startRecording(NAN);
    auto pending = s.recording();
    assert(pending.frames == 0 && std::isnan(pending.firstSampleTime));
    assert(pending.recording && s.status().recordedFrames == 0);
    s.recorder.capture(input, 1, 64, 200, 48000);
    auto second = s.recording();
    assert(second.frames == 64 && second.firstSampleTime == 200);
    assert(second.recording); // the previous recording's End cannot end this one

    // Repeated restarts race the callback with copying a published prefix.
    std::atomic<bool> done{false};
    std::thread capture([&] {
        double t = 300;
        while (!done.load()) {
            s.recorder.capture(input, 1, 64, t, 48000);
            t += 64. / 48000;
            std::this_thread::yield();
        }
    });
    for (int i = 0; i < 500; ++i) {
        s.startRecording(NAN);
        auto r = s.recording();
        assert(r.frames <= 4800);
        if (r.frames) {
            assert(std::isfinite(r.firstSampleTime));
            for (float x : r.samples) assert(x == .25f);
        }
        std::this_thread::yield();
    }
    done.store(true);
    capture.join();

    // Sound views can have unaligned, reversed strides (legal NumPy arrays).
    char storage[1 + 3 * sizeof(double)];
    const double values[] = {.125, -.25, .5};
    std::memcpy(storage + 1, values, sizeof(values));
    pm::ArrayView v;
    v.type = pm::ScalarType::Float64;
    v.ndim = 1; v.shape[0] = 3; v.strides[0] = -ptrdiff_t(sizeof(double));
    v.data = storage + 1 + 2 * sizeof(double);
    auto sound = s.makeSound(v, 0);
    s.play(sound, NAN, 0, 0, 1, 1);
    float output[3]; float *out[] = {output};
    s.mixer.render(out, 1, 3, 400, 48000);
    for (int i = 0; i < 3; ++i) assert(output[i] == values[2-i]);
    double huge = std::numeric_limits<double>::max();
    v.data = &huge; v.shape[0] = 1; v.strides[0] = sizeof(double);
    bool rejected = false;
    try { s.makeSound(v, 0); } catch (const pm::Error &) { rejected = true; }
    assert(rejected);
    s.results(); // drain the earlier test events
    Event later{Event::Start, Event::OnTime, 1001, 500, 500};
    InputEvent earlier{InputEvent::Key, InputEvent::Triggered, 1002, 499, 499, 0, .5f};
    assert(s.mixer.events.push(later));
    assert(s.recorder.events.push(earlier));
    auto ordered = s.results();
    assert(ordered.size() == 2 && ordered[0].time == 499 && ordered[1].time == 500);
    s.info.timed = true;
    routeChanged = true;
    assert(!s.status().info.timed);
    assert(!s.status().info.timed); // remains invalid until the session is reopened
    puts("PASS: recording restart/copy concurrency, current recording metadata, unaligned strided sounds and float overflow rejection.");

    // A burst larger than the mixer's voices and the event ring, with no polling
    // between buffers: events are lost and counted, but every voice is retired
    // and its sound released.
    auto outputOnly = [] {
        Platform p;
        p.warn = [](const char *, const char *) {};
        auto session = std::make_unique<Session>(std::move(p));
        session->info.rate = 48000;
        session->info.channels = 1;
        return session;
    };
    {
        auto b = outputOnly();
        const float one[] = {.5f};
        pm::ArrayView click;
        click.type = pm::ScalarType::Float32;
        click.ndim = 1; click.shape[0] = 1; click.strides[0] = sizeof(float);
        click.data = one;
        uint64_t sound = b->makeSound(click, 0);
        float buffer[64]; float *bout[] = {buffer};
        double t = 1000;
        for (int round = 0; round < 3; ++round) {
            for (int k = 0; k < 1000; ++k) b->play(sound, NAN, 0, 0, 1, 1);
            b->mixer.render(bout, 1, 64, t, 48000);   // 256 play, the rest are refused
            b->mixer.render(bout, 1, 64, t + 64. / 48000, 48000);
            t += 128. / 48000;
        }
        auto st = b->status();
        assert(st.voices == 0 && st.lostEvents > 0);
        b->closeSound(sound);
        assert(b->status().sounds == 0);
    }
    // Handles kept across close and reopen never name the new session's sounds or voices.
    {
        auto a = outputOnly();
        const float one[] = {.5f};
        pm::ArrayView click;
        click.type = pm::ScalarType::Float32;
        click.ndim = 1; click.shape[0] = 1; click.strides[0] = sizeof(float);
        click.data = one;
        uint64_t oldSound = a->makeSound(click, 0);
        uint64_t oldVoice = a->play(oldSound, NAN, 0, 0, 1, 0);
        a.reset();                                     // CloseAudio
        auto b = outputOnly();                         // OpenAudio
        uint64_t newSound = b->makeSound(click, 0);
        assert(newSound != oldSound);
        bool refused = false;
        try { b->play(oldSound, NAN, 0, 0, 1, 1); } catch (const pm::Error &) { refused = true; }
        assert(refused);
        uint64_t newVoice = b->play(newSound, NAN, 0, 0, 1, 0);
        assert(newVoice != oldVoice);
        b->stopSound(oldVoice, NAN);                   // an old voice has ended: nothing to stop
        float buffer[8]; float *bout[] = {buffer};
        b->mixer.render(bout, 1, 8, 2000, 48000);
        for (float x : buffer) assert(x == .5f);       // the new voice plays on, untouched
    }
    puts("PASS: voices retired and sounds released through a burst that overflows the event ring; "
         "handles across close and reopen never alias.");
    {
        bool paused = true;
        Platform p; p.playable = [&] { return !paused; }; p.warn = [](const char *, const char *) {};
        Session s(std::move(p)); s.info.rate = 48000; s.info.channels = 1;
        float data[] = {.25f};
        pm::ArrayView v{}; v.data=data; v.type=pm::ScalarType::Float32; v.ndim=1; v.shape[0]=1; v.strides[0]=4;
        uint64_t sound = s.makeSound(v, 48000);
        bool rejected = false; try { s.play(sound,NAN,0,0,1,0); } catch(const pm::Error &) { rejected=true; }
        assert(rejected);
        s.info.input = true; s.info.inputRate = 48000; s.allocateInput(1, .1);
        s.stopRecording(NAN); // cleanup is allowed while interrupted
        bool recordRejected = false;
        try { s.startRecording(NAN); } catch(const pm::Error &) { recordRejected=true; }
        assert(recordRejected);
        paused = false;
        uint64_t voice = s.play(sound,NAN,0,0,1,0);
        float samples[8]; float *out[] = {samples};
        s.mixer.render(out,1,8,100,48000);
        s.mixer.interrupt(100.0001);
        s.mixer.render(out,1,8,100.001,48000);
        auto events = s.results(); bool ended=false;
        for (const auto &e : events) if (e.id == voice && e.status == pm::AudioEventStatus::Interrupted) ended=true;
        assert(ended && s.status().voices == 0);
    }
    puts("PASS: interrupted sessions reject new playback; resumed voices report Interrupted and release their sound ownership.");

    {
        Platform p; p.warn=[](const char *,const char *){};p.outputTime=[](double t){return t+50;};
        auto session=std::make_unique<Session>(std::move(p));
        session->info.rate=48000;session->info.channels=1;
        std::vector<Command> commands;std::shared_ptr<const Sound> retained;
        session->observeOutput=[&](const Command &c,std::shared_ptr<const Sound> sound,bool frameKeyed) {
            assert(!frameKeyed);
            commands.push_back(c);if(sound)retained=std::move(sound);
        };
        float sample=.25f;
        pm::ArrayView v{};v.data=&sample;v.type=pm::ScalarType::Float32;v.ndim=1;v.shape[0]=1;v.strides[0]=4;
        uint64_t sound=session->makeSound(v,48000),voice=session->play(sound,100,0,0,1,1);
        float out[8];float *outputs[]={out};session->mixer.render(outputs,1,8,150,48000);
        auto heard=session->results();assert(heard[0].requested==150 && heard[0].time==150);
        session->closeSound(sound);
        session->modulate(voice,2,0,.5,NAN);session->stopSound(voice,NAN);
        assert(commands[0].when==100);
        assert(commands.size()==3 && commands[0].kind==Command::Play && commands[1].kind==Command::Modulate && commands[2].kind==Command::Stop);
        session.reset();assert(retained && retained->samples[0]==.25f);
    }
    puts("PASS: output observer retains samples and logs stops/modulation after the live voice has retired.");

    { // Device commands use physical frame times; export observes logical ones.
        Platform p;p.warn=[](const char*,const char*){};
        p.frameProjected=[](uint64_t token){return token==42?100.0:NAN;};
        p.framePhysical=[](uint64_t token){return token==42?200.0:NAN;};
        p.framePresented=[](uint64_t){return 200.0;};
        p.outputTime=[](double time){return time+50;};
        auto session=std::make_unique<Session>(std::move(p));
        session->info.rate=48000;session->info.channels=1;bool observed=false;
        session->observeOutput=[&](const Command &c,std::shared_ptr<const Sound>,bool keyed){
            assert(keyed && std::abs(c.when-100.002)<1e-8);observed=true;
        };
        float sample=.5f;pm::ArrayView v{};v.data=&sample;v.type=pm::ScalarType::Float32;
        v.ndim=1;v.shape[0]=1;v.strides[0]=4;
        auto sound=session->makeSound(v,48000);session->play(sound,NAN,42,.002,1,1);
        assert(observed);float out[8];float *outputs[]={out};
        session->mixer.render(outputs,1,8,200.002,48000);
        auto events=session->results();assert(!events.empty());
        assert(std::abs(events[0].requested-200.002)<1e-8 && events[0].frameToken==42);
    }
    puts("PASS: frame-keyed sound preserves logical export time and physical device/event time independently.");

}
