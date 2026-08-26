# Filing the `preferredFrameLatency` report with Apple

## Where

Feedback Assistant, either the app (Spotlight for "Feedback Assistant", it's built into macOS) or
[feedbackassistant.apple.com](https://feedbackassistant.apple.com). Filing requires an Apple
Developer account, Beta Software Program membership, or AppleSeed for IT. The app is preferable
to the website because it automatically attaches time-sensitive diagnostic data at submission.

**Area:** *Developer Technologies & SDKs* — Apple's guidance is to use this topic for feedback
about a specific framework or API, which is exactly what this is. Name QuartzCore /
`CAMetalDisplayLink` in the title and body so it routes to the right team.

**File one issue per report.** Apple states this explicitly, so this is two submissions:
a bug for the non-functional property, and a separate enhancement request for the missing
readback. Cross-reference them by FB number once you have the first one.

---

## The prerequisite that determines whether this goes anywhere

**A minimal reproducer that does not involve Octave, MATLAB, or Psychtoolbox.** If an Apple
engineer has to install a numerical computing environment and a psychophysics toolbox to see
your bug, the report will be closed unresolved. It needs to be one file, one `clang` command,
no Xcode project.

The skeleton below is the shape it should take — a fullscreen `CAMetalLayer`, a
`CAMetalDisplayLink`, a trivial clear-and-present, and one printed number. Complete and verify
it before filing; the numbers it produces should match what PsychMetal reports.

```objc
// fblatency.m
// clang -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore \
//     fblatency.m -o fblatency
// Usage: ./fblatency 1     (or 2)

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>

static const int kWarmup = 120, kMeasure = 600;
static double gLead[kWarmup + kMeasure];
static int gCount = 0;
static float gRequested = 1.0f;
static id<MTLDevice> gDevice;
static id<MTLCommandQueue> gQueue;
static CAMetalLayer *gLayer;
static CAMetalDisplayLink *gLink;
static NSWindow *gWindow;

static int cmpd(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

@interface Delegate : NSObject <CAMetalDisplayLinkDelegate, NSApplicationDelegate>
@end

@implementation Delegate

- (void)metalDisplayLink:(CAMetalDisplayLink *)l needsUpdate:(CAMetalDisplayLink.Update *)u {
    if (gCount >= kWarmup + kMeasure) return;

    gLead[gCount++] = u.targetPresentationTimestamp - CACurrentMediaTime();

    id<CAMetalDrawable> d = u.drawable;
    if (d) {
        id<MTLCommandBuffer> cb = [gQueue commandBuffer];
        MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture     = d.texture;
        p.colorAttachments[0].loadAction  = MTLLoadActionClear;
        p.colorAttachments[0].clearColor  = MTLClearColorMake(0.1, 0.1, 0.1, 1.0);
        p.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:p] endEncoding];
        [cb presentDrawable:d];
        [cb commit];
    }

    if (gCount == kWarmup + kMeasure) {
        double ifi = 1.0 / 60.0;   // set from CGDisplayModeGetRefreshRate for other displays
        qsort(gLead + kWarmup, kMeasure, sizeof(double), cmpd);
        double median = gLead[kWarmup + kMeasure / 2];
        printf("requested preferredFrameLatency = %.1f\n", gRequested);
        printf("readback                        = %.1f\n", gLink.preferredFrameLatency);
        printf("median callback->present lead   = %.3f ms = %.4f refreshes\n",
               median * 1000.0, median / ifi);
        [NSApp terminate:nil];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSScreen *screen = NSScreen.mainScreen;
    gDevice = MTLCreateSystemDefaultDevice();
    gQueue  = [gDevice newCommandQueue];

    gWindow = [[NSWindow alloc] initWithContentRect:screen.frame
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO
                                             screen:screen];
    gWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    gWindow.animationBehavior  = NSWindowAnimationBehaviorNone;

    NSView *v = [[NSView alloc] initWithFrame:gWindow.contentView.bounds];
    v.wantsLayer = YES;
    gLayer = [CAMetalLayer layer];
    gLayer.device              = gDevice;
    gLayer.pixelFormat         = MTLPixelFormatBGRA8Unorm;
    gLayer.opaque              = YES;
    gLayer.framebufferOnly     = YES;
    gLayer.displaySyncEnabled  = YES;
    gLayer.maximumDrawableCount = 2;
    gLayer.contentsScale       = gWindow.backingScaleFactor;
    gLayer.frame               = v.bounds;
    gLayer.drawableSize        = CGSizeMake(v.bounds.size.width  * gLayer.contentsScale,
                                            v.bounds.size.height * gLayer.contentsScale);
    v.layer = gLayer;
    gWindow.contentView = v;
    [gWindow makeKeyAndOrderFront:nil];
    [gWindow toggleFullScreen:nil];

    gLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:gLayer];
    gLink.delegate = self;
    gLink.preferredFrameLatency = gRequested;
    gLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    gLink.paused = NO;
}
@end

int main(int argc, const char *argv[]) {
    if (argc > 1) gRequested = (float)atof(argv[1]);
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        Delegate *dg = [Delegate new];
        NSApp.delegate = dg;
        [NSApp run];
    }
    return 0;
}
```

Run it as `./fblatency 1` and `./fblatency 2`. If the median lead is identical, you have the
bug in a form Apple can act on. Attach the source file and both outputs.

---

## Report 1 — the bug

**Title**

> CAMetalDisplayLink.preferredFrameLatency has no effect on presentation scheduling on macOS

**Description**

> `CAMetalDisplayLink.preferredFrameLatency` is documented as "the amount of time, in frames,
> your app requests to render a frame," with only 1.0 and 2.0 accepted. On macOS 27.0 beta on Apple
> silicon, setting this property to 1.0 or 2.0 produces no observable difference in
> presentation scheduling. The property reads back the assigned value correctly, but the
> interval between the display-link callback and the predicted presentation time
> (`CAMetalDisplayLink.Update.targetPresentationTimestamp`) is unchanged.
>
> The documentation notes that "the final latency may be bigger if the system needs more time,
> such as for windowed modes on macOS." The measurements below were taken in native fullscreen
> on a single opaque, `framebufferOnly` `CAMetalLayer` whose `drawableSize` exactly matches the
> display mode, with no colour-space conversion — i.e. not a windowed mode. The observed latency
> is fixed at approximately three refresh intervals regardless of the requested value.
>
> Notably, the same application achieves an approximately two-refresh horizon when its bundle
> declares `LSApplicationCategoryType = public.app-category.games` with `GCSupportsGameMode`
> and `LSSupportsGameMode` (a diagnostic manipulation, not a shipping configuration). This
> demonstrates that a shorter horizon is achievable on this hardware and display, but it is
> not reachable through the documented API. Even in that configuration,
> `preferredFrameLatency` 1.0 versus 2.0 remains inert.

**Steps to reproduce**

> 1. Build the attached single-file reproducer:
>    `clang -fobjc-arc -framework Cocoa -framework Metal -framework QuartzCore fblatency.m -o fblatency`
> 2. Run `./fblatency 1` on a 60 Hz display. Note the median callback-to-presentation lead.
> 3. Run `./fblatency 2`. Note the median lead.
> 4. Compare.

**Expected**

> The median callback-to-presentation lead should differ between the two runs by approximately
> one refresh interval, reflecting the requested change in frame latency.

**Actual**

> The median lead is identical to within measurement noise in both runs. The property reads
> back as 1.0 and 2.0 respectively, so the assignment is accepted, but behaviour does not change.

**Measurements**

> M4 MacBook Air, internal display, 60 Hz (measured 59.99991 Hz), macOS 27.0 beta.
> Median interval from display-link callback to `targetPresentationTimestamp`, 600 measured
> frames after 120 warm-up frames, repeated in an ABA design:
>
> | Configuration | Requested latency | Max drawables | Median lead |
> | --- | --- | --- | --- |
> | Standard bundle | 1.0 | 2 | 49.922 ms (2.995 refreshes) |
> | Standard bundle | 1.0 | 3 | 49.946 ms (2.997) |
> | Standard bundle | 2.0 | 2 | 49.942 ms (2.997) |
> | Standard bundle | 2.0 | 3 | 49.943 ms (2.997) |
> | Game-mode-declaring bundle | 1.0 | 2 | 33.28 ms (1.997) |
> | Game-mode-declaring bundle | 2.0 | 2 | 33.30 ms (1.998) |
>
> Decomposition: the interval from the callback to `targetTimestamp` (the documented rendering
> deadline) is approximately 16.53 ms — one refresh — in every configuration. The entire
> difference lies in the interval from the rendering deadline to predicted presentation, which
> is approximately 33.4 ms in the standard bundle and 16.7 ms in the game-mode-declaring bundle.
>
> `maximumDrawableCount` of 2 versus 3 also produced no measurable difference.

**Attachments**

- `fblatency.m` and the console output of both runs
- sysdiagnose (let the Feedback Assistant app capture it)
- The measurement table above as a CSV if you have it

---

## Report 2 — the enhancement request

**Title**

> Request: API to query the effective frame latency granted to a CAMetalDisplayLink

**Description**

> `CAMetalDisplayLink.preferredFrameLatency` documents that "the final latency may be bigger if
> the system needs more time." There is currently no way for an application to discover what
> latency it was actually granted — reading the property back returns the requested value, not
> the effective one.
>
> For applications with hard presentation-timing requirements this is a significant gap: the
> only way to determine the actual scheduling horizon is to measure it empirically over many
> frames by comparing `targetPresentationTimestamp` against confirmed
> `MTLDrawable.presentedTime`, which requires a warm-up period and cannot distinguish a
> system-imposed floor from a transient condition.
>
> Requesting either a read-only `effectiveFrameLatency` property, or an indication on
> `CAMetalDisplayLink.Update` of the latency applying to that update.
>
> Context: this arises in vision-science stimulus presentation, where the presentation
> pipeline depth must be known rather than estimated. Related to FB<number from Report 1>.

---

## Also worth doing

**Post it on the Apple Developer Forums**, Graphics & Games area, with the FB number in the
text. Feedback Assistant reports frequently go unacknowledged; forum threads with a concrete
reproducer and an FB number sometimes get an engineer's attention, and the FB number gives them
something to look up.

**Keep the Game Mode framing minimal and factual.** It is your strongest evidence — it proves
the shorter horizon is achievable on this hardware — but describe it as a diagnostic
manipulation in one sentence and move on. Don't editorialise about compositing, since Apple
does not document what occupies that interval and speculating weakens the report.

**Report the ABA design.** Two baselines differing by 0.025 ms around a 16.6 ms effect is what
makes this credible rather than anecdotal. It is unusual for a bug report to include a control
condition and it will be noticed.

---

## Sources

- [Feedback Assistant — Apple Developer](https://developer.apple.com/feedback-assistant/)
- [Intro to Feedback Assistant on Mac — Apple Support](https://support.apple.com/guide/feedback-assistant/intro-to-feedback-assistant-fba2e39e53f5/mac)
- [How to file great bug reports — Apple Developer](https://developer.apple.com/news/?id=vvrgkboh)
- [CAMetalDisplayLink.preferredFrameLatency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency)
