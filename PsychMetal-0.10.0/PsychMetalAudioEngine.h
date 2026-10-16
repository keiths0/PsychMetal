// PsychMetal audio: Core Audio on the Mac and iOS, around the real-time core in
// PsychMetalAudio.h. Included once, at the end of PsychMetalEngine.mm.
// SPDX-License-Identifier: MIT
//
// Output is one output unit (HAL output on the Mac, RemoteIO on iOS) whose
// render callback calls Mixer::render. Input, opened only when asked, is a
// second HAL unit on the Mac (its own device and clock) or RemoteIO's input bus
// on iOS; its callback pulls the samples and calls Recorder::capture. Both
// callbacks only convert the buffer's host time to GetSecs time and add or
// subtract the device's latency. Everything else happens on the caller's
// thread: these functions, like every engine call, have one caller at a time.

#include "PsychMetalAudioHost.h"
#include "PsychMetalOfflineAudio.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#if !PM_IOS
#import <CoreAudio/CoreAudio.h>
#endif

namespace {

constexpr uint32_t kMaxChannels = 32;
constexpr uint32_t kMaxInputFrames = 8192;

double hostSeconds(uint64_t ticks) {
    static const mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t value{};
        mach_timebase_info(&value);
        return value;
    }();
    return (double)ticks * tb.numer / tb.denom * 1e-9;
}

#if PM_IOS
// Notifications can outlive observer removal. Their work owns this state,
// and Close invalidates it on the same serial queue before disposing the unit.
struct AudioRecovery {
    dispatch_queue_t queue = dispatch_queue_create("PsychMetal audio recovery", DISPATCH_QUEUE_SERIAL);
    AudioComponentInstance output = nullptr;
    pm::audio::Mixer *mixer = nullptr;
    pm::audio::Recorder *recorder = nullptr;
    bool closed = false;
    std::atomic<bool> paused{false};
};
#endif

struct Audio {
    AudioComponentInstance output = nullptr, input = nullptr;   // on iOS input == output
    std::unique_ptr<pm::audio::Session> session;
    std::shared_ptr<std::atomic<bool>> lost = std::make_shared<std::atomic<bool>>(false);          // the device went away or the session was interrupted
    // Input pulled by the input callback: one buffer per channel, preallocated.
    std::vector<float> inputSamples;
    std::vector<uint8_t> inputListMemory;
    AudioBufferList *inputList = nullptr;
    const float *inputChannels[kMaxChannels] = {};
#if !PM_IOS
    AudioObjectID outputDevice = 0, inputDevice = 0;
    pm::AudioOptions options;
    bool recoveryPaused=false,recoveryClosing=false;
    double recoveryRetry=0;
    // What opening changed on a device, to put back at close: a device's sample
    // rate is shared by every program using it.
    struct Settings {
        AudioObjectID device = 0;
        Float64 oldRate = 0, setRate = 0;
        UInt32 oldFrames = 0, setFrames = 0;
    } outputSettings, inputSettings;
    // Device notices: the queue they arrive on, and what to remove at close.
    dispatch_queue_t notices = nullptr;
    struct Watch {
        AudioObjectID device;
        AudioObjectPropertySelector selector;
        AudioObjectPropertyListenerBlock block;
    };
    std::vector<Watch> watched;
#else
    id interruptionObserver = nil, routeObserver = nil;
    std::shared_ptr<AudioRecovery> recovery = std::make_shared<AudioRecovery>();
#endif
};
std::unique_ptr<Audio> audioState;

[[noreturn]] void audioFail(const char *what) { throw pm::Error(pm::kErrAudio, what); }
[[noreturn]] void audioFail(const std::string &what) { throw pm::Error(pm::kErrAudio, what); }
void check(OSStatus status, const char *what) {
    if (status != noErr) audioFail(std::string(what) + " (Core Audio status " + std::to_string((int)status) + ").");
}
pm::audio::Session &audioSession() {
    if (!audioState) audioFail("Audio is not open; call OpenAudio first.");
    return *audioState->session;
}

AudioStreamBasicDescription floatFormat(double rate, uint32_t channels) {
    AudioStreamBasicDescription f = {};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBytesPerPacket = f.mBytesPerFrame = sizeof(float);
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = channels;
    f.mBitsPerChannel = 32;
    return f;
}

// Samples per second of GetSecs time: the nominal rate, corrected by the
// timestamp's rate scalar (actual over nominal host ticks per sample).
double samplesPerSecond(const AudioTimeStamp *ts, double rate) {
    if ((ts->mFlags & kAudioTimeStampRateScalarValid) && ts->mRateScalar > 0) return rate / ts->mRateScalar;
    return rate;
}
double bufferHostTime(const AudioTimeStamp *ts) {
    return (ts->mFlags & kAudioTimeStampHostTimeValid) ? hostSeconds(ts->mHostTime) : CACurrentMediaTime();
}

OSStatus renderOutput(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *ts, UInt32,
                      UInt32 frames, AudioBufferList *io) {
    pm::audio::Session *s = static_cast<pm::audio::Session *>(ref);
    float *out[kMaxChannels];
    UInt32 n = io->mNumberBuffers < kMaxChannels ? io->mNumberBuffers : kMaxChannels;
    for (UInt32 c = 0; c < n; c++) out[c] = static_cast<float *>(io->mBuffers[c].mData);
    s->mixer.render(out, n, frames, bufferHostTime(ts) + s->info.outputLatency,
                    samplesPerSecond(ts, s->info.rate));
    return noErr;
}

