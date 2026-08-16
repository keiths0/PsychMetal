#define GL_SILENCE_DEPRECATION
#include "mex.h"
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <pthread.h>

#define NREC 16384
typedef struct {
    uint64_t token, tick;
    int status, done, gpuDone, scheduled, submitted, commandStatus;
    double rawTarget, projected, scheduledAt, presented, callback;
} Record;
static NSWindow *metalWindow;
static CAMetalLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static IOSurfaceRef surfaces[2];
static id<MTLTexture> textures[2];
static GLuint gltex[2], originalTexture;
static GLuint ptbFbo;
static GLenum textureTarget;
static id<MTLRenderPipelineState> pipeline;
static id<MTLSamplerState> sampler;
static double ifi, lastTargetErrorMs, lastConfirmDelayMs;
static NSUInteger renderWidth, renderHeight;
static uint64_t ticks, nextToken, confirmedCount, missingPresentedCount;
static int lagEstimateFrames, lagCandidateFrames, lagCandidateCount;
static NSInteger selectedScreenIndex = -1;
static CGDirectDisplayID selectedDisplayID = 0;
static Record rec[NREC];
static int pendingBuffer = -1;
static uint64_t pendingToken, pendingTargetTick, lastTargetTick;
static uint64_t lastBufferToken[2];
static bool closing = true;
static int activeLinkCallbacks;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static void waitBuffer(int b);
static void onMainSync(dispatch_block_t block) {
    if (pthread_main_np())
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

@interface PMDriver : NSObject <CAMetalDisplayLinkDelegate>
@property CAMetalDisplayLink *link;
@end
static PMDriver *driver;
static Record *recordFor(uint64_t token) {
    Record *r = &rec[token % NREC];
    return (r->token == token) ? r : NULL;
}

@implementation PMDriver
- (void)metalDisplayLink:(CAMetalDisplayLink *)l needsUpdate:(CAMetalDisplayLinkUpdate *)u {
    (void)l;
    pthread_mutex_lock(&lock);
    if (closing) {
        pthread_mutex_unlock(&lock);
        return;
    }
    ticks++;
    if (pendingBuffer < 0 || ticks < pendingTargetTick) {
        pthread_mutex_unlock(&lock);
        return;
    }
    int b = pendingBuffer;
    uint64_t token = pendingToken;
    activeLinkCallbacks++;
    pendingBuffer = -1;
    Record *r = recordFor(token);
    if (r) {
        r->tick = ticks;
        r->rawTarget = u.targetPresentationTimestamp;
        r->projected = r->rawTarget + lagEstimateFrames * ifi;
        r->scheduledAt = CACurrentMediaTime();
        r->scheduled = 1;
    }
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    id<CAMetalDrawable> d = u.drawable;
    if (!d) {
        pthread_mutex_lock(&lock);
        r = recordFor(token);
        if (r) {
            r->status = 2;
            r->done = 1;
        }
        activeLinkCallbacks--;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        return;
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = d.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    [re setRenderPipelineState:pipeline];
    [re setFragmentTexture:textures[b] atIndex:0];
    [re setFragmentSamplerState:sampler atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    [d addPresentedHandler:^(id<MTLDrawable> x) {
        double pt = x.presentedTime, ct = CACurrentMediaTime();
        pthread_mutex_lock(&lock);
        Record *q = recordFor(token);
        if (q) {
            q->presented = pt;
            q->callback = ct;
            q->status = (pt > 0) ? 0 : 1;
            q->done = 1;
            if (pt > 0) {
                confirmedCount++;
                lastTargetErrorMs = (pt - q->projected) * 1000.0;
                lastConfirmDelayMs = (ct - pt) * 1000.0;
                int observed = (int)llround((pt - q->rawTarget) / ifi);
                if (observed < 0)
                    observed = 0;
                if (observed > 3)
                    observed = 3;
                if (observed == lagCandidateFrames)
                    lagCandidateCount++;
                else {
                    lagCandidateFrames = observed;
                    lagCandidateCount = 1;
                }
                if (lagCandidateCount >= 3)
                    lagEstimateFrames = lagCandidateFrames;
            } else
                missingPresentedCount++;
        }
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
    }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> x) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(token);
        if (q) {
            q->commandStatus = (int)x.status;
            q->gpuDone = 1;
            if (x.status == MTLCommandBufferStatusError && !q->done) {
                q->status = 3;
                q->done = 1;
            }
        }
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
    }];
    [cb presentDrawable:d];
    [cb commit];
    pthread_mutex_lock(&lock);
    r = recordFor(token);
    if (r)
        r->submitted = 1;
    activeLinkCallbacks--;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
}
@end

static bool cmd(const mxArray *a, const char *s) {
    char b[64];
    if (!mxIsChar(a))
        return false;
    mxGetString(a, b, sizeof(b));
    return strcasecmp(b, s) == 0;
}
static void fail(const char *s) { mexErrMsgIdAndTxt("PsychMetal:Error", "%s", s); }
static struct timespec deadline(double sec) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    long n = t.tv_nsec + (long)(sec * 1e9);
    t.tv_sec += n / 1000000000;
    t.tv_nsec = n % 1000000000;
    return t;
}
static bool transitionFullscreen(bool enter) {
    if (!metalWindow)
        return true;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id observer = nil;
    NSNotificationName name =
        enter ? NSWindowDidEnterFullScreenNotification : NSWindowDidExitFullScreenNotification;
    onMainSync(^{
        observer = [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                                     object:metalWindow
                                                                      queue:nil
                                                                 usingBlock:^(NSNotification *n) {
                                                                     (void)n;
                                                                     dispatch_semaphore_signal(sem);
                                                                 }];
        [metalWindow toggleFullScreen:nil];
    });
    bool completed = false;
    if (pthread_main_np()) {
        // toggleFullScreen completes asynchronously on AppKit's main run loop.
        // Pump that loop when a MATLAB MEX call itself owns the main thread;
        // blocking it on the semaphore would prevent the notification.
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5.0];
        do {
            completed = dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW) == 0;
            if (!completed)
                [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        } while (!completed && limit.timeIntervalSinceNow > 0);
    } else {
        completed = dispatch_semaphore_wait(
                        sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    }
    onMainSync(^{
        if (observer)
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
    });
    return completed;
}
static void closeCore(void) {
    // Prevent new display-link work before invalidating the link. A callback
    // already encoding a frame is allowed to finish before resources vanish.
    pthread_mutex_lock(&lock);
    closing = true;
    pendingBuffer = -1;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    if (driver)
        onMainSync(^{
            driver.link.paused = YES;
            [driver.link invalidate];
            driver.link = nil;
            driver = nil;
        });
    pthread_mutex_lock(&lock);
    struct timespec callbackDeadline = deadline(2);
    while (activeLinkCallbacks > 0)
        if (pthread_cond_timedwait(&cond, &lock, &callbackDeadline) == ETIMEDOUT)
            break;
    // Completion and presented handlers also touch the record ring. Drain
    // submitted frames before a later Open clears and reuses those records.
    struct timespec gpuDeadline = deadline(2);
    for (;;) {
        bool inFlight = false;
        uint64_t start = (nextToken > NREC) ? nextToken - NREC : 1;
        for (uint64_t token = start; token < nextToken; token++) {
            Record *r = recordFor(token);
            if (r && r->submitted && (!r->gpuDone || !r->done)) {
                inFlight = true;
                break;
            }
        }
        if (!inFlight)
            break;
        if (pthread_cond_timedwait(&cond, &lock, &gpuDeadline) == ETIMEDOUT)
            break;
    }
    pthread_mutex_unlock(&lock);
    __block bool isFullscreen = false;
    if (metalWindow)
        onMainSync(^{
            isFullscreen = (metalWindow.styleMask & NSWindowStyleMaskFullScreen) != 0;
        });
    if (isFullscreen && !transitionFullscreen(false))
        mexWarnMsgIdAndTxt(
            "PsychMetal:FullscreenExit",
            "Timed out waiting for native fullscreen exit; forcing the presentation window hidden.");
    if (metalWindow)
        onMainSync(^{
            metalWindow.ignoresMouseEvents = YES;
            [metalWindow resignKeyWindow];
            [metalWindow orderOut:nil];
            [metalWindow close];
            metalWindow = nil;
        });
    if (CGLGetCurrentContext()) {
        if (ptbFbo) {
            glBindFramebuffer(GL_FRAMEBUFFER, ptbFbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, textureTarget, originalTexture, 0);
        }
        if (gltex[0])
            glDeleteTextures(2, gltex);
    }
    ptbFbo = 0;
    originalTexture = 0;
    memset(gltex, 0, sizeof(gltex));
    textures[0] = textures[1] = nil;
    pipeline = nil;
    sampler = nil;
    for (int i = 0; i < 2; i++) {
        if (surfaces[i])
            CFRelease(surfaces[i]);
        surfaces[i] = NULL;
    }
    queue = nil;
    device = nil;
    layer = nil;
}
static IOSurfaceRef makeSurface(size_t w, size_t h) {
    size_t row = (w * 4 + 63) & ~63ULL;
    NSDictionary *p = @{
        (id)kIOSurfaceWidth : @(w),
        (id)kIOSurfaceHeight : @(h),
        (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfaceBytesPerRow : @(row),
        (id)kIOSurfacePixelFormat : @(0x42475241)
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)p);
}
static void openCore(NSUInteger w, NSUInteger h, double period, GLenum target, GLuint tex0,
                     NSInteger screenIndex, double globalLeft, double globalTop, double globalRight,
                     double globalBottom) {
    closeCore();
    CGLContextObj c = CGLGetCurrentContext();
    if (!c)
        fail("No current PTB OpenGL context.");
    GLint capturedFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &capturedFbo);
    if (capturedFbo <= 0)
        fail("PTB offscreen framebuffer was not selected before Open.");
    ptbFbo = (GLuint)capturedFbo;
    device = MTLCreateSystemDefaultDevice();
    if (!device)
        fail("No Metal device.");
    queue = [device newCommandQueue];
    if (!queue)
        fail("Could not create a Metal command queue.");
    onMainSync(^{
        NSArray<NSScreen *> *screens = NSScreen.screens;
        NSScreen *primary = screens.count ? screens[0] : NSScreen.mainScreen;
        double mainTop = NSMaxY(primary.frame);
        NSRect wanted = NSMakeRect(globalLeft, mainTop - globalBottom, globalRight - globalLeft,
                                   globalBottom - globalTop);
        NSScreen *screen = nil;
        selectedScreenIndex = -1;
        for (NSUInteger i = 0; i < screens.count; i++) {
            NSRect f = screens[i].frame;
            if (fabs(NSMinX(f) - NSMinX(wanted)) < 1.0 && fabs(NSMinY(f) - NSMinY(wanted)) < 1.0 &&
                fabs(NSWidth(f) - NSWidth(wanted)) < 1.0 && fabs(NSHeight(f) - NSHeight(wanted)) < 1.0) {
                screen = screens[i];
                selectedScreenIndex = (NSInteger)i;
                break;
            }
        }
        if (!screen && screenIndex >= 0 && screenIndex < (NSInteger)screens.count) {
            screen = screens[(NSUInteger)screenIndex];
            selectedScreenIndex = screenIndex;
            mexWarnMsgIdAndTxt(
                "PsychMetal:DisplayMapping",
                "Could not match PTB's global display rectangle exactly; using AppKit display index %ld.",
                (long)screenIndex);
        }
        if (!screen) {
            screen = NSScreen.mainScreen;
            selectedScreenIndex = 0;
            mexWarnMsgIdAndTxt("PsychMetal:DisplayMapping",
                               "Could not identify the requested display; using the main display.");
        }
        selectedDisplayID = (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        // Native fullscreen always starts from a borderless display-sized window.
        metalWindow = [[NSWindow alloc] initWithContentRect:screen.frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO
                                                     screen:screen];
        metalWindow.releasedWhenClosed = NO;
        metalWindow.animationBehavior = NSWindowAnimationBehaviorNone;
        metalWindow.title = @"PsychMetal direct offscreen presenter";
        metalWindow.level = NSNormalWindowLevel;
        metalWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        NSView *view = [[NSView alloc] initWithFrame:metalWindow.contentView.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.wantsLayer = YES;
        layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.opaque = YES;
        layer.framebufferOnly = YES;
        layer.displaySyncEnabled = YES;
        layer.maximumDrawableCount = 2;
        layer.contentsScale = metalWindow.backingScaleFactor;
        layer.frame = view.bounds;
        layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        layer.drawableSize = CGSizeMake(view.bounds.size.width * layer.contentsScale,
                                        view.bounds.size.height * layer.contentsScale);
        view.layer = layer;
        metalWindow.contentView = view;
        [metalWindow makeKeyAndOrderFront:nil];
    });
    if (!transitionFullscreen(true))
        mexWarnMsgIdAndTxt("PsychMetal:FullscreenEnter",
                           "Timed out waiting for native fullscreen entry.");
    onMainSync(^{
        NSView *v = metalWindow.contentView;
        layer.contentsScale = metalWindow.backingScaleFactor;
        layer.frame = v.bounds;
        layer.drawableSize = CGSizeMake(v.bounds.size.width * layer.contentsScale,
                                        v.bounds.size.height * layer.contentsScale);
    });
    __block CGSize actualDrawableSize = CGSizeZero;
    onMainSync(^{ actualDrawableSize = layer.drawableSize; });
    if (llround(actualDrawableSize.width) != (long long)w ||
        llround(actualDrawableSize.height) != (long long)h)
        mexErrMsgIdAndTxt(
            "PsychMetal:DrawableSize",
            "Metal drawable is %.0fx%.0f but the PTB drawing rectangle is %lux%lu. Refusing "
            "to scale the stimulus; the returned rect must describe the actual drawable.",
            actualDrawableSize.width, actualDrawableSize.height, (unsigned long)w,
            (unsigned long)h);
    ifi = period;
    renderWidth = w;
    renderHeight = h;
    originalTexture = tex0;
    textureTarget = target;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V{float4 "
                       @"p[[position]];float2 uv;};\nvertex V vmain(uint i[[vertex_id]]){float2 "
                       @"p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};float2 "
                       @"u[3]={float2(0,0),float2(2,0),float2(0,2)};return "
                       @"{float4(p[i],0,1),u[i]};}\nfragment float4 fmain(V in[[stage_in]],texture2d<float> "
                       @"t[[texture(0)]],sampler s[[sampler(0)]]){return t.sample(s,in.uv);}";
    NSError *shaderError = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&shaderError];
    if (!lib)
        mexErrMsgIdAndTxt("PsychMetal:Shader", "Metal shader failed: %s",
                          shaderError.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vmain"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&shaderError];
    if (!pipeline)
        mexErrMsgIdAndTxt("PsychMetal:Pipeline", "Metal pipeline failed: %s",
                          shaderError.localizedDescription.UTF8String);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterNearest;
    sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler = [device newSamplerStateWithDescriptor:sd];
    glGenTextures(2, gltex);
    for (int i = 0; i < 2; i++) {
        surfaces[i] = makeSurface(w, h);
        if (!surfaces[i])
            fail("IOSurface allocation failed.");
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:w
                                                              height:h
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        textures[i] = [device newTextureWithDescriptor:td iosurface:surfaces[i] plane:0];
        glBindTexture(target, gltex[i]);
        glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(target, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        CGLError e = CGLTexImageIOSurface2D(c, target, GL_RGBA8, (GLsizei)w, (GLsizei)h, GL_BGRA,
                                            GL_UNSIGNED_INT_8_8_8_8_REV, surfaces[i], 0);
        if (e != kCGLNoError)
            mexErrMsgIdAndTxt("PsychMetal:IOSurface",
                              "CGLTexImageIOSurface2D error %d (%s): target=0x%x size=%lux%lu rowBytes=%lu "
                              "surfaceAlloc=%lu MetalTexture=%s",
                              (int)e, CGLErrorString(e), (unsigned)target, (unsigned long)w, (unsigned long)h,
                              (unsigned long)IOSurfaceGetBytesPerRow(surfaces[i]),
                              (unsigned long)IOSurfaceGetAllocSize(surfaces[i]), textures[i] ? "yes" : "no");
    }
    glBindTexture(target, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, ptbFbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, gltex[0], 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        fail("PTB framebuffer is incomplete with IOSurface attachment.");
    memset(rec, 0, sizeof(rec));
    memset(lastBufferToken, 0, sizeof(lastBufferToken));
    nextToken = 1;
    pendingBuffer = -1;
    pendingTargetTick = 0;
    lastTargetTick = 0;
    ticks = 0;
    confirmedCount = 0;
    missingPresentedCount = 0;
    lastTargetErrorMs = NAN;
    lastConfirmDelayMs = NAN;
    lagEstimateFrames = 0;
    lagCandidateFrames = 0;
    lagCandidateCount = 0;
    activeLinkCallbacks = 0;
    pthread_mutex_lock(&lock);
    closing = false;
    pthread_mutex_unlock(&lock);
    onMainSync(^{
        driver = [PMDriver new];
        driver.link = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
        driver.link.delegate = driver;
        driver.link.preferredFrameLatency = 1;
        double hz = (ifi > 0) ? 1.0 / ifi : 60;
        driver.link.preferredFrameRateRange = CAFrameRateRangeMake(hz, hz, hz);
        [driver.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        driver.link.paused = NO;
    });
    mexAtExit(closeCore);
}
static uint64_t enqueue(int b) {
    if (b < 0 || b > 1)
        fail("Buffer index must be zero or one.");
    // Cross-API synchronization: Metal must not sample the IOSurface until
    // all preceding PTB/OpenGL drawing into it has completed.
    glFinish();
    pthread_mutex_lock(&lock);
    struct timespec d = deadline(2);
    while (pendingBuffer >= 0)
        if (pthread_cond_timedwait(&cond, &lock, &d) == ETIMEDOUT) {
            pthread_mutex_unlock(&lock);
            fail("Presentation queue timeout.");
        }
    uint64_t t = nextToken++;
    Record *r = &rec[t % NREC];
    memset(r, 0, sizeof(*r));
    r->token = t;
    r->status = 2;
    lastBufferToken[b] = t;
    uint64_t earliest = ticks + 1;
    uint64_t requested = lastTargetTick ? lastTargetTick + 1 : earliest;
    pendingTargetTick = (requested > earliest) ? requested : earliest;
    lastTargetTick = pendingTargetTick;
    pendingBuffer = b;
    pendingToken = t;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    int next = 1 - b;
    waitBuffer(next);
    glBindFramebuffer(GL_FRAMEBUFFER, ptbFbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, textureTarget, gltex[next], 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        fail("PTB framebuffer became incomplete while swapping IOSurface attachment.");
    return t;
}
static void waitBuffer(int b) {
    pthread_mutex_lock(&lock);
    uint64_t token = lastBufferToken[b];
    Record *r = token ? recordFor(token) : NULL;
    struct timespec d = deadline(2);
    while (r && !r->gpuDone)
        if (pthread_cond_timedwait(&cond, &lock, &d) == ETIMEDOUT) {
            pthread_mutex_unlock(&lock);
            fail("Buffer reuse timeout.");
        }
    pthread_mutex_unlock(&lock);
}
static Record waitScheduled(uint64_t t) {
    pthread_mutex_lock(&lock);
    Record *r = recordFor(t);
    if (!r) {
        pthread_mutex_unlock(&lock);
        fail("Unknown or expired frame token.");
    }
    struct timespec d = deadline(2);
    while (!r->scheduled)
        if (pthread_cond_timedwait(&cond, &lock, &d) == ETIMEDOUT)
            break;
    Record out = *r;
    if (!r->scheduled) {
        out.status = 2;
        out.projected = 0;
    }
    pthread_mutex_unlock(&lock);
    return out;
}
static void drainRecords(void) {
    pthread_mutex_lock(&lock);
    struct timespec d = deadline(2);
    for (;;) {
        bool pending = false;
        uint64_t start = (nextToken > NREC) ? nextToken - NREC : 1;
        for (uint64_t token = start; token < nextToken; token++) {
            Record *r = recordFor(token);
            if (r && r->scheduled && !r->done) {
                pending = true;
                break;
            }
        }
        if (!pending)
            break;
        if (pthread_cond_timedwait(&cond, &lock, &d) == ETIMEDOUT)
            break;
    }
    pthread_mutex_unlock(&lock);
}
static mxArray *historyMatrix(void) {
    pthread_mutex_lock(&lock);
    uint64_t end = nextToken;
    uint64_t start = (end > NREC) ? end - NREC : 1;
    mwSize count = (mwSize)(end - start);
    mxArray *out = mxCreateDoubleMatrix(count, 9, mxREAL);
    double *v = mxGetPr(out);
    for (uint64_t t = start; t < end; t++) {
        Record *r = recordFor(t);
        mwSize row = (mwSize)(t - start);
        // The selected token range is exactly the live portion of the ring.
        // Keep the original row even if corruption is detected, so MATLAB's
        // column-major stride remains valid.
        if (!r)
            continue;
        v[row + count * 0] = (double)r->token;
        v[row + count * 1] = r->projected;
        v[row + count * 2] = r->presented;
        v[row + count * 3] = r->done ? r->status : 2;
        v[row + count * 4] = r->scheduledAt;
        v[row + count * 5] = r->callback;
        v[row + count * 6] = (double)r->tick;
        v[row + count * 7] = (double)r->commandStatus;
        v[row + count * 8] = r->rawTarget;
    }
    pthread_mutex_unlock(&lock);
    return out;
}

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    @autoreleasepool {
        if (nrhs < 1)
            fail("Command required.");
        if (cmd(prhs[0], "Open")) {
            if (nrhs != 11)
                fail("Open needs "
                     "width,height,IFI,target,texture,screenIndex,globalRect.");
            openCore(mxGetScalar(prhs[1]), mxGetScalar(prhs[2]), mxGetScalar(prhs[3]), mxGetScalar(prhs[4]),
                     mxGetScalar(prhs[5]), (NSInteger)mxGetScalar(prhs[6]), mxGetScalar(prhs[7]),
                     mxGetScalar(prhs[8]), mxGetScalar(prhs[9]), mxGetScalar(prhs[10]));
            return;
        }
        if (cmd(prhs[0], "Queue")) {
            if (nrhs != 2 || nlhs != 1)
                fail("Queue needs a buffer index.");
            plhs[0] = mxCreateDoubleScalar(enqueue((int)mxGetScalar(prhs[1])));
            return;
        }
        if (cmd(prhs[0], "WaitScheduled")) {
            if (nrhs != 2 || nlhs != 1)
                fail("WaitScheduled needs one token and one output.");
            Record r = waitScheduled((uint64_t)mxGetScalar(prhs[1]));
            plhs[0] = mxCreateDoubleMatrix(1, 2, mxREAL);
            double *v = mxGetPr(plhs[0]);
            v[0] = r.projected;
            v[1] = r.scheduled ? 0 : 2;
            return;
        }
        if (cmd(prhs[0], "Diagnostic")) {
            if (nrhs != 1 || nlhs != 2)
                fail("Diagnostic needs two outputs.");
            drainRecords();
            plhs[0] = historyMatrix();
            __block CGSize drawableSize = CGSizeZero;
            if (metalWindow)
                onMainSync(^{ drawableSize = layer.drawableSize; });
            // Snapshot values written by the display-link and completion
            // callbacks before constructing MATLAB arrays.
            pthread_mutex_lock(&lock);
            uint64_t snapshotTicks = ticks;
            uint64_t snapshotConfirmed = confirmedCount;
            uint64_t snapshotMissing = missingPresentedCount;
            double snapshotTargetError = lastTargetErrorMs;
            double snapshotConfirmDelay = lastConfirmDelayMs;
            pthread_mutex_unlock(&lock);
            const char *n[] = {
                "displayLinkTicks",      "confirmedPresentations", "missingPresentedTimes",
                "lastTargetErrorMs",     "lastConfirmDelayMs",     "appKitScreenIndex",
                "cgDisplayID",           "renderWidth",            "renderHeight",
                "drawableWidth",         "drawableHeight"};
            plhs[1] = mxCreateStructMatrix(1, 1, 11, n);
            mxSetField(plhs[1], 0, "displayLinkTicks", mxCreateDoubleScalar(snapshotTicks));
            mxSetField(plhs[1], 0, "confirmedPresentations", mxCreateDoubleScalar(snapshotConfirmed));
            mxSetField(plhs[1], 0, "missingPresentedTimes", mxCreateDoubleScalar(snapshotMissing));
            mxSetField(plhs[1], 0, "lastTargetErrorMs", mxCreateDoubleScalar(snapshotTargetError));
            mxSetField(plhs[1], 0, "lastConfirmDelayMs", mxCreateDoubleScalar(snapshotConfirmDelay));
            mxSetField(plhs[1], 0, "appKitScreenIndex", mxCreateDoubleScalar(selectedScreenIndex));
            mxSetField(plhs[1], 0, "cgDisplayID", mxCreateDoubleScalar(selectedDisplayID));
            mxSetField(plhs[1], 0, "renderWidth", mxCreateDoubleScalar(renderWidth));
            mxSetField(plhs[1], 0, "renderHeight", mxCreateDoubleScalar(renderHeight));
            mxSetField(plhs[1], 0, "drawableWidth", mxCreateDoubleScalar(drawableSize.width));
            mxSetField(plhs[1], 0, "drawableHeight", mxCreateDoubleScalar(drawableSize.height));
            return;
        }
        if (cmd(prhs[0], "Close")) {
            closeCore();
            return;
        }
        fail("Unknown command.");
    }
}
