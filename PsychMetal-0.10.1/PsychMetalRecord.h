// PsychMetal movie recording: every frame the window presents, written to a movie.
// SPDX-License-Identifier: MIT
//
// Included by PsychMetalEngine.mm after the movie reader, on the Mac and the
// iPhone alike. Each frame is rendered as usual; then, in the same command buffer,
// the GPU draws the finished frame (scaled, and converted from a 10-bit or float
// drawable) into a pixel buffer from the AVAssetWriterInputPixelBufferAdaptor's
// pool, seen by Metal through CVMetalTextureCache. When the GPU has finished, the
// buffer is appended on the recorder's own queue, stamped with the refresh the
// frame was aimed at, counted from the first recorded frame. A frame held for
// several refreshes therefore lasts as long in the movie. No frame is ever
// dropped: when the encoder falls behind, the next frame waits for it.
//
// The stamp is the frame's aim, not when it was shown: a frame shown late while
// recording (the copy and the encoder add work) is in the movie on time. Stop
// reports how many were shown late, from the display's own reports.
//
// Sound: when audio is open, the mixer copies everything it plays into a tap (a
// lock-free ring: the audio callback never waits), with the time each block is
// heard. A thread of the recorder's own takes the blocks and writes them as the
// movie's sound track, placed by those times against the first frame's aim. The
// display and the sound share GetSecs' clock, so sounds scheduled for a frame's
// time are on that frame in the movie. Two channels: the output's first two.
#include <condition_variable>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <thread>

struct PMRecorder {
    AVAssetWriter *writer = nil;
    AVAssetWriterInput *input = nil;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
    CVMetalTextureCacheRef cache = nullptr;
    id<MTLRenderPipelineState> pipeline = nil;
    dispatch_queue_t queue = nil;           // appends, in order
    std::mutex mutex;
    std::condition_variable changed;
    bool accepting = true;
    int pending = 0;                        // frames drawn for the encoder, not yet appended
    std::string failure;                    // the first thing that went wrong
    size_t width = 0, height = 0;
    bool virtualClock = false;
    pm::recording::Span virtualSpan;
    std::atomic<bool> videoFinished{false},soundFinished{false};
    std::shared_ptr<pm::audio::OfflineAudio> offlineAudio;
    std::atomic<double> soundHorizon{NAN};
    double period = 0;                      // the timebase: the display's nominal refresh period
    int32_t timescale = 600000;
    int64_t perRefresh = 0;                 // timescale units per refresh, when exact
    double first = NAN;                     // the first frame's aim
    int64_t lastTick = -1;
    uint64_t frames = 0;
    std::vector<uint64_t> tokens;           // for counting late frames at stop
    std::map<uint64_t, double> aims;        // each frame's final aim, by token, until it is written
    std::string path, codec;
    NSString *finalPath = nil, *stagingPath = nil;
    bool framebufferOnlyBefore = true;
    // Sound.
    std::unique_ptr<pm::audio::Tap> tap;
    AVAssetWriterInput *soundInput = nil;
    CMAudioFormatDescriptionRef soundFormat = nullptr;
    double soundRate = 0;
    std::thread soundThread;
    std::atomic<double> firstAim{NAN};      // the first frame's aim, for the sound thread
    std::atomic<double> endTime{NAN};       // set at stop: the movie's end, after the first frame
    std::atomic<bool> soundStop{false};
    int64_t soundNext = -1;                 // the next sample of the track, by the movie's clock
    uint64_t soundWritten = 0;              // sample frames written
    ~PMRecorder() {
        if (stagingPath) [NSFileManager.defaultManager removeItemAtURL:[NSURL fileURLWithPath:stagingPath] error:nil];
        if (cache) CFRelease(cache);
        if (soundFormat) CFRelease(soundFormat);
    }
};
static std::shared_ptr<PMRecorder> recorder; // accessed atomically by host/presenter threads

