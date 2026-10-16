// make_test_movie: writes a movie whose every frame carries its own number, with
// AVFoundation (AVAssetWriter), for testing PsychMetal's movie playback, and
// reads it back (AVAssetReader) to check that it says what it should.
//
//   make_test_movie OUT CODEC [WIDTH HEIGHT RATE FRAMES SOUND TURN]
//     CODEC   prores4444 | prores422 | h264 | hevc
//     RATE    frames per second: 30, or a fraction such as 30000/1001
//     SOUND   1: a sound track (440 Hz at 0.2, with a 1 ms click at the start of
//             every second, frame 0 included); 0: none. Default 1.
//     TURN    0, 90, 180 or 270: the track asks to be shown turned that far clockwise,
//             as a phone's portrait video does (the pixels are stored unturned).
//   Defaults: 160 96 30 90 1 0. The file type follows OUT's extension (.mov, .mp4, .m4v).
//
// Frame k: the top half is 16 bars, bar i (from the left) white if bit i of k is
// set, else black, so the number survives lossy coding; the bottom half is one
// colour, red k mod 256, green 255 - k mod 256, blue 64. H.264 and HEVC are
// written with B-frames and a key frame every 15 frames, so decoding in display
// order and from a key frame is exercised; ProRes has every frame a key frame.
//
// Exit 0 when the movie was written and reads back with every frame, in order,
// and its sound the expected length. SPDX-License-Identifier: MIT
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <string>
#include <vector>

static int failed(const char *what, NSError *error = nil) {
    fprintf(stderr, "make_test_movie: %s%s%s\n", what, error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
    for (NSError *cause = error; cause; cause = cause.userInfo[NSUnderlyingErrorKey])
        fprintf(stderr, "  %s (%ld): %s\n", cause.domain.UTF8String, (long)cause.code,
                cause.userInfo.description.UTF8String);
    return 1;
}

static const int kBars = 16;
static void paint(uint8_t *base, size_t stride, int w, int h, int k) {
    for (int y = 0; y < h; y++) {
        uint8_t *row = base + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            uint8_t b, g, r;
            if (y < h / 2) {
                int bar = x * kBars / w;
                uint8_t v = ((k >> bar) & 1) ? 255 : 0;
                b = g = r = v;
            } else {
                r = (uint8_t)(k % 256); g = (uint8_t)(255 - k % 256); b = 64;
            }
            row[4 * x] = b; row[4 * x + 1] = g; row[4 * x + 2] = r; row[4 * x + 3] = 255;
        }
    }
}
// The number in a decoded frame: each bar's centre, on the top quarter's middle row.
static int numberOf(const uint8_t *base, size_t stride, int w, int h) {
    const uint8_t *row = base + (size_t)(h / 4) * stride;
    int k = 0;
    for (int bar = 0; bar < kBars; bar++) {
        int x = (2 * bar + 1) * w / (2 * kBars);
        const uint8_t *p = row + 4 * x;
        if ((p[0] + p[1] + p[2]) / 3 >= 128) k |= 1 << bar;
    }
    return k;
}

