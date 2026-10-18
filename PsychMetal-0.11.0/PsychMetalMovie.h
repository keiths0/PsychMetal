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
// from the frame before it that can be decoded alone). After each request the
// queue prepares a bounded lookahead ring, overlapping the caller's drawing and Flip.
#import <CoreVideo/CoreVideo.h>
#include <algorithm>
#include <map>
#include <exception>
#include <memory>

struct PMMovie {
    AVURLAsset *asset = nil;
    AVAssetTrack *video = nil, *sound = nil;
    std::vector<CMTime> syncTimes;
    std::vector<CMTime> times;           // each frame's presentation time, in order
    pm::MovieInfo info;
    double rotation = 0;                 // degrees clockwise the frames are to be shown turned
    dispatch_queue_t queue = nil;        // the reader and the decoded frame belong to this queue
    AVAssetReader *reader = nil;
    AVAssetReaderTrackOutput *output = nil;
    int64_t next = -1;                   // the frame the reader returns next, if it is running
    int64_t decoded = -1;                // the frame in `frame`
    PMTextureRef frame;
    // Keep the requested frame while the worker fills its bounded lookahead.
    // All fields are confined to queue; repeat draws reuse the requested frame.
    PMTextureRef requestedFrame;
    int64_t requested = -1, failedPrefetch = -1;
    std::exception_ptr prefetchFailure;
    size_t cacheCapacity=8;
    bool preloaded=false;
    std::map<int64_t,PMTextureRef> decodedCache;
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
    if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
        fail("Timed out loading movie metadata.");
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
    if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
        fail("Timed out loading movie metadata.");
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
        if(got>index) {CFRelease(sample);fail("The decoder skipped the requested movie frame; refusing to substitute a later frame.");}
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
static PMTextureRef frameOf(std::shared_ptr<PMMovie> owner, int64_t index) {
    __block PMTextureRef out;
    __block std::exception_ptr failure;
    __block bool needsPrefetch=false;
    dispatch_sync(owner->queue, ^{
        @autoreleasepool {
            try {
                needsPrefetch=!owner->preloaded && owner->requested!=index;
                auto cached=owner->decodedCache.find(index);
                if(cached!=owner->decodedCache.end()) {
                    out=cached->second;owner->requested=index;owner->requestedFrame=out;
                }
                else if (owner->requested == index && owner->requestedFrame)
                    out = owner->requestedFrame;
                else {
                    if (owner->failedPrefetch == index && owner->prefetchFailure)
                        std::rethrow_exception(owner->prefetchFailure);
                    out = decodeFrame(*owner, index);
                    owner->requested = index;
                    owner->requestedFrame = out;
                }
            } catch (...) { failure = std::current_exception(); }
        }
    });
    if (failure) std::rethrow_exception(failure);
    // The preceding synchronous job has already drained any earlier prefetch.
    // Repeating a frame or drawing from a full preload needs no worker job.
    if (!needsPrefetch) return out;
    // The current draw can proceed while this queue fills the bounded ring.
    // A following draw synchronizes behind this one job; there is no unbounded
    // producer queue. A repeat draw or a seek never substitutes another frame.
    dispatch_async(owner->queue, ^{
        @autoreleasepool {
            if(owner->preloaded) return;
            for(auto at=owner->decodedCache.begin();at!=owner->decodedCache.end();) {
                if(at->first<index || at->first>=index+(int64_t)owner->cacheCapacity) at=owner->decodedCache.erase(at);
                else ++at;
            }
            owner->decodedCache[index]=out;
            for(int64_t next=index+1;next<std::min<int64_t>(owner->times.size(),index+owner->cacheCapacity);next++) {
                if(owner->decodedCache.count(next)) continue;
                if(owner->failedPrefetch==next && owner->prefetchFailure) break;
                try { owner->decodedCache[next]=decodeFrame(*owner,next); }
                catch(...) {owner->failedPrefetch=next;owner->prefetchFailure=std::current_exception();break;}
            }
        }
    });
    return out;
}

uint64_t pm::openMovie(const std::string &path, pm::MovieInfo &info) {
    if(hdrOutput)fail("Movie decoding is SDR-only; use an SDR window until linear HDR decoding is available.");
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
                    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,false);
                    bool sync=true;
                    if(attachments && CFArrayGetCount(attachments)>0) {
                        auto dictionary=(CFDictionaryRef)CFArrayGetValueAtIndex(attachments,0);
                        sync=CFDictionaryGetValue(dictionary,kCMSampleAttachmentKey_NotSync)!=kCFBooleanTrue;
                    }
                    if(sync) m->syncTimes.push_back(s.presentationTimeStamp);
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
                for (CMTime &t : m->syncTimes) t = CMTimeAdd(t, shift);
                end = CMTimeAdd(end, shift);
            }
        }

        std::sort(m->syncTimes.begin(),m->syncTimes.end(),[](CMTime a,CMTime b){return CMTimeCompare(a,b)<0;});
        if(!m->syncTimes.empty()) {
            int64_t previous=-1,largest=0;
            for(CMTime t:m->syncTimes) {
                const int64_t index=frameAt(*m,t);
                if(index>=0) {if(previous>=0)largest=std::max(largest,index-previous);previous=index;}
            }
            if(previous>=0) largest=std::max(largest,(int64_t)m->times.size()-previous);
            info.keyframeInterval=(double)largest;
        }
        const size_t n = m->times.size();
        double first = CMTimeGetSeconds(m->times.front());
        double span = CMTimeGetSeconds(end) - first;
        std::vector<double> gaps;
        gaps.reserve(n-1);
        for (size_t i = 1; i < n; i++) gaps.push_back(CMTimeGetSeconds(m->times[i]) - CMTimeGetSeconds(m->times[i - 1]));
        double typical = 0;
        if (!gaps.empty()) {
            std::nth_element(gaps.begin(), gaps.begin() + gaps.size() / 2, gaps.end());
            typical = gaps[gaps.size() / 2];
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
        const double decodedBytes=info.width*info.height*4;
        if(!(decodedBytes>0) || decodedBytes>256.0*1024*1024) fail("A decoded movie frame exceeds the 256 MiB automatic buffer budget.");
        m->cacheCapacity=std::max<size_t>(1,std::min<size_t>(8,(size_t)(256.0*1024*1024/decodedBytes)));
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

// Convert with original sample timestamps and every video frame independently
// decodable. This path has independent reader inputs, not a live stimulus clock.
uint64_t pm::transcodeMovie(const std::string &source,const std::string &destination,const std::string &codec) {
    @autoreleasepool {
        NSString *from=[NSString stringWithUTF8String:source.c_str()].stringByExpandingTildeInPath;
        NSString *to=[NSString stringWithUTF8String:destination.c_str()].stringByExpandingTildeInPath;
        if([from.stringByResolvingSymlinksInPath isEqualToString:to.stringByResolvingSymlinksInPath]) fail("Movie conversion needs a different destination path.");
        from=[NSURL fileURLWithPath:from].URLByStandardizingPath.path;
        to=[NSURL fileURLWithPath:to].URLByStandardizingPath.path;
        if([from.stringByResolvingSymlinksInPath isEqualToString:to.stringByResolvingSymlinksInPath]) fail("Movie conversion needs a different destination path.");
        const bool prores=codec=="prores4444"||codec=="prores422";
        AVVideoCodecType type=codec=="h264"?AVVideoCodecTypeH264:codec=="hevc"?AVVideoCodecTypeHEVC:
            codec=="prores4444"?AVVideoCodecTypeAppleProRes4444:codec=="prores422"?AVVideoCodecTypeAppleProRes422:nil;
        if(!type) fail("Conversion codec must be h264, hevc, prores4444 or prores422.");
        NSString *ext=to.pathExtension.lowercaseString;
        AVFileType fileType=[ext isEqualToString:@"mov"]?AVFileTypeQuickTimeMovie:
            [ext isEqualToString:@"mp4"]?AVFileTypeMPEG4:[ext isEqualToString:@"m4v"]?AVFileTypeAppleM4V:nil;
        if(!fileType||(prores&&fileType!=AVFileTypeQuickTimeMovie)) fail("Use .mov for ProRes; .mov, .mp4 or .m4v for H.264/HEVC.");
        auto asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:from] options:nil];
        auto videos=tracksOf(asset,AVMediaTypeVideo);auto sounds=tracksOf(asset,AVMediaTypeAudio);
        if(!videos.count) fail("The source has no video track.");
        auto video=videos.firstObject;
        if(!loadKeys(video,@[@"naturalSize",@"preferredTransform"])) fail("Could not load the source video geometry.");
        const CGSize geometry=video.naturalSize;
        if(!std::isfinite(geometry.width)||!std::isfinite(geometry.height)||geometry.width<1||geometry.height<1||geometry.width>16384||geometry.height>16384)
            fail("Source movie dimensions are invalid or exceed 16384 pixels.");
        NSString *temp=[to stringByAppendingFormat:@".%@.tmp",NSUUID.UUID.UUIDString];
        NSError *error=nil;
        auto reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
        auto writer=[AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:temp] fileType:fileType error:&error];
        struct Cleanup {
            AVAssetReader *reader;AVAssetWriter *writer;NSString *temp;
            ~Cleanup(){[reader cancelReading];if(writer.status==AVAssetWriterStatusWriting)[writer cancelWriting];
                [NSFileManager.defaultManager removeItemAtURL:[NSURL fileURLWithPath:temp] error:nil];}
        } cleanup{reader,writer,temp};
        if(!reader||!writer) fail("Could not create the movie converter.");
        auto videoOut=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:video outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
        videoOut.alwaysCopiesSampleData=NO;[reader addOutput:videoOut];
        NSMutableDictionary *settings=[@{AVVideoCodecKey:type,AVVideoWidthKey:@((int)video.naturalSize.width),AVVideoHeightKey:@((int)video.naturalSize.height)} mutableCopy];
        if(!prores) settings[AVVideoCompressionPropertiesKey]=@{AVVideoMaxKeyFrameIntervalKey:@1,AVVideoAllowFrameReorderingKey:@NO};
        auto videoIn=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
        videoIn.transform=video.preferredTransform;
        if(![writer canAddInput:videoIn]) fail("This system cannot encode the requested all-intra video.");
        [writer addInput:videoIn];
        AVAssetReaderTrackOutput *audioOut=nil;AVAssetWriterInput *audioIn=nil;
        if(sounds.count) {
            auto track=sounds.firstObject;
            if(!loadKeys(track,@[@"formatDescriptions"])) fail("Could not load the source audio format.");
            auto format=(CMAudioFormatDescriptionRef)(__bridge CFTypeRef)track.formatDescriptions.firstObject;
            const auto description=format?CMAudioFormatDescriptionGetStreamBasicDescription(format):nullptr;
            const double rate=description?description->mSampleRate:48000;
            NSDictionary *pcm=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVSampleRateKey:@(rate),AVNumberOfChannelsKey:@2,
                AVLinearPCMBitDepthKey:@32,AVLinearPCMIsFloatKey:@YES,AVLinearPCMIsBigEndianKey:@NO,AVLinearPCMIsNonInterleaved:@NO};
            audioOut=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:pcm];
            audioOut.alwaysCopiesSampleData=NO;[reader addOutput:audioOut];
            NSDictionary *encoded=fileType==AVFileTypeQuickTimeMovie?pcm:@{AVFormatIDKey:@(kAudioFormatMPEG4AAC),AVSampleRateKey:@(rate),AVNumberOfChannelsKey:@2,AVEncoderBitRateKey:@256000};
            audioIn=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:encoded];
            if(![writer canAddInput:audioIn]) fail("Could not encode the movie's audio.");
            [writer addInput:audioIn];
        }
        if(![reader startReading]) failWith(pm::kErrGeneral,"Could not start movie decoding: %s",reader.error?reader.error.localizedDescription.UTF8String:"no reason given");
        if(![writer startWriting]) failWith(pm::kErrGeneral,"Could not start movie encoding: %s",writer.error?writer.error.localizedDescription.UTF8String:"no reason given");
        [writer startSessionAtSourceTime:kCMTimeZero];
        bool videoDone=false,audioDone=!audioIn;uint64_t frames=0;
        double deadline=CACurrentMediaTime()+10;
        while(!videoDone||!audioDone) {
            @autoreleasepool {
                bool progress=false;
                auto append=[&](AVAssetReaderTrackOutput *out,AVAssetWriterInput *input,bool &done,bool count) {
                    if(done||!input.readyForMoreMediaData)return;
                    auto sample=[out copyNextSampleBuffer];
                    if(!sample) {if(reader.status==AVAssetReaderStatusFailed) fail("Movie decoding failed during conversion.");
                        [input markAsFinished];done=true;progress=true;return;}
                    bool ok=[input appendSampleBuffer:sample];CFRelease(sample);
                    if(!ok) failWith(pm::kErrGeneral,"The encoder refused a converted movie sample: %s",writer.error?writer.error.localizedDescription.UTF8String:"no reason given");
                    if(count)++frames;progress=true;
                };
                append(videoOut,videoIn,videoDone,true);if(audioIn)append(audioOut,audioIn,audioDone,false);
                if(writer.status!=AVAssetWriterStatusWriting) fail("Movie conversion encoder failed.");
                if(progress)deadline=CACurrentMediaTime()+10;
                else if(CACurrentMediaTime()>deadline) fail("Movie conversion encoder stopped accepting samples.");
                else usleep(500);
            }
        }
        auto finished=dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(finished);}];
        if(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))||writer.status!=AVAssetWriterStatusCompleted)
            fail("Could not finish the converted movie; the previous destination is unchanged.");
        if(!frames)fail("The source contained no decoded video frames.");
        if(std::rename(temp.fileSystemRepresentation,to.fileSystemRepresentation)) fail("Could not replace the conversion destination; the previous file is unchanged.");
        return frames;
    }
}