// A stalled/failed writer must not strand the recording queue or its sound
// thread forever. This runs off the audio callback and preserves the first error.
static bool recordingInputReady(PMRecorder *r, AVAssetWriterInput *input) {
    const char *track=input==r->soundInput?"audio":"video";
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    for (;;) {
        {
            std::lock_guard<std::mutex> held(r->mutex);
            if (!r->failure.empty()) return false;
        }
        std::string problem;
        if (r->writer.status != AVAssetWriterStatusWriting)
            problem = std::string("The movie writer stopped accepting ")+track+" media.";
        else if (input.readyForMoreMediaData) return true;
        else if (std::chrono::steady_clock::now() >= deadline)
            problem = std::string("Timed out waiting for the ")+track+" movie encoder to accept media.";
        if (!problem.empty()) {
            std::lock_guard<std::mutex> held(r->mutex);
            if (r->failure.empty()) r->failure = problem;
            r->changed.notify_all();
            return false;
        }
        usleep(500);
    }
}

// Both tracks are push sources produced by the same advancing stimulus. Even
// with logical timestamps this is not an independent AVAssetReader-style source:
// throttling video for ideal interleaving can stop the Flips which generate the
// audio horizon, so neither producer can advance. Real-time input mode suppresses
// that interleaving throttle; readiness still applies actual encoder backpressure.
// Our six-frame admission bound and timeout remain in force; no samples are dropped.
static void configureRecordingInput(AVAssetWriterInput *input) {
    input.expectsMediaDataInRealTime = YES;
}

static CMTime recordingTime(const PMRecorder &r, int64_t tick) {
    return r.perRefresh ? CMTimeMake(tick * r.perRefresh, r.timescale)
                        : CMTimeMake((int64_t)std::llround((double)tick * r.period * r.timescale), r.timescale);
}

// Each producer closes its own input as soon as its last append completes.
// Delaying both EOFs until both producers drain can deadlock writer interleaving.
static void finishRecordingInput(PMRecorder *r, bool sound) {
    auto input=sound?r->soundInput:r->input;
    if(!input) return;
    auto &finished=sound?r->soundFinished:r->videoFinished;
    if(finished.exchange(true)) return;
    {
        std::lock_guard<std::mutex> held(r->mutex);
        if(!r->failure.empty()) return;
    }
    if(r->writer.status!=AVAssetWriterStatusWriting) return;
    @try { [input markAsFinished]; }
    @catch(NSException *error) {
        std::lock_guard<std::mutex> held(r->mutex);
        if(r->failure.empty()) {const char *reason=error.reason.UTF8String;r->failure=std::string("Could not finish the movie input: ")+(reason?reason:"no reason given");}
        r->changed.notify_all();
    }
}

static void closeRecordingAdmission(PMRecorder *r,double logicalStop) {
    bool drained=false;
    {
        std::lock_guard<std::mutex> held(r->mutex);
        r->accepting=false;
        if(r->virtualClock) {
            // Settled admissions give the exact tail even while the last video
            // append is waiting for the audio producer to signal EOF.
            r->endTime.store(r->virtualSpan.end(logicalStop,r->period)*r->period);
            r->soundStop.store(true);
        }
        drained=r->pending==0;r->changed.notify_all();
    }
    if(drained) finishRecordingInput(r,false);
}

// Admission and completion are paired even when buffer allocation or encoding
// fails. Stop closes admission under the same mutex before waiting for zero.
static bool reserveRecordingFrame(PMRecorder *r) {
    std::unique_lock<std::mutex> held(r->mutex);
    if (!r->accepting || !r->failure.empty()) return false;
    if (!r->changed.wait_for(held, std::chrono::seconds(10), [r] {
            return r->pending < 6 || !r->accepting || !r->failure.empty();
        })) {
        r->failure = "The movie encoder stopped taking frames.";
        return false;
    }
    if (!r->accepting || !r->failure.empty()) return false;
    ++r->pending;
    return true;
}
static void releaseRecordingFrame(PMRecorder *r) {
    bool drained=false;
    {
        std::lock_guard<std::mutex> held(r->mutex);
        --r->pending;
        drained=!r->accepting && r->pending==0;
        // Keep Stop waiting until this last producer has also delivered EOF.
        // No new admissions are possible while the completion marker is held.
        if(drained) ++r->pending;
        r->changed.notify_all();
    }
    if(drained) {
        finishRecordingInput(r,false);
        std::lock_guard<std::mutex> held(r->mutex);
        --r->pending;r->changed.notify_all();
    }
}