OSStatus captureInput(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                      UInt32 frames, AudioBufferList *) {
    Audio *a = static_cast<Audio *>(ref);
    if (frames > kMaxInputFrames) return kAudio_ParamError;
    for (UInt32 c = 0; c < a->inputList->mNumberBuffers; c++) {
        a->inputList->mBuffers[c].mDataByteSize = frames * sizeof(float);
        a->inputList->mBuffers[c].mData = (void *)a->inputChannels[c];
    }
    OSStatus status = AudioUnitRender(a->input, flags, ts, bus, frames, a->inputList);
    if (status != noErr) return status;
    pm::audio::Session &s = *a->session;
    s.recorder.capture(a->inputChannels, a->inputList->mNumberBuffers, frames,
                       bufferHostTime(ts) - s.info.inputLatency, samplesPerSecond(ts, s.info.inputRate));
    return noErr;
}

void prepareInputBuffers(Audio &a, uint32_t channels) {
    a.inputSamples.assign((size_t)channels * kMaxInputFrames, 0.f);
    a.inputListMemory.assign(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * channels, 0);
    a.inputList = reinterpret_cast<AudioBufferList *>(a.inputListMemory.data());
    a.inputList->mNumberBuffers = channels;
    for (uint32_t c = 0; c < channels; c++) {
        a.inputChannels[c] = a.inputSamples.data() + (size_t)c * kMaxInputFrames;
        a.inputList->mBuffers[c].mNumberChannels = 1;
    }
}

AudioComponentInstance newOutputUnit(OSType subtype) {
    AudioComponentDescription d = {kAudioUnitType_Output, subtype, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent c = AudioComponentFindNext(nullptr, &d);
    if (!c) audioFail("The system's audio output unit is unavailable.");
    AudioComponentInstance unit = nullptr;
    check(AudioComponentInstanceNew(c, &unit), "Could not create an audio unit");
    return unit;
}
void disposeUnit(AudioComponentInstance &unit) {
    if (!unit) return;
    AudioOutputUnitStop(unit);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    unit = nullptr;
}

// Microphone access, asked once; waits for the person's answer. A refusal is its
// own error, so a program can tell it from a fault and say where to turn it on.
[[noreturn]] void microphoneRefused(const char *what) { throw pm::Error(pm::kErrMicrophone, what); }
void requireMicrophone() {
#if PM_IOS
    __block BOOL granted = NO;
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    if (@available(iOS 17.0, *)) {
        AVAudioApplicationRecordPermission p = [AVAudioApplication sharedInstance].recordPermission;
        if (p == AVAudioApplicationRecordPermissionGranted) return;
        if (p == AVAudioApplicationRecordPermissionDenied)
            microphoneRefused("Microphone access is off for this app. Turn it on in Settings, under the app's name.");
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL ok) { granted = ok; dispatch_semaphore_signal(answered); }];
    } else {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if (s.recordPermission == AVAudioSessionRecordPermissionGranted) return;
        if (s.recordPermission == AVAudioSessionRecordPermissionDenied)
            microphoneRefused("Microphone access is off for this app. Turn it on in Settings, under the app's name.");
        [s requestRecordPermission:^(BOOL ok) { granted = ok; dispatch_semaphore_signal(answered); }];
    }
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    if (!granted) microphoneRefused("Microphone access was refused. Turn it on in Settings, under the app's name.");
#else
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) return;
    if (status == AVAuthorizationStatusNotDetermined) {
        __block BOOL granted = NO;
        dispatch_semaphore_t answered = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) {
            granted = ok; dispatch_semaphore_signal(answered);
        }];
        dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
        if (granted) return;
    }
    microphoneRefused("Microphone access is off for the program running PsychMetal (Terminal, MATLAB, Octave or Python). "
                      "Turn it on in System Settings > Privacy & Security > Microphone, then restart that program.");
#endif
}