uint64_t pm::prepareMovie(uint64_t handle,uint32_t frames,uint64_t maxBytes) {
    auto m=movieFor(handle);
    if(frames>256 || maxBytes<16 || maxBytes>2ull*1024*1024*1024) fail("PrepareMovie needs frames 0..256 and maxBytes 16..2147483648.");
    const uint64_t bytes=(uint64_t)m->info.width*(uint64_t)m->info.height*4;
    const uint64_t wanted=frames?std::min<uint64_t>(frames,m->times.size()):m->times.size();
    if(!bytes || wanted>maxBytes/bytes) fail("The requested decoded movie frames exceed maxBytes; use fewer frames or a larger explicit budget.");
    __block std::exception_ptr failure;__block uint64_t resident=0;
    dispatch_sync(m->queue,^{@autoreleasepool {
        try {
            // Reconfiguration must not retain the previous full cache while
            // constructing another one of the same size. GPU draws keep their
            // own snapshots; decoder internals are outside the pixel budget.
            m->decodedCache.clear();m->requestedFrame.reset();m->requested=-1;
            m->preloaded=false;m->cacheCapacity=wanted;
            std::map<int64_t,PMTextureRef> prepared;
            for(uint64_t i=0;i<wanted;i++) prepared[i]=decodeFrame(*m,i);
            m->decodedCache=std::move(prepared);m->cacheCapacity=wanted;m->preloaded=frames==0;
            m->requested=-1;m->requestedFrame.reset();m->failedPrefetch=-1;m->prefetchFailure=nullptr;
            resident=m->decodedCache.size();
        } catch(...) {failure=std::current_exception();}
    }});
    if(failure) std::rethrow_exception(failure);
    return resident;
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
    memcpy(item->xf, currentXf, sizeof(item->xf));
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
    queueMovieFrame(*m, frameOf(m, (int64_t)index), src, dst, angle, tint, filter);
    texturesDrawn++;
}