// Called by encodeFrame, after the frame is rendered into `out`, before the command
// buffer is committed. Never with the engine lock held.
static void recordFrame(id<MTLCommandBuffer> cb, id<MTLTexture> out, uint64_t token) {
    auto owner = std::atomic_load(&recorder);
    PMRecorder *r = owner.get();
    if (!r) return;
    if (!reserveRecordingFrame(r)) return;
    struct Reservation {
        PMRecorder *r;
        bool submitted = false;
        ~Reservation() {
            if (submitted) return;
            releaseRecordingFrame(r);
        }
    } reservation{r};
    // The refresh this frame is aimed at is final now for a queued frame and with a
    // display link; for a Flip, the engine settles it once the frame is handed to
    // the display (recordAim), and the writer waits for that.
    pthread_mutex_lock(&lock);
    Record *q = recordFor(token);
    const bool settled = r->virtualClock || (q && (q->queued || displayLinkPresentation) && isfinite(q->projected));
    const double aimNow = r->virtualClock ? pm::now() : settled ? q->projected : NAN;
    pthread_mutex_unlock(&lock);
    if (settled) {
        std::lock_guard<std::mutex> held(r->mutex);
        r->aims[token] = aimNow;
        if(r->virtualClock) {r->virtualSpan.note(aimNow,r->period);r->soundHorizon.store(aimNow);}
    }

    CVPixelBufferRef pixels = nullptr;
    CVPixelBufferPoolRef pool = r->adaptor.pixelBufferPool;
    if (!pool || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixels) != kCVReturnSuccess || !pixels) {
        std::lock_guard<std::mutex> held(r->mutex);
        r->failure = "The movie writer gave no buffer for a frame.";
        return;
    }
    CVMetalTextureRef metal = nullptr;
    CVMetalTextureCacheFlush(r->cache, 0);
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, r->cache, pixels, nil, MTLPixelFormatBGRA8Unorm,
                                                  r->width, r->height, 0, &metal) != kCVReturnSuccess || !metal) {
        CVPixelBufferRelease(pixels);
        std::lock_guard<std::mutex> held(r->mutex);
        r->failure = "A movie frame's buffer could not be given to Metal.";
        return;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = CVMetalTextureGetTexture(metal);
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;      // every pixel is written
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    if (!re) {
        CFRelease(metal); CVPixelBufferRelease(pixels);
        std::lock_guard<std::mutex> held(r->mutex);
        r->failure = "A movie frame could not be drawn for the encoder.";
        return;
    }
    const float inv[2] = {1.0f / (float)r->width, 1.0f / (float)r->height};
    [re setRenderPipelineState:r->pipeline];
    [re setFragmentTexture:out atIndex:0];
    [re setFragmentBytes:inv length:sizeof(inv) atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];

    {
        std::lock_guard<std::mutex> held(r->mutex);
        if (r->tokens.size() < 1000000) r->tokens.push_back(token);
    }
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        const bool drawn = done.status == MTLCommandBufferStatusCompleted;
        dispatch_async(r->queue, ^{
            PMRecorder *r = owner.get(); // GPU and writer completions retain this session
            // The frame's aim: its stamp, counted in refreshes from the first frame's.
            double aim = NAN;
            {
                std::unique_lock<std::mutex> held(r->mutex);
                r->changed.wait_for(held, std::chrono::seconds(2), [&] { return r->aims.count(token) > 0; });
                auto found = r->aims.find(token);
                if (found != r->aims.end()) { aim = found->second; r->aims.erase(found); }
            }
            if (!isfinite(aim)) {          // not settled in time: the engine's projection as it stands
                pthread_mutex_lock(&lock);
                Record *p = recordFor(token);
                aim = p && isfinite(p->projected) ? p->projected : CACurrentMediaTime();
                pthread_mutex_unlock(&lock);
            }
            if (!isfinite(r->first)) { r->first = aim; r->firstAim.store(aim); }
            int64_t tick = (int64_t)std::llround((aim - r->first) / r->period);
            if (tick <= r->lastTick) tick = r->lastTick + 1;
            r->lastTick = tick;
            r->frames++;
            const CMTime when = recordingTime(*r, tick);
            std::string problem;
            if (!drawn) problem = "The GPU failed to draw a frame for the movie.";
            if (problem.empty() && !recordingInputReady(r, r->input))
                problem = "The movie encoder did not accept a video frame.";
            if (problem.empty() && ![r->adaptor appendPixelBuffer:pixels withPresentationTime:when])
                problem = std::string("The movie writer refused a frame: ") +
                          (r->writer.error ? r->writer.error.localizedDescription.UTF8String : "no reason given");
            CFRelease(metal);
            CVPixelBufferRelease(pixels);
            {
                std::lock_guard<std::mutex> held(r->mutex);
                if (!problem.empty() && r->failure.empty()) r->failure = problem;
            }
            releaseRecordingFrame(r);
        });
    }];
    reservation.submitted = true;
}