#if !PM_IOS
// --- Mac: Core Audio devices --------------------------------------------------

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}
template <class T> bool getProperty(AudioObjectID object, AudioObjectPropertyAddress a, T &value) {
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &value) == noErr;
}
std::string deviceName(AudioObjectID device) {
    CFStringRef name = nullptr;
    if (!getProperty(device, address(kAudioObjectPropertyName), name) || !name) return "";
    char text[256] = {};
    CFStringGetCString(name, text, sizeof(text), kCFStringEncodingUTF8);
    CFRelease(name);
    return text;
}
uint32_t deviceChannels(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &size) != noErr || !size) return 0;
    std::vector<uint8_t> memory(size);
    auto *list = reinterpret_cast<AudioBufferList *>(memory.data());
    if (AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, list) != noErr) return 0;
    uint32_t n = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) n += list->mBuffers[i].mNumberChannels;
    return n;
}
std::string transportName(UInt32 t) {
    switch (t) {
    case kAudioDeviceTransportTypeBuiltIn: return "built-in";
    case kAudioDeviceTransportTypeUSB: return "USB";
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth";
    case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE";
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay";
    case kAudioDeviceTransportTypeHDMI: return "HDMI";
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort";
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt";
    case kAudioDeviceTransportTypeFireWire: return "FireWire";
    case kAudioDeviceTransportTypePCI: return "PCI";
    case kAudioDeviceTransportTypeAggregate: return "aggregate";
    case kAudioDeviceTransportTypeVirtual: return "virtual";
    default: return "other";
    }
}
UInt32 transportOf(AudioObjectID device) {
    UInt32 t = 0;
    getProperty(device, address(kAudioDevicePropertyTransportType), t);
    return t;
}
bool timedTransport(UInt32 t) {
    return t != kAudioDeviceTransportTypeBluetooth && t != kAudioDeviceTransportTypeBluetoothLE &&
           t != kAudioDeviceTransportTypeAirPlay;
}
// The device's latency and its first stream's, in frames, for one direction.
UInt32 latencyFrames(AudioObjectID device, AudioObjectPropertyScope scope) {
    UInt32 latency = 0, stream = 0;
    getProperty(device, address(kAudioDevicePropertyLatency, scope), latency);
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyStreams, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &size) == noErr && size >= sizeof(AudioStreamID)) {
        std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
        if (AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, streams.data()) == noErr)
            getProperty(streams[0], address(kAudioStreamPropertyLatency), stream);
    }
    return latency + stream;
}
std::vector<AudioObjectID> allDevices() {
    AudioObjectPropertyAddress a = address(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr) return {};
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data()) != noErr) return {};
    return ids;
}
AudioObjectID defaultDevice(bool input) {
    AudioObjectID d = 0;
    getProperty(kAudioObjectSystemObject,
                address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), d);
    return d;
}
AudioObjectID chooseDevice(int64_t id, bool input) {
    AudioObjectID d = id < 0 ? defaultDevice(input) : (AudioObjectID)id;
    if (!d) audioFail(input ? "There is no audio input device." : "There is no audio output device.");
    if (!deviceChannels(d, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput))
        audioFail(input ? "That device has no audio input; see AudioDevices." : "That device has no audio output; see AudioDevices.");
    return d;
}
// The rates a device offers, as "44100, 48000 Hz"; empty if it does not say.
// Returns whether `rate` is among them (true when the device does not say).
bool offersRate(AudioObjectID d, Float64 rate, std::string &offered) {
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyAvailableNominalSampleRates);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &size) != noErr || size < sizeof(AudioValueRange)) return true;
    std::vector<AudioValueRange> ranges(size / sizeof(AudioValueRange));
    if (AudioObjectGetPropertyData(d, &a, 0, nullptr, &size, ranges.data()) != noErr) return true;
    bool found = false;
    char text[64];
    for (const AudioValueRange &r : ranges) {
        found = found || (rate >= r.mMinimum - 0.5 && rate <= r.mMaximum + 0.5);
        if (r.mMinimum == r.mMaximum) snprintf(text, sizeof(text), "%s%g", offered.empty() ? "" : ", ", r.mMinimum);
        else snprintf(text, sizeof(text), "%s%g-%g", offered.empty() ? "" : ", ", r.mMinimum, r.mMaximum);
        offered += text;
    }
    offered += " Hz";
    return found;
}
// A device changes rate asynchronously: setting it returns at once and the old
// rate reads back until the hardware has switched, which can take a good part
// of a second. Waits up to two seconds for `rate`, woken by the device's own
// notice that its nominal rate changed rather than by polling.
bool settleRate(AudioObjectID d, Float64 rate) {
    auto reached = [&] {
        Float64 now = 0;
        return getProperty(d, address(kAudioDevicePropertyNominalSampleRate), now) && fabs(now - rate) < 0.5;
    };
    if (reached()) return true;
    dispatch_semaphore_t changed = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("PsychMetal sample rate", DISPATCH_QUEUE_SERIAL);
    AudioObjectPropertyListenerBlock noticed = ^(UInt32, const AudioObjectPropertyAddress *) {
        dispatch_semaphore_signal(changed);
    };
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyNominalSampleRate);
    const bool listening = AudioObjectAddPropertyListenerBlock(d, &a, queue, noticed) == noErr;
    const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC));
    bool ok = reached();        // it may have switched before the listener was added
    while (!ok && dispatch_semaphore_wait(changed, deadline) == 0) ok = reached();
    if (listening) AudioObjectRemovePropertyListenerBlock(d, &a, queue, noticed);
    return ok || reached();
}
// Sets the device's rate (if asked) and buffer size; returns the rate in use.
// `saved` records what was there before and what this session set.
double configureDevice(AudioObjectID d, double rate, uint32_t &bufferFrames, Audio::Settings &saved) {
    saved.device = d;
    getProperty(d, address(kAudioDevicePropertyNominalSampleRate), saved.oldRate);
    getProperty(d, address(kAudioDevicePropertyBufferFrameSize), saved.oldFrames);
    saved.setRate = saved.oldRate;
    saved.setFrames = saved.oldFrames;
    if (rate > 0 && fabs(rate - saved.oldRate) >= 0.5) {
        std::string offered;
        if (!offersRate(d, rate, offered))
            audioFail("The device does not offer " + std::to_string((long long)llround(rate)) + " Hz; it offers " + offered + ".");
        Float64 r = rate;
        AudioObjectPropertyAddress a = address(kAudioDevicePropertyNominalSampleRate);
        if (AudioObjectSetPropertyData(d, &a, 0, nullptr, sizeof(r), &r) != noErr)
            audioFail("The device does not accept that sample rate.");
        // From here a failed open puts the old rate back (restoreDevice).
        saved.setRate = r;
        if (!settleRate(d, r)) {
            AudioObjectSetPropertyData(d, &a, 0, nullptr, sizeof(saved.oldRate), &saved.oldRate);
            saved.setRate = saved.oldRate;
            audioFail("The device did not change to that sample rate within two seconds.");
        }
    }
    AudioValueRange range = {};
    getProperty(d, address(kAudioDevicePropertyBufferFrameSizeRange), range);
    UInt32 frames = bufferFrames;
    if (range.mMaximum > 0) frames = (UInt32)fmin(fmax(frames, range.mMinimum), range.mMaximum);
    AudioObjectPropertyAddress fa = address(kAudioDevicePropertyBufferFrameSize);
    AudioObjectSetPropertyData(d, &fa, 0, nullptr, sizeof(frames), &frames);
    getProperty(d, address(kAudioDevicePropertyBufferFrameSize), frames);
    bufferFrames = frames;
    saved.setFrames = frames;
    Float64 actual = 0;
    getProperty(d, address(kAudioDevicePropertyNominalSampleRate), actual);
    if (rate > 0 && fabs(actual - rate) >= 0.5) audioFail("The device did not keep that sample rate.");
    return actual;
}
// Puts back what opening changed, but only where the device still has this
// session's setting: a change someone else made since is theirs to keep.
void restoreDevice(const Audio::Settings &saved) {
    if (!saved.device) return;
    Float64 rate = 0;
    if (saved.oldRate > 0 && saved.setRate != saved.oldRate &&
        getProperty(saved.device, address(kAudioDevicePropertyNominalSampleRate), rate) && rate == saved.setRate) {
        AudioObjectPropertyAddress a = address(kAudioDevicePropertyNominalSampleRate);
        // Waited for, so audio opened straight after closing finds the old rate.
        if (AudioObjectSetPropertyData(saved.device, &a, 0, nullptr, sizeof(saved.oldRate), &saved.oldRate) == noErr)
            settleRate(saved.device, saved.oldRate);
    }
    UInt32 frames = 0;
    if (saved.oldFrames > 0 && saved.setFrames != saved.oldFrames &&
        getProperty(saved.device, address(kAudioDevicePropertyBufferFrameSize), frames) && frames == saved.setFrames) {
        AudioObjectPropertyAddress a = address(kAudioDevicePropertyBufferFrameSize);
        AudioObjectSetPropertyData(saved.device, &a, 0, nullptr, sizeof(saved.oldFrames), &saved.oldFrames);
    }
}
// Watches a device for going away, or for a rate or buffer size other than the
// one this session set (another program changed it): sound times no longer
// hold. Notices arrive on the session's own queue, so they need no run loop, and
// each block holds copies of what it compares, so a notice already in flight
// at close touches nothing that closing frees.
void watchDevice(Audio &a, AudioObjectID d, const Audio::Settings &s) {
    if (!a.notices) a.notices = dispatch_queue_create("PsychMetal audio device notices", DISPATCH_QUEUE_SERIAL);
    std::shared_ptr<std::atomic<bool>> lost = a.lost;
    Float64 rate = s.setRate;
    UInt32 frames = s.setFrames;
    AudioObjectPropertyListenerBlock block = ^(UInt32 count, const AudioObjectPropertyAddress *changed) {
        for (UInt32 i = 0; i < count; i++) {
            if (changed[i].mSelector == kAudioDevicePropertyNominalSampleRate) {
                Float64 now = 0;
                if (getProperty(d, address(kAudioDevicePropertyNominalSampleRate), now) && now == rate) continue;
            } else if (changed[i].mSelector == kAudioDevicePropertyBufferFrameSize) {
                UInt32 now = 0;
                if (getProperty(d, address(kAudioDevicePropertyBufferFrameSize), now) && now == frames) continue;
            }
            lost->store(true);
        }
    };
    // Typed: in the SDK these constants come from different unnamed enums.
    const AudioObjectPropertySelector selectors[] = {kAudioDevicePropertyDeviceIsAlive,
                                                     kAudioDevicePropertyNominalSampleRate,
                                                     kAudioDevicePropertyBufferFrameSize};
    for (AudioObjectPropertySelector selector : selectors) {
        AudioObjectPropertyAddress watched = address(selector);
        if (AudioObjectAddPropertyListenerBlock(d, &watched, a.notices, block) == noErr)
            a.watched.push_back({d, selector, block});
    }
}
void unwatchDevices(Audio &a) {
    for (const Audio::Watch &w : a.watched) {
        AudioObjectPropertyAddress watched = address(w.selector);
        AudioObjectRemovePropertyListenerBlock(w.device, &watched, a.notices, w.block);
    }
    a.watched.clear();
}