static const double kSoundRate = 48000;
static float soundAt(int64_t i) {
    const int64_t inSecond = i % (int64_t)kSoundRate;
    if (inSecond < 48) return .9f;                                   // the click
    return (float)(.2 * std::sin(2 * M_PI * 440 * (double)i / kSoundRate));
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: make_test_movie OUT CODEC [WIDTH HEIGHT RATE FRAMES SOUND TURN]\n"); return 2; }
    NSString *out = [NSString stringWithUTF8String:argv[1]];
    std::string codec = argv[2];
    int w = argc > 3 ? atoi(argv[3]) : 160, h = argc > 4 ? atoi(argv[4]) : 96;
    int64_t rateNum = 30, rateDen = 1;
    if (argc > 5 && sscanf(argv[5], "%lld/%lld", &rateNum, &rateDen) < 1) return failed("RATE must be N or N/D");
    if (rateDen < 1) rateDen = 1;
    int frames = argc > 6 ? atoi(argv[6]) : 90;
    bool sound = argc > 7 ? atoi(argv[7]) != 0 : true;
    int turn = argc > 8 ? atoi(argv[8]) : 0;
    if (turn % 90 || turn < 0 || turn > 270) return failed("TURN must be 0, 90, 180 or 270");
    if (w < 16 || h < 16 || w % 2 || h % 2 || frames < 1 || frames >= (1 << kBars) || rateNum < 1)
        return failed("bad size, rate or frame count");

    NSDictionary<NSString *, AVVideoCodecType> *codecs = @{@"prores4444": AVVideoCodecTypeAppleProRes4444,
        @"prores422": AVVideoCodecTypeAppleProRes422, @"h264": AVVideoCodecTypeH264, @"hevc": AVVideoCodecTypeHEVC};
    AVVideoCodecType type = codecs[[NSString stringWithUTF8String:codec.c_str()]];
    if (!type) return failed("CODEC must be prores4444, prores422, h264 or hevc");
    NSString *ext = out.pathExtension.lowercaseString;
    AVFileType fileType = [ext isEqual:@"mp4"] ? AVFileTypeMPEG4 : [ext isEqual:@"m4v"] ? AVFileTypeAppleM4V : AVFileTypeQuickTimeMovie;
    NSString *staging = [out stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    NSURL *url = [NSURL fileURLWithPath:staging];
    struct Cleanup {
        NSURL *url;
        ~Cleanup() { [NSFileManager.defaultManager removeItemAtURL:url error:nil]; }
    } cleanup{url};

    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:fileType error:&error];
    if (!writer) return failed("cannot write the file", error);
    NSMutableDictionary *video = [@{AVVideoCodecKey: type, AVVideoWidthKey: @(w), AVVideoHeightKey: @(h)} mutableCopy];
    if (type == AVVideoCodecTypeH264 || type == AVVideoCodecTypeHEVC)
        video[AVVideoCompressionPropertiesKey] = @{AVVideoMaxKeyFrameIntervalKey: @15, AVVideoAllowFrameReorderingKey: @YES,
                                                   AVVideoAverageBitRateKey: @(w * h * 30 * 2)};
    AVAssetWriterInput *videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:video];
    videoInput.expectsMediaDataInRealTime = NO;
    videoInput.transform = CGAffineTransformMakeRotation(turn * M_PI / 180);
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
        sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                      (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h)}];
    if (![writer canAddInput:videoInput]) return failed("the writer refuses this codec for this file type");
    [writer addInput:videoInput];

    AVAssetWriterInput *soundInput = nil;
    CMAudioFormatDescriptionRef soundFormat = nullptr;
    const int64_t soundFrames = (int64_t)std::llround(frames * (double)rateDen / rateNum * kSoundRate);
    if (sound) {
        NSDictionary *settings = fileType == AVFileTypeQuickTimeMovie
            ? @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(kSoundRate), AVNumberOfChannelsKey: @2,
                AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsBigEndianKey: @NO,
                AVLinearPCMIsNonInterleaved: @NO}
            : @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(kSoundRate), AVNumberOfChannelsKey: @2,
                AVEncoderBitRateKey: @192000};
        soundInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings];
        soundInput.expectsMediaDataInRealTime = NO;
        if (![writer canAddInput:soundInput]) return failed("the writer refuses the sound track");
        [writer addInput:soundInput];
        AudioStreamBasicDescription d{};
        d.mSampleRate = kSoundRate; d.mFormatID = kAudioFormatLinearPCM;
        d.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        d.mChannelsPerFrame = 2; d.mBitsPerChannel = 32; d.mBytesPerFrame = 8; d.mFramesPerPacket = 1; d.mBytesPerPacket = 8;
        if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &d, 0, nullptr, 0, nullptr, nullptr, &soundFormat))
            return failed("cannot describe the sound");
    }

    if (![writer startWriting]) return failed("cannot start writing", writer.error);
    [writer startSessionAtSourceTime:kCMTimeZero];
    dispatch_group_t done = dispatch_group_create();
    __block int frame = 0;
    __block bool videoFailed = false, videoDone = false, soundDone = false;
    dispatch_group_enter(done);
    [videoInput requestMediaDataWhenReadyOnQueue:dispatch_queue_create("video", DISPATCH_QUEUE_SERIAL) usingBlock:^{
        while (videoInput.readyForMoreMediaData && frame < frames) {
            CVPixelBufferRef buffer = nullptr;
            if (CVPixelBufferPoolCreatePixelBuffer(nullptr, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess) {
                videoFailed = true; frame = frames; break;
            }
            CVPixelBufferLockBaseAddress(buffer, 0);
            paint((uint8_t *)CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer), w, h, frame);
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            if (![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame * rateDen, (int32_t)rateNum)])
                videoFailed = true;
            CVPixelBufferRelease(buffer);
            frame++;
        }
        if (frame >= frames && !videoDone) { videoDone = true; [videoInput markAsFinished]; dispatch_group_leave(done); }
    }];
    __block int64_t written = 0;
    __block bool soundFailed = false;
    if (soundInput) {
        dispatch_group_enter(done);
        [soundInput requestMediaDataWhenReadyOnQueue:dispatch_queue_create("sound", DISPATCH_QUEUE_SERIAL) usingBlock:^{
            while (soundInput.readyForMoreMediaData && written < soundFrames) {
                const int64_t n = std::min<int64_t>(4800, soundFrames - written);
                CMBlockBufferRef block = nullptr;
                if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, (size_t)n * 8, kCFAllocatorDefault,
                                                       nullptr, 0, (size_t)n * 8, kCMBlockBufferAssureMemoryNowFlag, &block)) {
                    soundFailed = true; written = soundFrames; break;
                }
                std::vector<float> samples((size_t)n * 2);
                for (int64_t i = 0; i < n; i++) samples[(size_t)(2 * i)] = samples[(size_t)(2 * i + 1)] = soundAt(written + i);
                CMBlockBufferReplaceDataBytes(samples.data(), block, 0, (size_t)n * 8);
                CMSampleBufferRef sample = nullptr;
                if (CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, soundFormat, (CMItemCount)n,
                        CMTimeMake(written, (int32_t)kSoundRate), nullptr, &sample) || ![soundInput appendSampleBuffer:sample])
                    soundFailed = true;
                if (sample) CFRelease(sample);
                CFRelease(block);
                written += n;
            }
            if (written >= soundFrames && !soundDone) { soundDone = true; [soundInput markAsFinished]; dispatch_group_leave(done); }
        }];
    }
    dispatch_group_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    if (soundFormat) CFRelease(soundFormat);
    if (videoFailed || soundFailed || writer.status != AVAssetWriterStatusCompleted) return failed("writing failed", writer.error);

    // Read it back: every frame, in order, carrying its number.
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    __block NSArray<AVAssetTrack *> *videos = nil, *sounds = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *t, NSError *) { videos = t; dispatch_semaphore_signal(loaded); }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *t, NSError *) { sounds = t; dispatch_semaphore_signal(loaded); }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (videos.count != 1) return failed("the movie read back has no video track");
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) return failed("cannot read the movie back", error);
    AVAssetReaderTrackOutput *frames_ = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videos.firstObject
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    [reader addOutput:frames_];
    AVAssetReaderAudioMixOutput *samples_ = nil;
    if (sound) {
        if (sounds.count != 1) return failed("the movie read back has no sound track");
        samples_ = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:@[sounds.firstObject] audioSettings:@{
            AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsNonInterleaved: @NO, AVLinearPCMIsBigEndianKey: @NO, AVSampleRateKey: @(kSoundRate),
            AVNumberOfChannelsKey: @2}];
        [reader addOutput:samples_];
    }
    if (![reader startReading]) return failed("cannot decode the movie", reader.error);
    int got = 0;
    for (CMSampleBufferRef s; (s = [frames_ copyNextSampleBuffer]); CFRelease(s)) {
        CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(s);
        if (!pixels) continue;
        CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        int k = numberOf((const uint8_t *)CVPixelBufferGetBaseAddress(pixels), CVPixelBufferGetBytesPerRow(pixels),
                         (int)CVPixelBufferGetWidth(pixels), (int)CVPixelBufferGetHeight(pixels));
        CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        if (k != got) { fprintf(stderr, "make_test_movie: frame %d reads back as %d\n", got, k); CFRelease(s); return 1; }
        CMTime t = CMSampleBufferGetPresentationTimeStamp(s);
        if (CMTimeCompare(t, CMTimeMake(got * rateDen, (int32_t)rateNum)) != 0) {
            fprintf(stderr, "make_test_movie: frame %d has time %g\n", got, CMTimeGetSeconds(t)); CFRelease(s); return 1;
        }
        got++;
    }
    if (got != frames) { fprintf(stderr, "make_test_movie: %d frames read back of %d\n", got, frames); return 1; }
    int64_t heard = 0;
    if (samples_)
        for (CMSampleBufferRef s; (s = [samples_ copyNextSampleBuffer]); CFRelease(s))
            heard += (int64_t)CMSampleBufferGetNumSamples(s);
    // AAC is coded in packets of 1024 samples; the reader trims its priming, not its last packet.
    if (sound && (heard < soundFrames - 1 || heard > soundFrames + 1024)) {
        fprintf(stderr, "make_test_movie: %lld sound samples read back of %lld\n", (long long)heard, (long long)soundFrames);
        return 1;
    }
    if (reader.status == AVAssetReaderStatusFailed) return failed("decoding failed", reader.error);
    if (std::rename(staging.fileSystemRepresentation, out.fileSystemRepresentation))
        return failed(std::strerror(errno));
    printf("PASS: %s: %s, %dx%d, %d frames at %lld/%lld per second%s, every frame read back in order with its number.\n",
           argv[1], codec.c_str(), w, h, frames, (long long)rateNum, (long long)rateDen, sound ? ", with sound" : "");
    return 0;
} }
