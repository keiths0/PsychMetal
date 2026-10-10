// Native display-link pacing. Included once by PsychMetalEngine.mm.
// SPDX-License-Identifier: MIT
#import <QuartzCore/CAMetalDisplayLink.h>
#import <Metal/Metal.h>
#include <cmath>

// Only the delegate touches CAMetalDisplayLink. The experiment thread asks for
// ONE fresh update and encodes its draw list after receiving the drawable.
// No host-language code executes on the callback thread; no stale updates queue.
API_AVAILABLE(macos(14.0), ios(17.0))
@interface PMDisplayDriver : NSObject <CAMetalDisplayLinkDelegate> {
    NSCondition *gate;
    NSThread *thread;
    CAMetalLayer *targetLayer;
    CAMetalDisplayLinkUpdate *offered;
    BOOL stopping, finished, ready, requested;
    double earliest, refresh;
}
- (instancetype)initWithLayer:(CAMetalLayer *)metalLayer refresh:(double)hz;
- (CAMetalDisplayLinkUpdate *)nextUpdate:(double)when;
- (void)stop;
@end

@implementation PMDisplayDriver
- (instancetype)initWithLayer:(CAMetalLayer *)metalLayer refresh:(double)hz {
    if ((self = [super init])) {
        gate = [NSCondition new]; targetLayer = metalLayer; refresh = hz;
        thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        thread.name = @"PsychMetal display link";
        thread.qualityOfService = NSQualityOfServiceUserInteractive;
        [thread start];
        [gate lock];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (!ready && !finished && [gate waitUntilDate:deadline]) {}
        BOOL ok = ready;
        [gate unlock];
        if (!ok) { [self stop]; return nil; }
    }
    return self;
}
- (void)run {
    @autoreleasepool {
        CAMetalDisplayLink *link = [[CAMetalDisplayLink alloc] initWithMetalLayer:targetLayer];
        link.delegate = self;
        link.preferredFrameLatency = 2;
        link.preferredFrameRateRange = CAFrameRateRangeMake(refresh, refresh, refresh);
        [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
        [gate lock]; ready = YES; [gate broadcast]; [gate unlock];
        for (;;) {
            [gate lock]; BOOL done = stopping; [gate unlock];
            if (done) break;
            @autoreleasepool {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            }
        }
        [link invalidate]; link.delegate = nil;
        [gate lock]; offered = nil; finished = YES; [gate broadcast]; [gate unlock];
    }
}
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    (void)link;
    [gate lock];
    if (!stopping && requested && !offered &&
        update.targetPresentationTimestamp >= earliest &&
        update.targetPresentationTimestamp > CACurrentMediaTime()) {
        offered = update;
        requested = NO;
        [gate broadcast];
    }
    [gate unlock];
}
- (CAMetalDisplayLinkUpdate *)nextUpdate:(double)when {
    [gate lock];
    earliest = std::max(when, CACurrentMediaTime());
    requested = YES;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:std::max(0.0, when-CACurrentMediaTime())+2.0];
    while (!offered && !stopping && !finished && [gate waitUntilDate:deadline]) {}
    CAMetalDisplayLinkUpdate *result = offered;
    offered = nil; requested = NO;
    [gate unlock];
    return result;
}
- (void)stop {
    [gate lock]; stopping = YES; requested = NO; offered = nil; [gate broadcast];
    while (!finished) [gate wait];
    [gate unlock];
    thread = nil; targetLayer = nil;
}
@end

static PMDisplayDriver *displayDriver API_AVAILABLE(macos(14.0), ios(17.0));
static bool displayLinkPresentation = false;
static void stopDisplayDriver() {
    if (@available(macOS 14.0, iOS 17.0, *)) {
        [displayDriver stop]; displayDriver = nil;
    }
    displayLinkPresentation = false;
}

// Keep the two Metal presentation contracts distinct. Display-link drawables
// reject timed presentation and require rendering to be committed first.
static void commitPresentation(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable,
                               bool linked, double request) {
    if (linked) {
        [cb commit];
        [drawable present];
    } else {
        if (std::isfinite(request)) [cb presentDrawable:drawable atTime:request];
        else [cb presentDrawable:drawable];
        [cb commit];
    }
}