static void checkRecoveryRates(double outputRate,double inputRate,bool sharedDevice) {
    if(sharedDevice && inputRate>0 && std::fabs(outputRate-inputRate)>.5)
        audioFail("The fallback device cannot preserve the old distinct input/output sample rates. CloseAudio and reopen it.");
}

void openMac(Audio &a, const pm::AudioOptions &o,double inputRate=0) {
    a.outputDevice = chooseDevice(o.device, false);
    UInt32 transport = transportOf(a.outputDevice);
    a.session->info.timed = timedTransport(transport);
    if (!a.session->info.timed && !o.anyRoute)
        audioFail("The audio output is " + transportName(transport) + ", whose latency is long and variable. "
                  "Use wired or built-in output, or pass anyRoute (routes='any') to play untimed.");
    uint32_t outChannels = deviceChannels(a.outputDevice, kAudioObjectPropertyScopeOutput);
    if (o.channels > outChannels)
        audioFail("The output device has " + std::to_string(outChannels) + " channels.");
    uint32_t frames = o.bufferFrames;
    a.session->info.rate = configureDevice(a.outputDevice, o.rate, frames, a.outputSettings);
    a.session->info.bufferFrames = frames;
    a.session->info.channels = o.channels;
    a.session->info.outputLatency = latencyFrames(a.outputDevice, kAudioObjectPropertyScopeOutput) / a.session->info.rate;
    a.session->info.device = deviceName(a.outputDevice);
    a.session->info.transport = transportName(transport);

    a.output = newOutputUnit(kAudioUnitSubType_HALOutput);
    check(AudioUnitSetProperty(a.output, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                               &a.outputDevice, sizeof(a.outputDevice)), "Could not select the output device");
    AudioStreamBasicDescription f = floatFormat(a.session->info.rate, o.channels);
    check(AudioUnitSetProperty(a.output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f)),
          "The output device refused 32-bit float samples");
    AURenderCallbackStruct cb = {renderOutput, a.session.get()};
    check(AudioUnitSetProperty(a.output, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb)),
          "Could not attach the output callback");
    check(AudioUnitInitialize(a.output), "Could not initialize audio output");
    watchDevice(a, a.outputDevice, a.outputSettings);

    if (o.input) {
        requireMicrophone();
        a.inputDevice = chooseDevice(o.inputDevice, true);
        checkRecoveryRates(a.session->info.rate,inputRate,a.inputDevice==a.outputDevice);
        UInt32 inTransport = transportOf(a.inputDevice);
        uint32_t inChannels = deviceChannels(a.inputDevice, kAudioObjectPropertyScopeInput);
        if (o.inputChannels > inChannels)
            audioFail("The input device has " + std::to_string(inChannels) + " channels.");
        uint32_t inFrames = o.bufferFrames;
        a.session->info.inputRate = configureDevice(a.inputDevice, inputRate>0?inputRate:(a.inputDevice == a.outputDevice ? 0 : o.rate), inFrames,
                                                    a.inputSettings);
        a.session->info.inputBufferFrames = inFrames;
        a.session->info.inputChannels = o.inputChannels;
        a.session->info.inputLatency = latencyFrames(a.inputDevice, kAudioObjectPropertyScopeInput) / a.session->info.inputRate;
        a.session->info.inputDevice = deviceName(a.inputDevice);
        a.session->info.inputTransport = transportName(inTransport);
        prepareInputBuffers(a, o.inputChannels);

        a.input = newOutputUnit(kAudioUnitSubType_HALOutput);
        UInt32 on = 1, off = 0;
        check(AudioUnitSetProperty(a.input, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on)),
              "Could not enable audio input");
        check(AudioUnitSetProperty(a.input, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof(off)),
              "Could not separate audio input from output");
        check(AudioUnitSetProperty(a.input, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &a.inputDevice, sizeof(a.inputDevice)), "Could not select the input device");
        AudioStreamBasicDescription inFormat = floatFormat(a.session->info.inputRate, o.inputChannels);
        check(AudioUnitSetProperty(a.input, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inFormat, sizeof(inFormat)),
              "The input device refused 32-bit float samples");
        UInt32 maxFrames = kMaxInputFrames;
        AudioUnitSetProperty(a.input, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
        AURenderCallbackStruct in = {captureInput, &a};
        check(AudioUnitSetProperty(a.input, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &in, sizeof(in)),
              "Could not attach the input callback");
        check(AudioUnitInitialize(a.input), "Could not initialize audio input");
        if (a.inputDevice != a.outputDevice) watchDevice(a, a.inputDevice, a.inputSettings);
    }
}
void closePlatform(Audio &a) {
    disposeUnit(a.input);
    disposeUnit(a.output);
    unwatchDevices(a);
    // Input first: on a shared device its "before" is output's setting, so the
    // output's restore, last, leaves the device as it was before opening.
    restoreDevice(a.inputSettings);
    restoreDevice(a.outputSettings);
    a.inputSettings = a.outputSettings = Audio::Settings{};
}

