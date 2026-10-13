// PsychMetal movies: reading, decoding and drawing frames, and playing them.
// SPDX-License-Identifier: MIT
//
// Included by PsychMetalEngine.mm, after the audio engine, on the Mac and the
// iPhone alike. AVFoundation reads the file (any codec it reads: H.264, HEVC,
// ProRes and the rest, in .mov, .mp4 or .m4v); VideoToolbox decodes in hardware;
// CVMetalTextureCache gives Metal the decoded pixel buffer without a copy.
//
// AVAssetReader, not AVPlayer: the reader returns every frame, in order, each
// exactly once, with its own time. AVPlayer follows a clock of its own and drops
// frames to keep up, which a stimulus must never do.
//
// Frames are numbered from 0 by their presentation times, read from the file at
// Open without decoding. A frame is decoded on the movie's own serial queue, where
// the reader lives; drawing the frame that follows the last one decoded continues
// the reader, and any other restarts it at that frame's time (the decoder starts
// from the frame before it that can be decoded alone).
#import <CoreVideo/CoreVideo.h>
#include <algorithm>
#include <map>
#include <memory>

struct PMMovie {
    AVURLAsset *asset = nil;
    AVAssetTrack *video = nil, *sound = nil;
    std::vector<CMTime> times;           // each frame's presentation time, in order
    pm::MovieInfo info;
    double rotation = 0;                 // degrees clockwise the frames are to be shown turned
    dispatch_queue_t queue = nil;        // the reader and the decoded frame belong to this queue
    AVAssetReader *reader = nil;
    AVAssetReaderTrackOutput *output = nil;
    int64_t next = -1;                   // the frame the reader returns next, if it is running
    int64_t decoded = -1;                // the frame in `frame`
    PMTextureRef frame;
    CVMetalTextureCacheRef cache = nullptr;
    ~PMMovie() { if (cache) CFRelease(cache); }
};
static std::map<uint64_t, std::shared_ptr<PMMovie>> movies;
static uint64_t nextMovieHandle = 1;

static std::shared_ptr<PMMovie> movieFor(uint64_t handle) {
    auto found = movies.find(handle);
    if (found == movies.end()) fail("Unknown or closed movie handle.");
    return found->second;
}
// Movies hold textures from the window's device: they end with it.
static void closeMovies(void) { movies.clear(); }

// The frame whose time is t, or -1.
static int64_t frameAt(const PMMovie &m, CMTime t) {
    auto at = std::lower_bound(m.times.begin(), m.times.end(), t,
                               [](const CMTime &a, const CMTime &b) { return CMTimeCompare(a, b) < 0; });
    if (at == m.times.end() || CMTimeCompare(*at, t) != 0) return -1;
    return at - m.times.begin();
}

// Wait for AVFoundation to load what is asked for, synchronously.
static bool loadKeys(id<AVAsynchronousKeyValueLoading> object, NSArray<NSString *> *keys) {
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [object loadValuesAsynchronouslyForKeys:keys completionHandler:^{ dispatch_semaphore_signal(loaded); }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    for (NSString *key in keys)
        if ([object statusOfValueForKey:key error:nil] != AVKeyValueStatusLoaded) return false;
    return true;
}
static NSArray<AVAssetTrack *> *tracksOf(AVAsset *asset, AVMediaType type) {
    __block NSArray<AVAssetTrack *> *found = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:type completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *) {
        found = tracks; dispatch_semaphore_signal(loaded);
    }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    return found;
}