// A Flip's frame: the refresh it is aimed at, settled once it was handed to the display.
static void recordAim(uint64_t token, double aim) {
    auto owner = std::atomic_load(&recorder);
    PMRecorder *r = owner.get();
    if (!r || r->virtualClock || !isfinite(aim)) return;
    std::lock_guard<std::mutex> held(r->mutex);
    r->aims[token] = aim;
    r->changed.notify_all();
}

// The sound thread: tap blocks, in order, onto the track. Blocks before the first
// frame are dropped, or cut at it; small jitter between a block's time and the end
// of the last is taken up by placing it at that end; a later block is placed at its
// own time (the gap stays silent); an overlap is cut. At stop, the track is
// written up to the movie's end.
static bool appendRecordedSound(PMRecorder *r, const float *samples, size_t n, int64_t start) {
                CMBlockBufferRef block = nullptr;
                CMSampleBufferRef sample = nullptr;
                bool ok = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, n * 8, kCFAllocatorDefault, nullptr,
                                                             0, n * 8, kCMBlockBufferAssureMemoryNowFlag, &block) == noErr &&
                          CMBlockBufferReplaceDataBytes(samples, block, 0, n * 8) == noErr &&
                          CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, r->soundFormat,
                              (CMItemCount)n, CMTimeMake(start, (int32_t)r->soundRate), nullptr, &sample) == noErr;
                if (ok) ok = recordingInputReady(r, r->soundInput);
                if (ok) ok = [r->soundInput appendSampleBuffer:sample];
                if (sample) CFRelease(sample);
                if (block) CFRelease(block);
                if (!ok) {
                    std::lock_guard<std::mutex> held(r->mutex);
                    if (r->failure.empty()) r->failure = "The movie writer refused the sound.";
                    return false;
                }
    r->soundWritten += n;
    return true;
}