// Host-thread recovery: callbacks are stopped/disposed before buffers/settings
// change. Loaded sounds and recording samples stay in the existing Session.
// Preserve client rates so previously loaded PCM is not played at a new rate.
static bool recoverMac(Audio &a) {
    if(a.recoveryClosing)return a.lost->exchange(false);
    const bool changed=a.lost->exchange(false);
    const double now=CACurrentMediaTime();
    if(!changed && !(a.recoveryPaused && now>=a.recoveryRetry)) return false;
    a.recoveryPaused=true;a.recoveryRetry=now+1;
    a.session->mixer.interrupt(now);a.session->recorder.interrupt(now);
    const double rate=a.session->info.rate,inputRate=a.session->info.inputRate;
    closePlatform(a);
    if(a.notices) dispatch_sync(a.notices,^{}); // retired notices cannot restart a new route
    a.lost->store(false);
    try {
        auto options=a.options;options.rate=rate;
        // A removed explicit endpoint falls back to the current default. A
        // still-present explicit endpoint remains selected.
        UInt32 alive=0;
        if(options.device>=0 && (!getProperty((AudioObjectID)options.device,address(kAudioDevicePropertyDeviceIsAlive),alive)||!alive)) options.device=-1;
        alive=0;
        if(options.input && options.inputDevice>=0 && (!getProperty((AudioObjectID)options.inputDevice,address(kAudioDevicePropertyDeviceIsAlive),alive)||!alive)) options.inputDevice=-1;
        openMac(a,options,inputRate);
        a.session->mixer.resumed();
        check(AudioOutputUnitStart(a.output),"Could not restart audio output");
        if(a.input) check(AudioOutputUnitStart(a.input),"Could not restart audio input");
        a.recoveryPaused=false;
    } catch(const std::exception &) {
        closePlatform(a); // retry on the next host call after the cooldown
    }
    // Route changes always invalidate timing. Never resume interrupted voices.
    a.session->info.timed=false;
    return changed;
}

#else
// --- iOS: the audio session and RemoteIO ----------------------------------------