// Decode frame `index` (on the movie's queue). Throws on failure.
static PMTextureRef decodeFrame(PMMovie &m, int64_t index) {
    if (m.decoded == index && m.frame) return m.frame;
    if (!m.reader || m.next < 0 || index < m.next || index - m.next > 120) {
        [m.reader cancelReading];
        NSError *error = nil;
        m.reader = [[AVAssetReader alloc] initWithAsset:m.asset error:&error];
        if (!m.reader) failWith(pm::kErrGeneral, "The movie could not be read: %s", error.localizedDescription.UTF8String);
        NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                   (id)kCVPixelBufferMetalCompatibilityKey: @YES};
        m.output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:m.video outputSettings:settings];
        m.output.alwaysCopiesSampleData = NO;
        [m.reader addOutput:m.output];
        m.reader.timeRange = CMTimeRangeMake(m.times[(size_t)index], kCMTimePositiveInfinity);
        if (![m.reader startReading])
            failWith(pm::kErrGeneral, "The movie could not be decoded: %s", m.reader.error.localizedDescription.UTF8String);
        m.next = index;
    }
    for (;;) {
        CMSampleBufferRef sample = [m.output copyNextSampleBuffer];
        if (!sample) {
            m.next = -1;
            failWith(pm::kErrGeneral, "The movie ended before frame %lld could be decoded%s%s.", (long long)index,
                 m.reader.error ? ": " : "", m.reader.error ? m.reader.error.localizedDescription.UTF8String : "");
        }
        int64_t got = frameAt(m, CMSampleBufferGetPresentationTimeStamp(sample));
        CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
        if (got < 0 || !pixels) { CFRelease(sample); continue; }        // not a frame of the table
        m.next = got + 1;
        if (got < index) { CFRelease(sample); continue; }               // on the way to it
        CVMetalTextureCacheFlush(m.cache, 0);      // release textures of frames no longer held
        CVMetalTextureRef metal = nullptr;
        const size_t w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels);
        CVReturn made = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, m.cache, pixels, nil,
                                                                  MTLPixelFormatBGRA8Unorm, w, h, 0, &metal);
        if (made != kCVReturnSuccess || !metal) { CFRelease(sample); fail("A movie frame could not be given to Metal."); }
        auto resource = std::make_shared<PMTextureResource>();
        resource->texture = CVMetalTextureGetTexture(metal);
        resource->width = w; resource->height = h; resource->channels = 4; resource->bytes = true;
        // The GPU reads the pixel buffer itself: both stay alive as long as the texture.
        resource->keep = (__bridge_transfer id)metal;
        resource->keepSample = (__bridge_transfer id)sample;
        m.frame = resource;
        m.decoded = got;
        return resource;
    }
}
static PMTextureRef frameOf(PMMovie &m, int64_t index) {
    __block PMTextureRef out;
    __block std::string failure;
    PMMovie *movie = &m;
    dispatch_sync(m.queue, ^{
        @autoreleasepool {
            try { out = decodeFrame(*movie, index); }
            catch (const std::exception &e) { failure = e.what(); }
        }
    });
    if (!failure.empty()) failWith(pm::kErrGeneral, "%s", failure.c_str());
    return out;
}

