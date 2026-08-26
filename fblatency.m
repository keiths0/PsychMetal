// fblatency.m — minimal reproducer for CAMetalDisplayLink.preferredFrameLatency
//
// Build:
//   clang -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore \
//         fblatency.m -o fblatency
// Run:
//   ./fblatency 1
//   ./fblatency 2
//
// Prints the median interval from the display-link callback to Apple's predicted
// presentation time, and to Apple's rendering deadline, over 600 frames after a
// 120-frame warm-up. If preferredFrameLatency has an effect, the two runs differ.
//
// SPDX-License-Identifier: MIT

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>
#include <stdlib.h>

// enum, not `static const int` — the latter is not a constant expression in C
// and makes the array declarations below variable-length.
enum { kWarmup = 120, kMeasure = 600, kTotal = kWarmup + kMeasure };

static double gLead[kTotal];        // callback -> targetPresentationTimestamp
static double gDeadline[kTotal];    // callback -> targetTimestamp
static int gCount = 0;
static float gRequested = 1.0f;
static double gIFI = 1.0 / 60.0;
static id<MTLDevice> gDevice;
static id<MTLCommandQueue> gQueue;
static CAMetalLayer *gLayer;
static CAMetalDisplayLink *gLink;
static NSWindow *gWindow;

static int cmpd(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double medianOf(double *v, int n) {
    qsort(v, (size_t)n, sizeof(double), cmpd);
    return v[n / 2];
}

@interface Delegate : NSObject <CAMetalDisplayLinkDelegate, NSApplicationDelegate>
- (void)startLink;
@end

@implementation Delegate

// NOTE: the Objective-C class is CAMetalDisplayLinkUpdate. Apple's documentation
// page shows the Swift spelling CAMetalDisplayLink.Update, which will not compile.
- (void)metalDisplayLink:(CAMetalDisplayLink *)l
             needsUpdate:(CAMetalDisplayLinkUpdate *)u {
    (void)l;
    if (gCount >= kTotal)
        return;

    double now = CACurrentMediaTime();
    gLead[gCount] = u.targetPresentationTimestamp - now;
    gDeadline[gCount] = u.targetTimestamp - now;
    gCount++;

    id<CAMetalDrawable> d = u.drawable;
    if (d) {
        id<MTLCommandBuffer> cb = [gQueue commandBuffer];
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture = d.texture;
        p.colorAttachments[0].loadAction = MTLLoadActionClear;
        p.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:p];
        [e endEncoding];
        [cb presentDrawable:d];
        [cb commit];
    }

    if (gCount == kTotal) {
        // Median of each series independently; the third line is the difference
        // of the two medians, not the median of the differences.
        double lead = medianOf(gLead + kWarmup, kMeasure);
        double deadline = medianOf(gDeadline + kWarmup, kMeasure);
        printf("\n");
        printf("requested preferredFrameLatency : %.1f\n", gRequested);
        printf("readback                        : %.1f\n", gLink.preferredFrameLatency);
        printf("drawable size                   : %.0f x %.0f\n",
               gLayer.drawableSize.width, gLayer.drawableSize.height);
        printf("refresh interval used           : %.6f ms\n", gIFI * 1000.0);
        printf("callback -> targetTimestamp     : %8.3f ms (%.4f refreshes)\n",
               deadline * 1000.0, deadline / gIFI);
        printf("callback -> targetPresentation  : %8.3f ms (%.4f refreshes)\n",
               lead * 1000.0, lead / gIFI);
        printf("deadline -> targetPresentation  : %8.3f ms (%.4f refreshes)\n",
               (lead - deadline) * 1000.0, (lead - deadline) / gIFI);
        printf("\n");
        fflush(stdout);
        [NSApp terminate:nil];
    }
}

- (void)startLink {
    // Started only after the fullscreen transition completes, so drawableSize
    // matches the final fullscreen geometry exactly and no scaling occurs.
    NSView *v = gWindow.contentView;
    gLayer.contentsScale = gWindow.backingScaleFactor;
    gLayer.frame = v.bounds;
    gLayer.drawableSize = CGSizeMake(v.bounds.size.width * gLayer.contentsScale,
                                     v.bounds.size.height * gLayer.contentsScale);

    gLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:gLayer];
    gLink.delegate = self;
    gLink.preferredFrameLatency = gRequested;
    double hz = 1.0 / gIFI;
    gLink.preferredFrameRateRange = CAFrameRateRangeMake(hz, hz, hz);
    [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    gLink.paused = NO;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    NSScreen *screen = NSScreen.mainScreen;

    CGDirectDisplayID did =
        (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
    double hz = mode ? CGDisplayModeGetRefreshRate(mode) : 0.0;
    if (mode)
        CGDisplayModeRelease(mode);
    if (hz > 0.0)
        gIFI = 1.0 / hz;

    gDevice = MTLCreateSystemDefaultDevice();
    if (!gDevice) {
        fprintf(stderr, "No Metal device.\n");
        exit(1);
    }
    gQueue = [gDevice newCommandQueue];

    gWindow = [[NSWindow alloc] initWithContentRect:screen.frame
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO
                                             screen:screen];
    gWindow.releasedWhenClosed = NO;
    gWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    gWindow.animationBehavior = NSWindowAnimationBehaviorNone;

    NSView *v = [[NSView alloc] initWithFrame:gWindow.contentView.bounds];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    v.wantsLayer = YES;

    gLayer = [CAMetalLayer layer];
    gLayer.device = gDevice;
    gLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    gLayer.opaque = YES;
    gLayer.framebufferOnly = YES;
    gLayer.displaySyncEnabled = YES;
    gLayer.maximumDrawableCount = 2;
    gLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    v.layer = gLayer;
    gWindow.contentView = v;

    [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidEnterFullScreenNotification
                    object:gWindow
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    [self startLink];
                }];

    [gWindow makeKeyAndOrderFront:nil];
    [gWindow toggleFullScreen:nil];
}
@end

int main(int argc, const char *argv[]) {
    if (argc > 1)
        gRequested = (float)atof(argv[1]);
    if (gRequested != 1.0f && gRequested != 2.0f) {
        fprintf(stderr, "usage: %s [1|2]   (Apple accepts only 1.0 or 2.0)\n", argv[0]);
        return 2;
    }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        Delegate *dg = [Delegate new];
        NSApp.delegate = dg;   // weak; dg stays alive for the scope of [NSApp run]
        [NSApp run];
    }
    return 0;
}