// Play-and-record puts output on the receiver, the earpiece held to the ear in a
// call, where sound is all but inaudible; the category's DefaultToSpeaker option
// does not hold in measurement mode. Move it to the speaker, but only from the
// receiver: headphones, wired or Bluetooth, keep the sound.
void preferSpeaker(AVAudioSession *s) {
    AVAudioSessionPortDescription *now = s.currentRoute.outputs.firstObject;
    if (now && [now.portType isEqualToString:AVAudioSessionPortBuiltInReceiver])
        [s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
}

bool timedPort(NSString *type) {
    return ![type isEqualToString:AVAudioSessionPortBluetoothA2DP] && ![type isEqualToString:AVAudioSessionPortBluetoothLE] &&
           ![type isEqualToString:AVAudioSessionPortBluetoothHFP] && ![type isEqualToString:AVAudioSessionPortAirPlay];
}

void openIOS(Audio &a, const pm::AudioOptions &o) {
    if (o.device >= 0 || o.inputDevice >= 0) audioFail("On iOS the system chooses the audio route; omit device.");
    if (o.input) requireMicrophone();
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *error = nil;
    // Playback ignores the silent switch; play-and-record keeps output on the
    // speaker. Measurement mode turns off the system's voice processing.
    BOOL ok = o.input
        ? [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement
                 options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&error]
        : [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error];
    if (!ok) audioFail("The audio session refused its category.");
    double rate = o.rate > 0 ? o.rate : 48000;
    [s setPreferredSampleRate:rate error:nil];
    [s setPreferredIOBufferDuration:o.bufferFrames / rate error:nil];
    if (![s setActive:YES error:&error]) audioFail("The audio session could not start; another app may hold it.");
    if (o.input) preferSpeaker(s);
    a.session->info.rate = a.session->info.inputRate = s.sampleRate;
    if (o.rate > 0 && fabs(a.session->info.rate - o.rate) > 0.5) audioFail("This device does not run at that sample rate.");
    a.session->info.bufferFrames = a.session->info.inputBufferFrames = (uint32_t)llround(s.IOBufferDuration * a.session->info.rate);
    a.session->info.channels = o.channels;
    if ((NSInteger)o.channels > s.maximumOutputNumberOfChannels) audioFail("The audio route has fewer output channels.");
    a.session->info.outputLatency = s.outputLatency;
    AVAudioSessionPortDescription *out = s.currentRoute.outputs.firstObject;
    a.session->info.device = out ? out.portName.UTF8String : "";
    a.session->info.transport = out ? out.portType.UTF8String : "";
    a.session->info.timed = out ? timedPort(out.portType) : true;
    if (!a.session->info.timed && !o.anyRoute)
        audioFail("Audio is going to " + a.session->info.device + ", whose latency is long and variable. "
                  "Use the speaker or a wired output, or pass anyRoute (routes='any') to play untimed.");

    a.output = a.input = newOutputUnit(kAudioUnitSubType_RemoteIO);
    AudioStreamBasicDescription f = floatFormat(a.session->info.rate, o.channels);
    check(AudioUnitSetProperty(a.output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f)),
          "The audio route refused 32-bit float samples");
    AURenderCallbackStruct cb = {renderOutput, a.session.get()};
    check(AudioUnitSetProperty(a.output, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb)),
          "Could not attach the output callback");
    if (o.input) {
        if ((NSInteger)o.inputChannels > s.inputNumberOfChannels) audioFail("The audio route has fewer input channels.");
        a.session->info.input = true;
        a.session->info.inputChannels = o.inputChannels;
        a.session->info.inputLatency = s.inputLatency;
        AVAudioSessionPortDescription *in = s.currentRoute.inputs.firstObject;
        a.session->info.inputDevice = in ? in.portName.UTF8String : "";
        a.session->info.inputTransport = in ? in.portType.UTF8String : "";
        prepareInputBuffers(a, o.inputChannels);
        UInt32 on = 1;
        check(AudioUnitSetProperty(a.input, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on)),
              "Could not enable audio input");
        AudioStreamBasicDescription inFormat = floatFormat(a.session->info.inputRate, o.inputChannels);
        check(AudioUnitSetProperty(a.input, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inFormat, sizeof(inFormat)),
              "The input refused 32-bit float samples");
        AURenderCallbackStruct in2 = {captureInput, &a};
        check(AudioUnitSetProperty(a.input, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &in2, sizeof(in2)),
              "Could not attach the input callback");
    }
    check(AudioUnitInitialize(a.output), "Could not initialize audio");
    // A notification already in flight can outlive observer removal and Audio.
    auto lost = a.lost;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    auto recovery = a.recovery;
    recovery->output = a.output;
    recovery->mixer = &a.session->mixer;
    recovery->recorder = &a.session->recorder;
    a.interruptionObserver = [nc addObserverForName:AVAudioSessionInterruptionNotification object:s queue:nil
                                         usingBlock:^(NSNotification *n) {
        const NSUInteger kind = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        const NSUInteger options = [n.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        const double at = CACurrentMediaTime();
        dispatch_async(recovery->queue, ^{
            if (recovery->closed) return;
            if (kind == AVAudioSessionInterruptionTypeBegan) {
                recovery->paused.store(true);
                recovery->mixer->interrupt(at);
                recovery->recorder->interrupt(at);
                lost->store(true);
                AudioOutputUnitStop(recovery->output);
            } else if (kind == AVAudioSessionInterruptionTypeEnded &&
                       (options & AVAudioSessionInterruptionOptionShouldResume)) {
                // Resume the device, not interrupted stimuli: those have ended.
                NSError *error = nil;
                bool restarted = false;
                if ([[AVAudioSession sharedInstance] setActive:YES error:&error]) {
                    recovery->mixer->resumed(); // the callback gap belongs to the known interruption
                    restarted = AudioOutputUnitStart(recovery->output) == noErr;
                }
                if (restarted) recovery->paused.store(false);
                else lost->store(true);
            }
        });
    }];
    // A device arriving or leaving moves the sound. The notice iOS posts for the
    // category this session has just set, or for an override, does not.
    bool recording = o.input;
    a.routeObserver = [nc addObserverForName:AVAudioSessionRouteChangeNotification object:s queue:nil
                                  usingBlock:^(NSNotification *n) {
        NSUInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
        // Headphones unplugged with input open: back to the speaker, not the earpiece.
        if (recording && reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
            preferSpeaker([AVAudioSession sharedInstance]);
        if (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable ||
            reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable ||
            reason == AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory)
            lost->store(true);
    }];
}
void closePlatform(Audio &a) {
    if (a.interruptionObserver) [NSNotificationCenter.defaultCenter removeObserver:a.interruptionObserver];
    if (a.routeObserver) [NSNotificationCenter.defaultCenter removeObserver:a.routeObserver];
    a.interruptionObserver = a.routeObserver = nil;
    auto recovery = a.recovery;
    dispatch_sync(recovery->queue, ^{
        recovery->closed = true;
        recovery->output = nullptr;
        recovery->mixer = nullptr;
        recovery->recorder = nullptr;
    });
    a.input = nullptr;                     // the same unit as output
    disposeUnit(a.output);
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}
#endif

}  // namespace