uint64_t pm::openMovie(const std::string &path, pm::MovieInfo &info) {
    @autoreleasepool {
        if (!device || closing) fail("PsychMetal is not open.");
        NSString *file = [NSString stringWithUTF8String:path.c_str()];
        if (!file || ![NSFileManager.defaultManager fileExistsAtPath:file.stringByExpandingTildeInPath])
            failWith(pm::kErrGeneral, "There is no movie at %s.", path.c_str());
        auto m = std::make_shared<PMMovie>();
        m->asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:file.stringByExpandingTildeInPath]
                                       options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
        NSArray<AVAssetTrack *> *videos = tracksOf(m->asset, AVMediaTypeVideo);
        if (!videos.count) failWith(pm::kErrGeneral, "%s has no video track that this system can read.", path.c_str());
        m->video = videos.firstObject;
        if (!loadKeys(m->video, @[@"naturalSize", @"preferredTransform", @"formatDescriptions"]))
            fail("The movie's video track could not be read.");
        NSArray<AVAssetTrack *> *sounds = tracksOf(m->asset, AVMediaTypeAudio);
        if (sounds.count && loadKeys(sounds.firstObject, @[@"formatDescriptions"])) m->sound = sounds.firstObject;

        // The frame table: every frame's time, read without decoding.
        NSError *error = nil;
        AVAssetReader *scan = [[AVAssetReader alloc] initWithAsset:m->asset error:&error];
        if (!scan) failWith(pm::kErrGeneral, "The movie could not be read: %s", error.localizedDescription.UTF8String);
        AVAssetReaderTrackOutput *raw = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:m->video outputSettings:nil];
        raw.alwaysCopiesSampleData = NO;
        [scan addOutput:raw];
        if (![scan startReading]) failWith(pm::kErrGeneral, "The movie could not be read: %s", scan.error.localizedDescription.UTF8String);
        CMTime end = kCMTimeZero;
        for (CMSampleBufferRef sample; (sample = [raw copyNextSampleBuffer]); CFRelease(sample)) {
            @autoreleasepool {
                // A buffer with no samples (a marker, such as the end of a QuickTime
                // track's media) still carries a time; it is not a frame.
                if (CMSampleBufferGetNumSamples(sample) < 1 || CMSampleBufferGetTotalSampleSize(sample) < 1) continue;
                CMItemCount n = 0;
                CMSampleBufferGetSampleTimingInfoArray(sample, 0, nullptr, &n);
                std::vector<CMSampleTimingInfo> timing((size_t)std::max<CMItemCount>(n, 0));
                if (n > 0) CMSampleBufferGetSampleTimingInfoArray(sample, n, timing.data(), &n);
                for (const CMSampleTimingInfo &s : timing) {
                    if (!CMTIME_IS_VALID(s.presentationTimeStamp)) continue;
                    m->times.push_back(s.presentationTimeStamp);
                    CMTime last = CMTimeAdd(s.presentationTimeStamp, CMTIME_IS_VALID(s.duration) ? s.duration : kCMTimeZero);
                    if (CMTimeCompare(last, end) > 0) end = last;
                }
            }
        }
        if (scan.status == AVAssetReaderStatusFailed)
            failWith(pm::kErrGeneral, "The movie could not be read: %s", scan.error.localizedDescription.UTF8String);
        std::sort(m->times.begin(), m->times.end(), [](const CMTime &a, const CMTime &b) { return CMTimeCompare(a, b) < 0; });
        m->times.erase(std::unique(m->times.begin(), m->times.end(),
                                   [](const CMTime &a, const CMTime &b) { return CMTimeCompare(a, b) == 0; }), m->times.end());
        if (m->times.empty()) failWith(pm::kErrGeneral, "%s has no video frames.", path.c_str());
        // The samples' own times can be offset from the times the decoder gives the
        // frames: a movie with B-frames is stored with each frame's time shifted by
        // the reordering delay, which the decoded timeline (the movie's edit list)
        // takes back out. Frames are drawn by the decoder's times, so the table is
        // moved onto them: the first frame decoded fixes the offset.
        {
            AVAssetReader *probe = [[AVAssetReader alloc] initWithAsset:m->asset error:&error];
            if (!probe) failWith(pm::kErrGeneral, "The movie could not be read: %s", error.localizedDescription.UTF8String);
            AVAssetReaderTrackOutput *decoded = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:m->video
                outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
            decoded.alwaysCopiesSampleData = NO;
            [probe addOutput:decoded];
            if (![probe startReading])
                failWith(pm::kErrGeneral, "The movie could not be decoded: %s", probe.error.localizedDescription.UTF8String);
            CMTime firstShown = kCMTimeInvalid;
            for (CMSampleBufferRef sample; !CMTIME_IS_VALID(firstShown) && (sample = [decoded copyNextSampleBuffer]); CFRelease(sample))
                if (CMSampleBufferGetImageBuffer(sample)) firstShown = CMSampleBufferGetPresentationTimeStamp(sample);
            [probe cancelReading];
            if (!CMTIME_IS_VALID(firstShown))
                failWith(pm::kErrGeneral, "%s has no video frame that this system can decode.", path.c_str());
            const CMTime shift = CMTimeSubtract(firstShown, m->times.front());
            if (CMTimeCompare(shift, kCMTimeZero) != 0) {
                for (CMTime &t : m->times) t = CMTimeAdd(t, shift);
                end = CMTimeAdd(end, shift);
            }
        }

        const size_t n = m->times.size();
        double first = CMTimeGetSeconds(m->times.front());
        double span = CMTimeGetSeconds(end) - first;
        std::vector<double> gaps;
        for (size_t i = 1; i < n; i++) gaps.push_back(CMTimeGetSeconds(m->times[i]) - CMTimeGetSeconds(m->times[i - 1]));
        double typical = 0;
        if (!gaps.empty()) {
            std::vector<double> sorted = gaps;
            std::nth_element(sorted.begin(), sorted.begin() + sorted.size() / 2, sorted.end());
            typical = sorted[sorted.size() / 2];
        }
        if (!(span > 0) && typical > 0) span = typical * n;
        info.frames = (double)n;
        info.frameRate = span > 0 ? n / span : 0;
        info.duration = span;
        info.constantRate = true;
        for (double g : gaps) info.constantRate = info.constantRate && typical > 0 && std::fabs(g - typical) <= .001 * typical;
        if (info.constantRate && typical > 0) info.frameRate = 1 / typical;

        CGSize size = m->video.naturalSize;
        CGAffineTransform t = m->video.preferredTransform;
        m->rotation = std::fmod(std::round(std::atan2(t.b, t.a) * 180 / M_PI / 90) * 90 + 360, 360);
        bool sideways = m->rotation == 90 || m->rotation == 270;
        info.width = sideways ? size.height : size.width;
        info.height = sideways ? size.width : size.height;
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)m->video.formatDescriptions.firstObject;
        FourCharCode codec = format ? CMFormatDescriptionGetMediaSubType(format) : 0;
        char code[5] = {(char)(codec >> 24), (char)(codec >> 16), (char)(codec >> 8), (char)codec, 0};
        info.codec = codec ? code : "";
        if (m->sound) {
            CMAudioFormatDescriptionRef audio = (__bridge CMAudioFormatDescriptionRef)m->sound.formatDescriptions.firstObject;
            const AudioStreamBasicDescription *d = audio ? CMAudioFormatDescriptionGetStreamBasicDescription(audio) : nullptr;
            info.soundChannels = d ? d->mChannelsPerFrame : 0;
            info.soundRate = d ? d->mSampleRate : 0;
        }
        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &m->cache) != kCVReturnSuccess)
            fail("Could not make a Metal texture cache for the movie.");
        m->queue = dispatch_queue_create("PsychMetal movie", DISPATCH_QUEUE_SERIAL);
        m->info = info;
        if (nextMovieHandle >= PM_MAX_ID) fail("Movie handle space exhausted.");
        uint64_t handle = nextMovieHandle++;
        movies[handle] = m;
        return handle;
    }
}