static void soundMain(PMRecorder *r) {
    struct Finish {PMRecorder *r;~Finish(){finishRecordingInput(r,true);}} finish{r};
    pm::audio::TapBacklog waiting;
    const double rate = r->soundRate;
    const int64_t slack = (int64_t)std::llround(rate * 0.010);     // 10 ms
    const auto deadlineAfterStop = std::chrono::milliseconds(750);
    std::chrono::steady_clock::time_point stopped{};
    bool stopping = false;
    for (;;) {
        pm::audio::TapBlock b;
        const double first = r->firstAim.load();
        while (r->tap->blocks.pop(b)) {
            const uint64_t lost = waiting.push(b, first);
            if (lost) r->tap->lostFrames.fetch_add(lost, std::memory_order_relaxed);
        }
        const double end = r->endTime.load();
        const int64_t endSample = isfinite(end) ? (int64_t)std::llround(end * rate) : INT64_MAX;
        if (!stopping && r->soundStop.load()) { stopping = true; stopped = std::chrono::steady_clock::now(); }
        bool reachedEnd = false;
        while (isfinite(first) && !waiting.empty()) {
            const pm::audio::TapBlock &k = waiting.front();
            int64_t start = (int64_t)std::llround((k.onset - first) * rate);
            int64_t from = 0, count = k.frames;                        // the part of the block to write
            if (r->soundNext >= 0 && std::llabs(start - r->soundNext) <= slack) start = r->soundNext;
            if (r->soundNext >= 0 && start < r->soundNext) { from = r->soundNext - start; start = r->soundNext; }
            if (start < 0) { from += -start; start = 0; }
            if (start + (count - from) > endSample) count = from + std::max<int64_t>(0, endSample - start);
            if (start >= endSample) reachedEnd = true;
            if (count > from) {
                const size_t n = (size_t)(count - from);
                if(!appendRecordedSound(r,k.samples+2*from,n,start)) return;
                r->soundNext = start + (int64_t)n;
            }
            waiting.pop_front();
        }
        if (stopping && (reachedEnd || (isfinite(end) && r->soundNext >= endSample) || !isfinite(first) ||
                         std::chrono::steady_clock::now() - stopped > deadlineAfterStop))
            return;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}

static void offlineSoundMain(PMRecorder *r) {
    struct Finish {PMRecorder *r;~Finish(){finishRecordingInput(r,true);}} finish{r};
    try {
        bool aligned=false;
        for(;;) {
            {
                std::lock_guard<std::mutex> guard(r->mutex);
                if(!r->failure.empty()) return;
            }
            // Use one stop snapshot for both the horizon and exit decision.
            // A stop arriving during an append must drain the final horizon next.
            const bool stopping=r->soundStop.load();
            const double first=r->firstAim.load(), end=r->endTime.load();
            if(std::isfinite(first)) {
                if(!aligned) { r->offlineAudio->alignTo(first);aligned=true; }
                const double horizon=stopping && std::isfinite(end)?first+end:r->soundHorizon.load();
                r->offlineAudio->renderUntil(horizon,[&](double onset,const float *samples,uint32_t frames) {
                    int64_t start=(int64_t)std::llround((onset-first)*r->soundRate);
                    const int64_t from=start<0?std::min<int64_t>(frames,-start):0;
                    start+=from;
                    if((int64_t)frames>from && !appendRecordedSound(r,samples+2*from,(size_t)(frames-from),start))
                        throw std::runtime_error("The movie writer refused generated audio.");
                });
                if(r->offlineAudio->failed()) throw std::runtime_error("Movie audio command/memory limit exceeded or a command was backdated.");
                if(stopping && std::isfinite(end)) return;
            } else if(stopping && std::isfinite(end)) return;
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    } catch(const std::exception &error) {
        std::lock_guard<std::mutex> guard(r->mutex);
        if(r->failure.empty()) r->failure=error.what();
        r->changed.notify_all();
    }
}

void pm::startMovieRecording(const std::string &path, const std::string &codec, double scale, bool sound, bool virtualClock) {
    if(hdrOutput)fail("Recording currently writes SDR movies; open an SDR session to record.");
    @autoreleasepool {
        if (!device || closing) fail("PsychMetal is not open.");
        if (std::atomic_load(&recorder)) fail("A movie is already being recorded; StopMovieRecording first.");
        if (!(scale >= 0.05 && scale <= 1)) fail("scale must be 0.05 to 1.");
        NSDictionary<NSString *, AVVideoCodecType> *codecs = @{@"prores4444": AVVideoCodecTypeAppleProRes4444,
            @"prores422": AVVideoCodecTypeAppleProRes422, @"hevc": AVVideoCodecTypeHEVC, @"h264": AVVideoCodecTypeH264};
        AVVideoCodecType type = codecs[[NSString stringWithUTF8String:codec.c_str()]];
        if (!type) fail("codec must be prores4444, prores422, hevc or h264.");
        NSString *file = [NSString stringWithUTF8String:path.c_str()].stringByExpandingTildeInPath;
        NSString *ext = file.pathExtension.lowercaseString;
        AVFileType fileType = [ext isEqualToString:@"mov"] ? AVFileTypeQuickTimeMovie
                            : [ext isEqualToString:@"mp4"] ? AVFileTypeMPEG4
                            : [ext isEqualToString:@"m4v"] ? AVFileTypeAppleM4V : nil;
        if (!fileType) fail("The movie file must end in .mov, .mp4 or .m4v.");
        const bool prores = codec.rfind("prores", 0) == 0;
        if (prores && fileType != AVFileTypeQuickTimeMovie) fail("ProRes is written to a .mov file.");

        if(virtualClock && sound && audioState && audioState->session->hasActiveStreams())
            fail("Stop live streams before virtual-clock recording; use clock=live to capture their actual output.");
        if(exportSession && !virtualClock) fail("An export canvas requires clock=virtual.");
        if(virtualClock) {
            pthread_mutex_lock(&lock);
            const bool idle=frameQueue.empty() && !presenterBusy && !targetHandle;
            pthread_mutex_unlock(&lock);
            if(!idle) fail("Finish queued/offscreen drawing before virtual-clock recording.");
            if(sound && audioState && audioState->session && audioState->session->status().voices)
                fail("Stop existing sounds before virtual-clock recording; it renders newly scheduled sounds.");
        }
        auto r = std::make_shared<PMRecorder>();
        r->virtualClock=virtualClock;
        // Even sizes: the H.264 and HEVC encoders take nothing else.
        r->width = std::max<size_t>(2, (size_t)std::llround((double)renderWidth * scale / 2) * 2);
        r->height = std::max<size_t>(2, (size_t)std::llround((double)renderHeight * scale / 2) * 2);
        r->period = ifi;
        const double hz = 1 / ifi;
        if (std::fabs(hz - std::round(hz)) < 1e-3 && std::round(hz) > 0) {
            r->timescale = (int32_t)std::llround(hz) * 100; r->perRefresh = 100;
        } else if (std::fabs(hz * 1.001 - std::round(hz * 1.001)) < 1e-3) {
            r->timescale = (int32_t)std::llround(hz * 1.001) * 1000; r->perRefresh = 1001;     // 59.94 and its kin
        }
        // The logical clock and PCM must use the same period as the rational
        // video timebase; otherwise rounded NTSC rates accumulate A/V drift.
        if(r->perRefresh) r->period=(double)r->perRefresh/r->timescale;
        r->path = path; r->codec = codec;

        r->finalPath = file;
        r->stagingPath = [file stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
        NSURL *url = [NSURL fileURLWithPath:r->stagingPath];
        NSError *error = nil;
        r->writer = [AVAssetWriter assetWriterWithURL:url fileType:fileType error:&error];
        if (!r->writer)
            failWith(pm::kErrGeneral, "The movie file could not be created: %s", error.localizedDescription.UTF8String);
        NSDictionary *video = @{AVVideoCodecKey: type, AVVideoWidthKey: @(r->width), AVVideoHeightKey: @(r->height),
                                AVVideoColorPropertiesKey: @{AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                             AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                             AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2}};
        r->input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:video];
        configureRecordingInput(r->input);
        if (![r->writer canAddInput:r->input])
            failWith(pm::kErrGeneral, "This system cannot write %s to a .%s file.", codec.c_str(), ext.UTF8String);
        [r->writer addInput:r->input];
        double rate = 0;
        if (sound && audioOutputRate(rate)) {
            NSDictionary *settings = fileType == AVFileTypeQuickTimeMovie
                ? @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @2,
                    AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsBigEndianKey: @NO,
                    AVLinearPCMIsNonInterleaved: @NO}
                : @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @2,
                    AVEncoderBitRateKey: @256000};
            r->soundInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings];
            configureRecordingInput(r->soundInput);
            if (![r->writer canAddInput:r->soundInput])
                failWith(pm::kErrGeneral, "This system cannot write sound at %.0f Hz to a .%s file; record to .mov.",
                         rate, ext.UTF8String);
            [r->writer addInput:r->soundInput];
            AudioStreamBasicDescription d{};
            d.mSampleRate = rate; d.mFormatID = kAudioFormatLinearPCM;
            d.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            d.mChannelsPerFrame = 2; d.mBitsPerChannel = 32; d.mBytesPerFrame = 8; d.mFramesPerPacket = 1; d.mBytesPerPacket = 8;
            if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &d, 0, nullptr, 0, nullptr, nullptr, &r->soundFormat) != noErr)
                fail("Could not describe the movie's sound.");
            r->soundRate = rate;
        }
        r->adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:r->input
            sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                          (id)kCVPixelBufferWidthKey: @(r->width), (id)kCVPixelBufferHeightKey: @(r->height),
                                          (id)kCVPixelBufferMetalCompatibilityKey: @YES}];
        if (![r->writer startWriting])
            failWith(pm::kErrGeneral, "The movie could not be started: %s",
                     r->writer.error ? r->writer.error.localizedDescription.UTF8String : "no reason given");
        [r->writer startSessionAtSourceTime:kCMTimeZero];
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &r->cache) != kCVReturnSuccess) {
            [r->writer cancelWriting];
            fail("Could not make a Metal texture cache for the recording.");
        }
        r->pipeline = makePipeline(@"evmain", @"rfmain", MTLPixelFormatBGRA8Unorm,
                                   pm::internal::blendFor(PM_BLEND_COPY, false, false), &error);
        if (!r->pipeline) {
            [r->writer cancelWriting];
            failWith(pm::kErrPipeline, "The recording pipeline failed: %s", error.localizedDescription.UTF8String);
        }
        r->queue = dispatch_queue_create("PsychMetal recording", DISPATCH_QUEUE_SERIAL);
        // The finished frames must be readable by the GPU, as for readback.
        r->framebufferOnlyBefore = layer.framebufferOnly;
        layer.framebufferOnly = NO;
        heldDrawable = nil;              // taken before: it may not be readable
        try {
            const double began=CACurrentMediaTime();
            if(virtualClock) {recordingClock.begin(began,r->period);if(exportSession)recordingClock.beginSequence(began);}
            if (r->soundInput) {
                PMRecorder *raw = r.get();
                if(virtualClock) {
                    r->offlineAudio=std::make_shared<pm::audio::OfflineAudio>(began,r->soundRate,audioState->session->info.channels);
                    audioOfflineAttach(r->offlineAudio);
                    r->soundThread=std::thread([raw] { @autoreleasepool { offlineSoundMain(raw); } });
                } else {
                    r->tap = std::make_unique<pm::audio::Tap>();
                    r->soundThread = std::thread([raw] { @autoreleasepool { soundMain(raw); } });
                    audioTapAttach(r->tap.get());
                }
            }
        } catch(...) {
            if(virtualClock) { audioOfflineDetach();recordingClock.end(); }
            layer.framebufferOnly=r->framebufferOnlyBefore;
            [r->writer cancelWriting];
            throw;
        }
        std::atomic_store(&recorder, std::move(r));
    }
}