// Bound PCM allocation before inserting leading silence or decoded samples.
// At unusual sample rates the duration limit alone can permit gigabytes.
static size_t movieSoundLimit(double rate, uint32_t channels) {
    constexpr size_t memorySamples = (256u * 1024u * 1024u) / sizeof(float);
    return std::min(memorySamples, (size_t)(rate * 1800) * channels);
}
static size_t movieLeadingSilence(double seconds, double rate, uint32_t channels, size_t limit) {
    if (seconds <= 0) return 0;
    const double frames = seconds * rate;
    if (!std::isfinite(frames) || frames > (double)(limit / channels))
        fail("The movie's leading sound silence exceeds the decoded audio limit.");
    return (size_t)std::llround(frames) * channels;
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
        const size_t limit = movieSoundLimit(decodedRate, channels);
        bool first = true;
        for (CMSampleBufferRef sample; (sample = [output copyNextSampleBuffer]); ) {
            struct ReleaseSample {
                CMSampleBufferRef value;
                ~ReleaseSample() { CFRelease(value); }
            } held{sample};
            if (first) {        // a sound that starts after the first frame starts with silence
                first = false;
                double late = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), start));
                if (late > 0) {
                    const size_t silence = movieLeadingSilence(late, decodedRate, channels, limit);
                    out.assign(silence, 0.f);
                }
            }
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
            size_t bytes = block ? CMBlockBufferGetDataLength(block) : 0;
            size_t at = out.size();
            if (bytes / sizeof(float) > limit - at) {
                fail("The movie's decoded sound exceeds 30 minutes or 256 MiB; PsychMetal holds sounds in memory.");
            }
            out.resize(at + bytes / sizeof(float));
            if (bytes && CMBlockBufferCopyDataBytes(block, 0, bytes, out.data() + at) != kCMBlockBufferNoErr) {
                fail("The movie's sound could not be copied.");
            }
        }
        if (reader.status == AVAssetReaderStatusFailed)
            failWith(pm::kErrGeneral, "The movie's sound could not be decoded: %s", reader.error.localizedDescription.UTF8String);
        return out;
    }
}