std::vector<double> pm::movieFrameTimes(uint64_t handle) {
    auto m = movieFor(handle);
    std::vector<double> out;
    out.reserve(m->times.size());
    for (const CMTime &t : m->times) out.push_back(CMTimeGetSeconds(t));
    return out;
}

static void checkMovieDraw(const PMMovie &m, uint64_t index, const pm::Rect4 &src, const pm::Rect4 &dst,
                           double angle, const pm::Rect4 &tint, int filter) {
    if ((double)index >= m.info.frames) failWith(pm::kErrGeneral, "The movie has %.0f frames, numbered from 0; there is no frame %llu.",
                                             m.info.frames, (unsigned long long)index);
    for (size_t c = 0; c < 4; c++) {
        if (!std::isfinite(src[c]) || src[c] < 0 || src[c] > 1) fail("The source rect is a fraction of the frame, 0 to 1.");
        if (!std::isfinite(dst[c]) || std::fabs(dst[c]) > FLT_MAX) fail("Invalid destination rect.");
        if (!std::isfinite(tint[c]) || tint[c] < 0 || tint[c] > 1) fail("Invalid tint.");
    }
    if (!std::isfinite(angle) || std::fabs(angle) > FLT_MAX) fail("Rotation angle out of range.");
    if (filter != 0 && filter != 1) fail("filter mode must be 0 (nearest) or 1 (linear).");
}
// Queue a decoded frame as a texture item, turned as the movie asks.
static void queueMovieFrame(const PMMovie &m, const PMTextureRef &frame, const pm::Rect4 &src, const pm::Rect4 &dst,
                            double angle, const pm::Rect4 &tint, int filter) {
    if (drawCount >= PM_MAX_SHAPES) fail("Frame draw capacity exceeded; split the work across frames.");
    double l = dst[0], t = dst[1], r = dst[2], b = dst[3];
    if (m.rotation == 90 || m.rotation == 270) {          // the frame is stored on its side
        double cx = (l + r) / 2, cy = (t + b) / 2, hw = (b - t) / 2, hh = (r - l) / 2;
        l = cx - hw; r = cx + hw; t = cy - hh; b = cy + hh;
    }
    // src is a part of the frame as shown; the texture holds it as stored, which is
    // the frame shown turned back by `rotation` degrees (clockwise).
    pm::Rect4 stored = src;
    if (m.rotation == 90) stored = {src[1], 1 - src[2], src[3], 1 - src[0]};
    else if (m.rotation == 180) stored = {1 - src[2], 1 - src[3], 1 - src[0], 1 - src[1]};
    else if (m.rotation == 270) stored = {1 - src[3], src[0], 1 - src[1], src[2]};
    drawTextureRefs[drawCount] = frame;
    pthread_mutex_lock(&lock);
    PMDrawItem *item = &drawList[drawCount++];
    memset(item, 0, sizeof(*item));
    item->type = PM_ITEM_TEXTURE;
    item->texIndex = -1;
    item->blend = blendMode;
    memcpy(item->clip, clipRect, sizeof(item->clip));
    for (int c = 0; c < 4; c++) { item->src[c] = (float)stored[(size_t)c]; item->tint[c] = (float)tint[(size_t)c]; }
    item->dst[0] = (float)l; item->dst[1] = (float)t; item->dst[2] = (float)r; item->dst[3] = (float)b;
    item->angle = (float)((angle + m.rotation) * M_PI / 180);     // the shader turns by radians, clockwise
    item->filterMode = filter;
    pthread_mutex_unlock(&lock);
}