static void audioShutdown() noexcept {
    if (!audioState) return;
    // Explicit CloseAudio ends generated voices too, even when live voices
    // have already retired on the physical clock during a slow export.
    if(audioState->session && audioState->session->observeOutput) {
        pm::audio::Command stop;stop.kind=pm::audio::Command::StopAll;stop.when=pm::now();
        audioState->session->observeOutput(stop,{},false);
    }
    closePlatform(*audioState);
    audioState.reset();
}

std::vector<pm::AudioDevice> pm::audioDevices() { @autoreleasepool {
    std::vector<pm::AudioDevice> list;
#if PM_IOS
    AVAudioSession *s = [AVAudioSession sharedInstance];
    AVAudioSessionPortDescription *out = s.currentRoute.outputs.firstObject, *in = s.currentRoute.inputs.firstObject;
    if (out) list.push_back({0, out.portName.UTF8String, out.portType.UTF8String,
                             (uint32_t)s.outputNumberOfChannels, 0, s.sampleRate, true, false});
    if (in) list.push_back({1, in.portName.UTF8String, in.portType.UTF8String,
                            0, (uint32_t)s.inputNumberOfChannels, s.sampleRate, false, true});
#else
    AudioObjectID out = defaultDevice(false), in = defaultDevice(true);
    for (AudioObjectID d : allDevices()) {
        uint32_t o = deviceChannels(d, kAudioObjectPropertyScopeOutput), i = deviceChannels(d, kAudioObjectPropertyScopeInput);
        if (!o && !i) continue;
        Float64 rate = 0;
        getProperty(d, address(kAudioDevicePropertyNominalSampleRate), rate);
        list.push_back({(int64_t)d, deviceName(d), transportName(transportOf(d)), o, i, rate, d == out, d == in});
    }
#endif
    return list;
} }

namespace {
// Converts planar float samples from one rate to another, once, with the
// system's best-quality converter.
std::vector<float> convertRate(const std::vector<float> &in, uint32_t channels, uint64_t frames,
                               double from, double to, uint64_t &outFrames) {
    AudioStreamBasicDescription src = floatFormat(from, channels), dst = floatFormat(to, channels);
    AudioConverterRef conv = nullptr;
    check(AudioConverterNew(&src, &dst, &conv), "Could not convert the sound's sample rate");
    // Dispose on allocation or conversion failure as well as on success.
    auto disposeConverter = [](OpaqueAudioConverter *value) { AudioConverterDispose(value); };
    std::unique_ptr<OpaqueAudioConverter, decltype(disposeConverter)> owned(conv, disposeConverter);
    UInt32 quality = kAudioConverterQuality_Max;
    AudioConverterSetProperty(conv, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality);
    uint64_t capacity = (uint64_t)ceil(frames * to / from) + 64;
    std::vector<float> out((size_t)channels * capacity);
    struct Source { const std::vector<float> *in; uint32_t channels; uint64_t frames, done; };
    Source source{&in, channels, frames, 0};
    auto supply = [](AudioConverterRef, UInt32 *packets, AudioBufferList *list, AudioStreamPacketDescription **, void *ref) -> OSStatus {
        Source *s = static_cast<Source *>(ref);
        uint64_t n = std::min<uint64_t>(*packets, s->frames - s->done);
        for (uint32_t c = 0; c < s->channels; c++) {
            list->mBuffers[c].mData = (void *)(s->in->data() + (size_t)c * s->frames + s->done);
            list->mBuffers[c].mDataByteSize = (UInt32)(n * sizeof(float));
            list->mBuffers[c].mNumberChannels = 1;
        }
        *packets = (UInt32)n;
        s->done += n;
        return noErr;
    };
    std::vector<uint8_t> listMemory(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * channels);
    auto *list = reinterpret_cast<AudioBufferList *>(listMemory.data());
    uint64_t written = 0;
    while (written < capacity) {
        UInt32 chunk = (UInt32)std::min<uint64_t>(capacity - written, 4096);
        list->mNumberBuffers = channels;
        for (uint32_t c = 0; c < channels; c++) {
            list->mBuffers[c].mNumberChannels = 1;
            list->mBuffers[c].mData = out.data() + (size_t)c * capacity + written;
            list->mBuffers[c].mDataByteSize = chunk * sizeof(float);
        }
        UInt32 got = chunk;
        OSStatus status = AudioConverterFillComplexBuffer(conv, supply, &source, &got, list, nullptr);
        check(status, "Sample-rate conversion failed");
        written += got;
        if (got == 0) break;
    }
    outFrames = written;
    std::vector<float> packed((size_t)channels * written);
    for (uint32_t c = 0; c < channels; c++)
        std::copy_n(out.data() + (size_t)c * capacity, written, packed.data() + (size_t)c * written);
    return packed;
}
}  // namespace