// A terminal unconfirmed frame must not block reports for every later frame.
// Pending frames wait for their callback; expired/failed frames advance without
// inventing presentation timestamps. Presentations retains the original index.
static void collectMoviePresentations(uint64_t first,uint64_t submitted,uint64_t &reported,pm::timeline::Presentations &shown) {
    while(reported<submitted) {
        double presented=NAN;
        if(reportedPresentation(first+reported,presented)) shown.note(reported,presented);
        else {
            pthread_mutex_lock(&lock);const Record *r=recordFor(first+reported);
            const bool terminal=!r||r->done||(r->status!=0&&r->status!=2);
            pthread_mutex_unlock(&lock);
            if(!terminal) break;
        }
        ++reported;
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

    pm::recording::Sequence sequenceClock(recordingClock,CACurrentMediaTime);
    pm::MovieResult result{};
    result.expectedRefreshHz = 1 / period;
    // The first frame decoded before its refresh is chosen; the next decoded while
    // this one is shown, on the movie's queue.
    PMTextureRef current = frameOf(m, (int64_t)first);
    dispatch_sync(m->queue,^{}); // warm the bounded ring before choosing A/V start
    const double earliest = pm::now() + 3 * period;
    result.start = std::isnan(when) ? gridPointAtOrAfter(earliest) : gridPointForRequest(std::max(when, earliest), earliest);
    if (!std::isfinite(result.start)) result.start = std::isnan(when) ? earliest : std::max(when, earliest);
    if(recordingClock.active()) result.start=recordingClock.align(std::isnan(when)?earliest:std::max(when,earliest));
    if (sound) result.voice = pm::play(sound, result.start, 0, 0, gain, 1);

    pm::timeline::Presentations shown; shown.period = period;
    uint64_t reported = 0;
    auto collect = [&] {
        collectMoviePresentations(result.firstToken,result.submitted,reported,shown);
    };
    static const auto escapeOnly = [] { std::array<bool, 256> f{}; f[40] = true; return f; }();
    try {
        for (uint64_t k = 0; k < count; k++) {
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
            if (k + 1 < count) current = frameOf(m, (int64_t)(first + k + 1));
        }
    } catch (...) {
        for (NSUInteger i = 0; i < drawCount; i++) drawTextureRefs[i].reset();
        drawCount = 0; targetBase = 0; haveLastShape = false;
        throw;
    }
    if (result.cancelled) {
        timelineCancellation.store(false);
        if (result.voice) pm::stopSound(result.voice, NAN);
    }
    if (result.submitted) {
        if(!exportSession) awaitPresentation(result.lastToken, CACurrentMediaTime() + 0.1 + 8 * period);
        collect();
        double presented;
        result.firstPresented = reportedPresentation(result.firstToken, presented) ? presented : NAN;
    }
    if(result.voice && audioState) {
        const auto timing=audioSession().timing(result.voice);
        if(std::isfinite(timing.start)&&std::isfinite(result.firstPresented))
            result.audioStartOffsetMs=1000*(timing.start-result.firstPresented);
        double last=NAN;
        if(timing.finished && reportedPresentation(result.lastToken,last))
            result.audioEndOffsetMs=1000*(timing.end-(last+period));
        if(std::isfinite(result.audioStartOffsetMs)&&std::isfinite(result.audioEndOffsetMs))
            result.audioVideoDriftMs=result.audioEndOffsetMs-result.audioStartOffsetMs;
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