void pm::drawMovieFrame(uint64_t handle, uint64_t index, const pm::Rect4 &src, const pm::Rect4 &dst,
                        double angle, const pm::Rect4 &tint, int filter) {
    if (!device || closing) fail("PsychMetal is not open.");
    auto m = movieFor(handle);
    checkMovieDraw(*m, index, src, dst, angle, tint, filter);
    queueMovieFrame(*m, frameOf(*m, (int64_t)index), src, dst, angle, tint, filter);
    texturesDrawn++;
}

std::vector<float> pm::movieSound(uint64_t handle, double rate, double speed, bool keepPitch, uint32_t &channels) {
    @autoreleasepool {
        auto m = movieFor(handle);
        if (!m->sound) fail("The movie has no sound.");
        if (!(rate >= 8000 && rate <= 384000)) fail("rate must be 8000 to 384000 Hz.");
        if (!(speed >= .25 && speed <= 4)) fail("speed must be 0.25 to 4.");
        channels = (uint32_t)std::min(2.0, std::max(1.0, m->info.soundChannels));
        const bool stretch = keepPitch && speed != 1;
        // Resampling: decoded at rate/speed and played at rate, it lasts 1/speed as
        // long, its pitch moved by `speed`. Stretching: the track is placed in a
        // composition scaled to 1/speed of its length, and the reader's time-pitch
        // algorithm fills that time at the original pitch.
        const double decodedRate = stretch ? rate : rate / speed;
        AVAsset *source = m->asset;
        AVAssetTrack *track = m->sound;
        CMTime start = m->times.front();
        NSError *error = nil;
        if (stretch) {
            if (!loadKeys(m->sound, @[@"timeRange"])) fail("The movie's sound could not be read.");
            AVMutableComposition *composition = [AVMutableComposition composition];
            AVMutableCompositionTrack *t = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                    preferredTrackID:kCMPersistentTrackID_Invalid];
            const CMTimeRange whole = m->sound.timeRange;
            if (!t || ![t insertTimeRange:whole ofTrack:m->sound atTime:whole.start error:&error])
                failWith(pm::kErrGeneral, "The movie's sound could not be stretched: %s",
                         error ? error.localizedDescription.UTF8String : "no composition track");
            const CMTime end = CMTimeRangeGetEnd(whole);
            [composition scaleTimeRange:CMTimeRangeMake(kCMTimeZero, end)
                             toDuration:CMTimeMultiplyByFloat64(end, 1 / speed)];
            source = composition;
            track = t;
            start = CMTimeMultiplyByFloat64(start, 1 / speed);
        }
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:source error:&error];
        if (!reader) failWith(pm::kErrGeneral, "The movie's sound could not be read: %s", error.localizedDescription.UTF8String);
        NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32,
                                   AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsNonInterleaved: @NO,
                                   AVLinearPCMIsBigEndianKey: @NO, AVSampleRateKey: @(decodedRate),
                                   AVNumberOfChannelsKey: @(channels)};
        AVAssetReaderAudioMixOutput *output = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:@[track]
                                                                                        audioSettings:settings];
        if (stretch) output.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
        [reader addOutput:output];
        // From the first frame's time: the movie's sound and its frames share one timeline.
        reader.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);
        if (![reader startReading])
            failWith(pm::kErrGeneral, "The movie's sound could not be decoded: %s", reader.error.localizedDescription.UTF8String);
        std::vector<float> out;
        const size_t limit = (size_t)(decodedRate * 1800) * channels;     // half an hour
        bool first = true;
        for (CMSampleBufferRef sample; (sample = [output copyNextSampleBuffer]); CFRelease(sample)) {
            if (first) {        // a sound that starts after the first frame starts with silence
                first = false;
                double late = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), start));
                if (late > 0) out.assign((size_t)std::llround(late * decodedRate) * channels, 0.f);
            }
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
            size_t bytes = block ? CMBlockBufferGetDataLength(block) : 0;
            size_t at = out.size();
            if (at + bytes / sizeof(float) > limit) {
                CFRelease(sample);
                fail("The movie's sound is longer than half an hour; PsychMetal holds sounds in memory.");
            }
            out.resize(at + bytes / sizeof(float));
            if (bytes && CMBlockBufferCopyDataBytes(block, 0, bytes, out.data() + at) != kCMBlockBufferNoErr) {
                CFRelease(sample); fail("The movie's sound could not be copied.");
            }
        }
        if (reader.status == AVAssetReaderStatusFailed)
            failWith(pm::kErrGeneral, "The movie's sound could not be decoded: %s", reader.error.localizedDescription.UTF8String);
        return out;
    }
}