pm::AudioInfo pm::openAudio(const pm::AudioOptions &o) { @autoreleasepool {
    if(recordingClock.active()) fail("Open audio before starting virtual-clock recording.");
    if (audioState) fail("Audio is already open. Close it first.");
    if (o.channels < 1 || o.channels > kMaxChannels) fail("channels must be 1 to 32.");
    if (o.inputChannels < 1 || o.inputChannels > kMaxChannels) fail("inputChannels must be 1 to 32.");
    if (o.bufferFrames < 16 || o.bufferFrames > 4096) fail("bufferFrames must be 16 to 4096.");
    if (!(o.rate == 0 || (o.rate >= 8000 && o.rate <= 384000))) fail("rate must be 0 (the device's) or 8000 to 384000.");
    if (!(o.recordSeconds > 0 && o.recordSeconds <= 3600)) fail("recordSeconds must be more than 0 and at most 3600.");
    // Initialize the clock conversion before either real-time callback starts.
    (void)hostSeconds(0);
    auto a = std::make_unique<Audio>();
    Audio *ap = a.get();
    pm::audio::Platform platform;
    platform.framePhysical = [](uint64_t token) {
        pthread_mutex_lock(&lock);
        Record *r = recordFor(token);
        double t = r ? r->projected : NAN;
        pthread_mutex_unlock(&lock);
        return t;
    };
    platform.frameProjected=[](uint64_t token) {
        if(recordingClock.active()) return recordingClock.queuedTime(token);
        pthread_mutex_lock(&lock);
        Record *r=recordFor(token);const double t=r?r->projected:NAN;
        pthread_mutex_unlock(&lock);return t;
    };
    platform.framePresented = [](uint64_t token) {
        pthread_mutex_lock(&lock);
        Record *r = recordFor(token);
        double t = (r && r->done && r->status == 0 && r->presented > 0) ? r->presented : NAN;
        pthread_mutex_unlock(&lock);
        return t;
    };
    platform.convertRate = convertRate;
#if PM_IOS
    platform.takeLost = [ap] { return ap->lost->exchange(false); };
#else
    a->options=o;
    platform.takeLost = [ap] {return recoverMac(*ap);};
    platform.playable = [ap] {return !ap->recoveryPaused;};
#endif
    platform.now = [] { return CACurrentMediaTime(); };
    platform.outputTime=[](double when) {
        const double wall=CACurrentMediaTime();
        return recordingClock.active()?wall+when-recordingClock.now(wall):when;
    };
#if PM_IOS
    auto recovery = a->recovery;
    platform.playable = [recovery] { return !recovery->paused.load(); };
#endif
    platform.warn = [](const char *id, const char *message) { hookWarn(id, "%s", message); };
    a->session = std::make_unique<pm::audio::Session>(std::move(platform));
    try {
#if PM_IOS
        openIOS(*a, o);
#else
        openMac(*a, o);
#endif
        a->session->info.input = o.input;
        if (o.input) {
            a->session->info.recordSeconds = o.recordSeconds;
            a->session->allocateInput(o.inputChannels, o.recordSeconds);
        }
        check(AudioOutputUnitStart(a->output), "Could not start audio output");
#if !PM_IOS
        if (a->input) check(AudioOutputUnitStart(a->input), "Could not start audio input");
#endif
    } catch (...) {
        closePlatform(*a);
        throw;
    }
    audioState = std::move(a);
    const pm::AudioInfo &info = audioState->session->info;
    if (!info.timed)
        hookWarn(pm::kWarnAudioRoute, "Audio plays through %s; its latency is unknown, so sound times are not timing measurements.",
                 info.transport.c_str());
    return info;
} }

void pm::closeAudio() {
    @autoreleasepool {
#if !PM_IOS
        if(audioState)audioState->recoveryClosing=true;
#endif
        if (audioState) audioState->session->finish();
        audioShutdown();
    }
}
pm::AudioStatus pm::audioStatus() { return audioState ? audioState->session->status() : pm::AudioStatus{}; }
uint64_t pm::makeSound(const pm::ArrayView &v, double rate) { @autoreleasepool { return audioSession().makeSound(v, rate); } }
void pm::closeSound(uint64_t sound) { audioSession().closeSound(sound); }
uint64_t pm::play(uint64_t sound, double when, uint64_t frame, double offset, double gain, uint32_t repeats) {
    return audioSession().play(sound, when, frame, offset, gain, repeats);
}
void pm::stopSound(uint64_t voice, double when) { audioSession().stopSound(voice, when); }
void pm::modulate(uint64_t voice, double hz, double phase, double depth, double when) {
    audioSession().modulate(voice, hz, phase, depth, when);
}
uint64_t pm::startRecording(double when) { return audioSession().startRecording(when); }
void pm::stopRecording(double when) { audioSession().stopRecording(when); }
pm::Recording pm::getRecording() { return audioSession().recording(); }
uint64_t pm::voiceKey(double threshold, double when, double window, uint32_t minimum) {
    return audioSession().voiceKey(threshold, when, window, minimum);
}
pm::InputRecent pm::inputRecent(double seconds) { return audioSession().recent(seconds); }
std::vector<pm::AudioEvent> pm::audioResults() { return audioSession().results(); }

// For a movie being recorded (PsychMetalRecord.h): the output's rate, and a copy
// of everything the mixer plays from now on. False when audio is not open. A
// session opened later is not tapped.
static bool audioOutputRate(double &rate) {
    if (!audioState || !audioState->session) return false;
    rate = audioState->session->info.rate;
    return true;
}
static bool audioTapAttach(pm::audio::Tap *tap) {
    if (!audioState || !audioState->session) return false;
    audioState->session->mixer.tap.attach(tap);
    return true;
}
static void audioTapDetach(pm::audio::Tap *tap) {
    if (!audioState || !audioState->session) return;
    audioState->session->mixer.tap.detach(tap);
}

// Offline audio observes only commands issued during this export. Existing live
// voices must be stopped first; no unsynchronized copy of callback state occurs.
static void audioOfflineAttach(const std::shared_ptr<pm::audio::OfflineAudio> &offline) {
    if(!audioState || !audioState->session) return;
    std::weak_ptr<pm::audio::OfflineAudio> weak=offline;
    audioState->session->observeOutput=[weak](const pm::audio::Command &c,std::shared_ptr<const pm::audio::Sound> sound,bool frameKeyed) {
        if(auto out=weak.lock()) out->capture(c,std::move(sound),pm::now(),frameKeyed);
    };
}
static void audioOfflineDetach() {
    if(audioState && audioState->session) audioState->session->observeOutput={};
}