// Replace only a completed export. A failed recording never destroys an
// existing destination, and rename on the same filesystem is atomic.
static void commitRecordedFile(PMRecorder *r) {
    if (std::rename(r->stagingPath.fileSystemRepresentation, r->finalPath.fileSystemRepresentation))
        failWith(pm::kErrGeneral, "Could not replace the movie at %s: %s. The previous file is unchanged.",
                 r->path.c_str(), std::strerror(errno));
    r->stagingPath = nil;
}

// Finish the file; the recorder is gone whatever happens. Throws what went wrong.
static pm::MovieRecording finishRecording(void) {
    @autoreleasepool {
        auto r = std::atomic_exchange(&recorder, std::shared_ptr<PMRecorder>{});
        if (!r) fail("No movie is being recorded.");
        const double logicalStop=r->virtualClock?pm::now():NAN;
        struct EndClock {
            bool active;
            ~EndClock() { if(active) recordingClock.end(); }
        } endClock{r->virtualClock};
        if(r->virtualClock) {
            audioOfflineDetach();
            const double horizon=r->soundHorizon.load();
            if(std::isfinite(horizon)) r->soundHorizon.store(std::max(horizon+r->period,logicalStop));
        }
        closeRecordingAdmission(r.get(),logicalStop);
        {
            std::unique_lock<std::mutex> held(r->mutex);
            if (!r->changed.wait_for(held, std::chrono::seconds(20), [&r] { return r->pending == 0; })) {
                // Completion blocks retain the session; late GPU callbacks cannot
                // touch a freed recorder and release their ownership when done.
                if (r->failure.empty()) r->failure = "Timed out waiting for the last frames to be encoded.";
                held.unlock();
                if (layer) layer.framebufferOnly = r->framebufferOnlyBefore;
                r->soundStop.store(true);
                audioTapDetach(r->tap.get());
                [r->writer cancelWriting];
                if (r->soundThread.joinable()) r->soundThread.join();
                failWith(pm::kErrGeneral, "Timed out waiting for the last frames to be encoded. "
                         "No completed movie was saved to %s; any previous file was preserved.", r->path.c_str());
            }
        }
        if (layer) layer.framebufferOnly = r->framebufferOnlyBefore;
        const int64_t durationTicks=pm::recording::endingTick(logicalStop,r->first,r->lastTick,r->period);
        if (r->soundThread.joinable()) {
            // The sound up to the movie's end has been played (the mixer runs ahead of
            // the clock), and is in the tap or on its way.
            r->endTime.store((double)durationTicks*r->period);
            r->soundStop.store(true);
            r->soundThread.join();
            audioTapDetach(r->tap.get());
            // Detach has acknowledged every callback that could hold the tap.
        }
        pm::MovieRecording out;
        out.path = r->path; out.codec = r->codec; out.virtualClock=r->virtualClock;
        out.width = (double)r->width; out.height = (double)r->height;
        out.frames = (double)r->frames;
        out.refreshes = (double)durationTicks;
        out.refreshHz = 1 / r->period;
        out.duration = out.refreshes * r->period;
        pthread_mutex_lock(&lock);
        for (uint64_t token : r->tokens) {
            Record *q = recordFor(token);
            if (!q || !q->done || !(q->presented > 0)) { out.unreported++; continue; }
            if (q->presented - q->projected > 0.5 * r->period) out.late++;
        }
        pthread_mutex_unlock(&lock);
        out.sound = r->soundInput != nil && r->soundWritten > 0;
        out.soundSeconds = r->soundRate > 0 ? (double)r->soundWritten / r->soundRate : 0;
        out.soundLostSeconds = r->tap && r->soundRate > 0 ? (double)r->tap->lostFrames.load() / r->soundRate : 0;
        if (r->frames && r->failure.empty()) {
            // Virtual mode includes caller waits after the last frame; live mode holds one refresh.
            finishRecordingInput(r.get(),false);
            finishRecordingInput(r.get(),true);
            [r->writer endSessionAtSourceTime:recordingTime(*r, durationTicks)];
            dispatch_semaphore_t finished = dispatch_semaphore_create(0);
            [r->writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
            if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) {
                [r->writer cancelWriting];
                r->failure = "Timed out finishing the movie file.";
            }
        } else {
            [r->writer cancelWriting];
        }
        std::string problem = r->failure;
        if (problem.empty() && r->frames && r->writer.status != AVAssetWriterStatusCompleted)
            problem = std::string("The movie could not be finished: ") +
                      (r->writer.error ? r->writer.error.localizedDescription.UTF8String : "no reason given");
        if (!problem.empty()) failWith(pm::kErrGeneral, "%s No completed movie was saved to %s; any previous file was preserved.", problem.c_str(), r->path.c_str());
        if (!r->frames) fail("No frames were presented while recording; no movie was written.");
        commitRecordedFile(r.get());
        return out;
    }
}

pm::MovieRecording pm::stopMovieRecording() { return finishRecording(); }

// Close finishes a recording, as Stop would, and says so if it could not.
static void closeRecording(void) {
    if (!std::atomic_load(&recorder)) return;
    try { finishRecording(); }
    catch (const std::exception &e) { hookWarn(pm::kWarnRecording, "%s", e.what()); }
}