pm::MovieResult pm::playMovie(uint64_t handle, uint64_t first, uint64_t count, uint32_t refreshes,
                              const pm::Rect4 &src, const pm::Rect4 &dst, double when, uint64_t sound, double gain) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (targetHandle) fail("PlayMovie draws into the window; end drawing into the offscreen window first.");
    auto m = movieFor(handle);
    if (count < 1 || (double)(first + count) > m->info.frames) fail("The frames to play lie outside the movie.");
    if (refreshes < 1 || refreshes > 1000) fail("refreshes per frame must be 1 to 1000.");
    checkMovieDraw(*m, first, src, dst, 0, {1, 1, 1, 1}, 1);
    if (drawCount) fail("PlayMovie draws each frame itself; flip or clear what is queued first.");
    if (!std::isnan(when) && !(std::isfinite(when) && when >= 0)) fail("when must be a GetSecs time, or NaN.");
#if PM_IOS
    iosRequireFront();
#endif
    pthread_mutex_lock(&lock);
    const bool idle = waitQueueIdleLocked();
    const double period = gridPeriod();
    pthread_mutex_unlock(&lock);
    if (!idle) fail("Timed out waiting for queued frames; QueueCancel them before PlayMovie.");

    pm::MovieResult result{};
    result.expectedRefreshHz = 1 / period;
    // The first frame decoded before its refresh is chosen; the next decoded while
    // this one is shown, on the movie's queue.
    PMTextureRef current = frameOf(*m, (int64_t)first);
    const double earliest = CACurrentMediaTime() + 3 * period;
    result.start = gridPointAtOrAfter(std::isnan(when) ? earliest : std::max(when, earliest));
    if (!std::isfinite(result.start)) result.start = std::isnan(when) ? earliest : std::max(when, earliest);
    if (sound) result.voice = pm::play(sound, result.start, 0, 0, gain, 1);

    pm::timeline::Presentations shown; shown.period = period;
    uint64_t reported = 0;
    auto collect = [&] {
        for (double presented; reported < result.submitted && reportedPresentation(result.firstToken + reported, presented); ++reported)
            shown.note(reported, presented);
    };
    static const auto escapeOnly = [] { std::array<bool, 256> f{}; f[40] = true; return f; }();
    // The decode ahead: its result lives in shared state that the block holds.
    struct Ahead { PMTextureRef frame; std::string failure; };
    const auto ahead = std::make_shared<Ahead>();
    PMMovie *movie = m.get();
    dispatch_semaphore_t aheadReady = dispatch_semaphore_create(0);
    bool aheadPending = false;
    auto decodeAhead = [&](int64_t index) {
        aheadPending = true;
        std::shared_ptr<Ahead> state = ahead;
        dispatch_semaphore_t ready = aheadReady;
        dispatch_async(movie->queue, ^{
            @autoreleasepool {
                try { state->frame = decodeFrame(*movie, index); } catch (const std::exception &e) { state->failure = e.what(); }
            }
            dispatch_semaphore_signal(ready);
        });
    };
    auto finishAhead = [&] {
        if (aheadPending) { dispatch_semaphore_wait(aheadReady, DISPATCH_TIME_FOREVER); aheadPending = false; }
    };
    try {
        for (uint64_t k = 0; k < count; k++) {
            if (k + 1 < count) decodeAhead((int64_t)(first + k + 1));
            for (uint32_t r = 0; r < refreshes; r++) {
                bool keys[256] = {};
                readKeyboardState(keys, escapeOnly.data());
                if (timelineCancellation.load() || keys[40]) { result.cancelled = true; break; }
                queueMovieFrame(*m, current, src, dst, 0, {1, 1, 1, 1}, 1);
                texturesDrawn++;
                auto flipped = pm::flip(result.submitted ? 0 : result.start);
                if (!result.submitted) result.firstToken = flipped.token;
                result.lastToken = flipped.token;
                ++result.submitted;
                collect();
            }
            if (result.cancelled) break;
            ++result.frames;
            if (k + 1 < count) {
                finishAhead();
                if (!ahead->failure.empty()) failWith(pm::kErrGeneral, "%s", ahead->failure.c_str());
                current = ahead->frame;
            }
        }
    } catch (...) {
        finishAhead();
        for (NSUInteger i = 0; i < drawCount; i++) drawTextureRefs[i].reset();
        drawCount = 0; targetBase = 0; haveLastShape = false;
        throw;
    }
    finishAhead();
    if (result.cancelled) {
        timelineCancellation.store(false);
        if (result.voice) pm::stopSound(result.voice, NAN);
    }
    if (result.submitted) {
        awaitPresentation(result.lastToken, CACurrentMediaTime() + 0.1 + 8 * period);
        collect();
        double presented;
        result.firstPresented = reportedPresentation(result.firstToken, presented) ? presented : NAN;
    }
    result.shown = shown.shown; result.late = shown.late; result.lateRefreshes = shown.lateRefreshes;
    result.longestIntervalMs = shown.longest * 1000;
    return result;
}

void pm::closeMovie(uint64_t handle) {
    auto found = movies.find(handle);
    if (found == movies.end()) fail("Unknown or closed movie handle.");
    std::shared_ptr<PMMovie> m = found->second;
    movies.erase(found);
    dispatch_sync(m->queue, ^{ [m->reader cancelReading]; });
}
