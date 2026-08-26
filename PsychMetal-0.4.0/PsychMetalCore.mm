// PsychMetalCore 0.4.0 — direct Metal presentation. No OpenGL.
// SPDX-License-Identifier: MIT
#include "mex.h"
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <vector>

#define NREC 16384
#define LAGWIN 64
typedef struct {
    uint64_t token;
    int status, done, gpuDone, scheduled, commandStatus, inFlight;
    double projected, scheduledAt, presented, callback;
    // scheduledAt is stamped when Flip STARTS, before layer.nextDrawable, so
    // presented - scheduledAt includes drawable-pool backpressure and is not
    // the pipeline latency. committedAt is stamped at [cb commit], after the
    // wait, so presented - committedAt is the actual submit-to-present figure
    // the N+2 rule is about. Reporting only the former made a deeper drawable
    // pool look like a longer pipeline when it is mostly a longer queue.
    double committedAt;
    double requestedTime, gpuStart, gpuEnd, presentRequest, presentCallMs;
    int pipelineNoted;
} Record;
static NSWindow *metalWindow;
static CAMetalLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
// Native Metal drawing. Shapes accumulate on the calling thread during a frame
// and are encoded into the drawable's own render pass, in call order, over a
// background the pass has already cleared to. One instanced quad per shape: the
// fragment shader decides coverage, which is how ovals, frames, Gabors and
// noise share one pipeline without any per-shape vertex data.
#define PM_MAX_SHAPES 8192
#define PM_SHAPE_RING 4
// kind selects how the fragment shader computes coverage, and how the vertex
// shader reads rect: for a line rect is the two endpoints, otherwise it is a
// bounding box. param is the pen width for the frame shapes and the line width.
// 64 bytes, 16-byte aligned, matching the Metal struct exactly.
//
// extra carries the parameters only the Gabor needs: cycles per pixel, carrier
// orientation in radians, and carrier phase in radians. It is a separate float4
// rather than more scalars because a float4 lands on the 16-byte boundary the
// struct already has to respect, and because a fourth Gabor parameter (an
// aspect ratio for the envelope) is the obvious next request.
enum { PM_FILL_RECT = 0, PM_FRAME_RECT = 1, PM_FILL_OVAL = 2,
       PM_FRAME_OVAL = 3, PM_DOT = 4, PM_LINE = 5, PM_GABOR = 6,
       PM_NOISE = 7 };

// WHITE NOISE IS A HASH, NOT A RANDOM STREAM, and that is the whole design.
//
// Generating a full frame on the CPU and uploading it does not fit in a
// refresh. Measured single-threaded over 2880x1864 = 5.4M pixels: mono uniform
// 7.6 ms, colour uniform 15.9 ms, mono normal via Box-Muller 50.3 ms, plus
// 21.5 MB of upload per frame (1.3 GB/s at 60 Hz). Normal-distributed
// full-frame noise cannot be done that way at 60 Hz at any plausible CPU speed.
//
// A counter-based hash of (x, y, seed) has no state, so every pixel is computed
// independently in the fragment shader with nothing uploaded. It is also more
// reproducible than a stream RNG rather than less: any pixel of any frame can
// be recomputed at any time, in any order, from the seed alone.
//
// pmHash is a PCG output permutation. The SAME arithmetic appears in the Metal
// shader source below and in noiseDeviate() here, and the two must stay
// identical or PsychMetal('NoiseValues') will not describe what was displayed.
// Both rely on uint32 wraparound, which is why the CPU side is here in C rather
// than in the wrapper: MATLAB and Octave saturate uint32 arithmetic instead of
// wrapping, so a .m implementation would be silently wrong.
static inline uint32_t pmHash(uint32_t v) {
    uint32_t s = v * 747796405u + 2891336453u;
    uint32_t w = ((s >> ((s >> 28) + 4)) ^ s) * 277803737u;
    return (w >> 22) ^ w;
}
static inline float pmUnit(uint32_t k) {
    return (float)k * 2.3283064365386963e-10f;   // [0, 1)
}
// Zero-mean deviate: uniform on [-1, 1], or standard normal by Box-Muller.
static inline float noiseDeviate(uint32_t base, uint32_t channel, bool normal) {
    uint32_t k = pmHash(base + channel * 0x9E3779B9u);
    if (!normal)
        return pmUnit(k) * 2.0f - 1.0f;
    float u1 = pmUnit(k) * 0.9999998f + 1.0e-7f;
    float u2 = pmUnit(pmHash(k + 1u));
    return sqrtf(-2.0f * logf(u1)) * cosf(6.28318530718f * u2);
}
static inline uint32_t noiseBase(uint32_t seed, uint32_t ix, uint32_t iy) {
    return pmHash(pmHash(pmHash(seed) + ix) + iy);
}
typedef struct {
    float rect[4];
    float color[4];
    uint32_t kind;
    float param;
    float pad[2];
    float extra[4];
} PMShape;
// Background colour for the frame clear, matching Screen('OpenWindow')'s second
// argument. Every frame is cleared to it before any drawing.
static float clearRGBA[4] = {0.0f, 0.0f, 0.0f, 1.0f};
// Drawable prefetch. nextDrawable blocks until the pool has a free drawable,
// which with two drawables is a full presentation away. Calling it at the START
// of Flip puts that wait between the caller's input sample and the commit, so
// the sample is about a refresh stale by the time the frame is submitted even
// though the pipeline itself is optimal: measured 0.942 refreshes from sample
// to commit against 0.975 from commit to photons.
//
// The wait is unavoidable, but its POSITION is not. Acquiring the next frame's
// drawable at the END of Flip moves the block before the next sample instead of
// after it. Frame time and rate are unchanged; only staleness is removed.
//
// This is not the long hold the scheduled-`when` path warns about: the drawable
// is held across one frame's drawing, not many refreshes.
// Online slip detection. presentedTime for frame N arrives about half a
// millisecond after it is shown, so by the time Flip is called for N+1 the
// truth about N is already known and can be reported to the caller rather than
// left for post-hoc analysis.
//
// It also has to be fed back into the prediction. lastProjected advanced at the
// nominal cadence and never re-anchored, so after a slip the projection fell
// BEHIND reality and stayed there: a caller computing its next `when` from the
// returned timestamp asked for a moment already past, and the frames that
// followed presented at the next boundary instead of the requested one. One
// late frame produced four wrongly scheduled ones.
static double lastConfirmedPresented = NAN;   // newest confirmed presentedTime
static double lastConfirmedProjected = NAN;   // what was predicted for it
static double pendingSlipRefreshes;           // reported with the NEXT flip
static int prefetchDrawable;
static id<CAMetalDrawable> heldDrawable;
static id<MTLRenderPipelineState> shapePipeline;
static id<MTLBuffer> shapeBuffers[PM_SHAPE_RING];
static int shapeBufferIndex;
// Draw items are kept in CALL ORDER, not sorted by kind. Shapes batch into one
// instanced draw, but a texture needs its own binding and breaks the batch, so
// the encoder walks this list and flushes the pending shape run whenever it
// meets a texture. That is what makes a texture drawn after a rectangle appear
// on top of it, which sorting by kind would not.
#define PM_MAX_TEXTURES 256
enum { PM_ITEM_SHAPE = 0, PM_ITEM_TEXTURE = 1 };
typedef struct {
    uint32_t type;
    PMShape shape;          // PM_ITEM_SHAPE
    int32_t texIndex;       // PM_ITEM_TEXTURE
    float src[4];           // normalised source rect
    float dst[4];           // destination rect in pixels
    float tint[4];          // multiplied into the sampled colour
    float angle;            // radians, about the destination centre
    int32_t filterMode;     // 0 nearest, 1 bilinear, as Screen('DrawTexture')
} PMDrawItem;
static PMDrawItem drawList[PM_MAX_SHAPES];
static NSUInteger drawCount;
static id<MTLTexture> userTextures[PM_MAX_TEXTURES];
static id<MTLRenderPipelineState> texturePipeline;
static id<MTLSamplerState> linearSampler, nearestSampler;
static uint64_t texturesCreated, texturesDrawn;

static bool shapeOverflow;
// Cumulative counters, so a shape that never appears can be traced to the stage
// that lost it: appended but not encoded means the encode site never ran.
static uint64_t shapesAppended, shapesEncoded, shapeEncodeCalls;
// First shape of the most recent batch, exactly as the mex stored it. A shape
// that is queued and encoded but invisible is either off screen or the wrong
// colour, and this distinguishes those without guessing.
static PMShape lastShape;
static bool haveLastShape;
static double ifi, lastTargetErrorMs, lastConfirmDelayMs;
static NSUInteger renderWidth, renderHeight;
static uint64_t nextToken, confirmedCount, missingPresentedCount;
static NSInteger selectedScreenIndex = -1;
static CGDirectDisplayID selectedDisplayID = 0;
static Record rec[NREC];
static bool closing = true;
static int inFlightCount;
// CAMetalDisplayLink.preferredFrameLatency was settable through Open until
// 0.3.1. It was removed because it demonstrably does nothing: the scheduling
// horizon measured 2.995 to 2.997 refreshes at every combination of requested
// latency (1 or 2) and drawable count (2 or 3), and the property read back the
// assigned value correctly in all of them. Requesting 2 under Game Mode gave
// ONE refresh, less than asked for, so it is ignored in both directions rather
// than being the documented case of the system needing more time. See
// docs/05_results.md section 2; the Feedback Assistant reproducer is the
// standalone fblatency.m, which does not need PsychMetal.
static NSUInteger requestedDrawableCount, drawableCountReadback;
static NSInteger activationPolicyBefore = -1, activationPolicyAfter = -1;
static bool activationPolicyPromotionAttempted, activationPolicyPromotionSucceeded;
static bool appPrepared;
// True for the lifetime of one MEX load, never cleared by closeCore. Combined
// with a process environment marker this distinguishes a second Open in the
// same load (fine) from the bundle having been unloaded and reloaded (fatal).
static bool loadInitialized;
// Presentation reproduces what Psychtoolbox does for its OpenGL path: capture
// the display and raise a borderless display-sized window above the shielding
// level, so nothing else can be composited over it. PTB's own comment is that
// this "exclude[s] the desktop compositor from interfering" — note it takes the
// CGL path there, which needs no NSWindow at all. A CAMetalLayer must live in a
// window, so this is as close as a layer-based backend can get; PTB's Vulkan
// backend is under the same constraint. Measured, it makes no difference to
// presentation timing, but it is the only window that positions correctly on a
// display with a notch.
static bool displayCaptured;
// Whether to call CGDisplayCapture. The window sits at CGShieldingWindowLevel
// either way, so this isolates display capture itself as a variable.
static bool captureRequested = true;
// A drawable is acquired and presented inline on the interpreter thread. There
// is no CAMetalDisplayLink: through 0.3.1 a second mode drove presentation from
// one, which is how 0.2.0 worked, and it cost the link's pipeline depth. The
// frame is presented at the next refresh it can reach rather than at a slot two
// or three refreshes ahead. It is the model MoltenVK uses for a FIFO swapchain,
// and it measured 1.75 refreshes against the display link's 2.995.
static bool directWaitForConfirm = true;
// Vsync. Disabling it lets a frame be presented as soon as it is ready instead
// of at a refresh boundary. It tears, so it is a diagnostic rather than a
// stimulus mode, but it separates "waiting for a compositor slot" from
// "presentedTime is accounted at the end of scan-out".
static bool displaySync = true;
// Two-phase presentation. PrepareFlip does the fence, drawable acquisition,
// encoding, commit and waitUntilScheduled; PresentNow issues only [drawable
// present]. Everything variable happens before the deadline, so the jitter of
// the swap itself can be measured and minimised.
static id<CAMetalDrawable> preparedDrawable;
static uint64_t preparedToken;
// Refresh grid learned from confirmed presentedTime values. Measured intervals
// are stable to a couple of mach ticks, so one anchor plus the measured period
// predicts every later refresh boundary to well under a microsecond.
static double gridFirstPresented, gridLastPresented, measuredIFI;
// The last presentation time handed back to the caller. Presentation is FIFO, so
// the next frame cannot appear before this one; without the constraint an
// unscheduled Flip immediately after a long scheduled hold predicts from a clock
// that is still behind the value already returned, and Flip appears to go
// backwards in time.
static double lastProjected;
static int64_t gridFirstFrame, gridLastFrame;
static uint64_t gridSamples, directNoDrawableCount, directTimeoutCount;
// Running estimate of submit-to-present latency, from confirmed presentations.
// WaitToDraw uses it to work backwards from a target refresh boundary to the
// moment drawing must start, so input can be sampled as late as possible.
static double leadSamples[LAGWIN], leadEstimate;
static int leadCount, leadIndex;
// The scheduling-relevant quantity is the part of the pipeline the application
// cannot influence: from GPU completion to reported presentation. Measuring
// submit-to-present instead is circular, because that interval contains
// whatever delay PsychMetal itself chose before acquiring the drawable.
static double pipelineSamples[LAGWIN], pipelineEstimate;
static int pipelineCount, pipelineIndex;
static double gpuSamples[LAGWIN], gpuEstimate;
static int gpuCount, gpuIndex;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static void closeCore(void);
static void notePipelineSample(Record *q);
static void prepareApp(void);
static void settleAppKit(double seconds);
static void onMainSync(dispatch_block_t block) {
    if (pthread_main_np())
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

static Record *recordFor(uint64_t token) {
    Record *r = &rec[token % NREC];
    return (r->token == token) ? r : NULL;
}
// Upper percentile of a small sample. WaitToDraw needs a conservative bound on
// submit-to-present latency, not a central one: undershooting makes the frame
// miss its refresh boundary entirely, while overshooting only samples input
// slightly earlier than strictly necessary.
static double percentileOf(const double *src, int n, double frac) {
    double values[LAGWIN];
    memcpy(values, src, (size_t)n * sizeof(double));
    for (int i = 1; i < n; i++) {
        double value = values[i];
        int j = i - 1;
        while (j >= 0 && values[j] > value) {
            values[j + 1] = values[j];
            j--;
        }
        values[j + 1] = value;
    }
    int idx = (int)(frac * (n - 1) + 0.5);
    if (idx < 0) idx = 0;
    if (idx > n - 1) idx = n - 1;
    return values[idx];
}
// 1x4 double array helper for the geometry fields in Diagnostic.
static mxArray *rect4(double a, double b, double c, double d) {
    mxArray *m = mxCreateDoubleMatrix(1, 4, mxREAL);
    double *p = mxGetPr(m);
    p[0] = a; p[1] = b; p[2] = c; p[3] = d;
    return m;
}

// Encode the shapes accumulated since the last Flip, then clear the list. Called
// with the render encoder still open, after the pass has cleared the drawable.
// Rotates through a small ring of instance buffers because earlier frames may
// still be reading the previous one.
static void encodeShapes(id<MTLRenderCommandEncoder> re) {
    pthread_mutex_lock(&lock);
    NSUInteger n = drawCount;
    bool overflowed = shapeOverflow;
    // Static, not a local: PM_MAX_SHAPES items is far too large for the stack.
    // Safe because only one frame is ever encoded at a time, and the copy exists
    // so the lock can be released before any Metal call.
    static PMDrawItem items[PM_MAX_SHAPES];
    if (n > 0)
        memcpy(items, drawList, n * sizeof(PMDrawItem));
    drawCount = 0;
    shapeOverflow = false;
    haveLastShape = false;
    shapeEncodeCalls++;
    shapesEncoded += n;
    pthread_mutex_unlock(&lock);

    if (overflowed)
        mexWarnMsgIdAndTxt("PsychMetal:ShapeOverflow",
                           "More than %d draw items in one frame; the excess was dropped.",
                           PM_MAX_SHAPES);
    if (n == 0 || !re)
        return;

    float size[2] = {(float)renderWidth, (float)renderHeight};

    // Walk in call order. Consecutive shapes accumulate into one instanced
    // draw; a texture flushes that run first, so ordering is preserved.
    //
    // Shapes are written STRAIGHT INTO the mapped Metal buffer rather than into
    // a local array first. An earlier version staged them in a
    // PMShape[PM_MAX_SHAPES] local, which is a 393 KB stack allocation on every
    // frame and cost about half the frame rate.
    // ONE buffer for the whole frame, with a rising offset per flush. The
    // previous version advanced to the next buffer in a 4-slot ring at every
    // flush, so a frame containing five textures wrapped the ring and
    // overwrote data that earlier draws in the SAME command buffer still
    // referenced. Metal reads vertex buffers at GPU execution time, not at
    // encode time, so that was a real corruption hazard as well as forcing
    // the driver to track write-after-read hazards.
    int slot = shapeBufferIndex;
    shapeBufferIndex = (shapeBufferIndex + 1) % PM_SHAPE_RING;
    PMShape *base = (PMShape *)shapeBuffers[slot].contents;
    NSUInteger written = 0;      // total shapes placed in this frame's buffer
    NSUInteger batched = 0;      // shapes in the run waiting to be drawn

    for (NSUInteger i = 0; i <= n; i++) {
        bool isShape = (i < n) && (items[i].type == PM_ITEM_SHAPE);
        if (isShape && written < PM_MAX_SHAPES) {
            base[written++] = items[i].shape;
            batched++;
            continue;
        }
        if (batched > 0 && shapePipeline) {
            [re setRenderPipelineState:shapePipeline];
            [re setVertexBuffer:shapeBuffers[slot]
                         offset:(written - batched) * sizeof(PMShape)
                        atIndex:0];
            [re setVertexBytes:size length:sizeof(size) atIndex:1];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip
                   vertexStart:0
                   vertexCount:4
                 instanceCount:batched];
            batched = 0;
        }
        if (i >= n)
            break;
        PMDrawItem *it = &items[i];
        if (it->texIndex < 0 || it->texIndex >= PM_MAX_TEXTURES ||
            !userTextures[it->texIndex] || !texturePipeline)
            continue;
        struct {
            float dst[4], src[4], tint[4], size[2], angle, pad;
        } u;
        memcpy(u.dst, it->dst, sizeof(u.dst));
        memcpy(u.src, it->src, sizeof(u.src));
        memcpy(u.tint, it->tint, sizeof(u.tint));
        u.size[0] = size[0];
        u.size[1] = size[1];
        u.angle = it->angle;
        u.pad = 0.0f;
        [re setRenderPipelineState:texturePipeline];
        [re setVertexBytes:&u length:sizeof(u) atIndex:0];
        [re setFragmentTexture:userTextures[it->texIndex] atIndex:0];
        [re setFragmentSamplerState:(it->filterMode ? linearSampler : nearestSampler)
                            atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        texturesDrawn++;
    }
}

// The whole of a frame's encoding: clear the drawable, encode the Metal draw
// list, end the pass. Returns false only if the encoder could not be created,
// which each caller reports differently.
//
// Through 0.3.1 this began by blitting an IOSurface that Screen had drawn into.
// That was the entire reason PsychMetal needed OpenGL, and it is gone.
static bool encodeFrame(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d) {
    if (!cb || !d)
        return false;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = d.texture;
    // With interop the blit below covers every pixel, so DontCare avoids a
    // full-screen write that would be thrown away. Without it there is nothing
    // underneath, and the drawable is recycled, so it must be cleared or the
    // previous contents of that drawable show through wherever nothing is drawn.
    // Drawables are recycled from a pool, so a frame that did not write every
    // pixel would show the contents of a frame two or three back. The clear is
    // the only thing standing between the caller and that.
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(clearRGBA[0], clearRGBA[1], clearRGBA[2], clearRGBA[3]);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    if (!re)
        return false;
    // The native Metal draw list, in call order.
    encodeShapes(re);
    [re endEncoding];
    return true;
}

// Presented and completed handlers are identical for both presentation modes.
// Factored so the direct path cannot drift from the display-link path.
static void attachHandlers(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d, uint64_t token) {
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
                // Maintain the refresh grid used by direct-mode scheduling.
                // Only while vsync is on: with it off, presentedTime marks
                // whenever the swap happened, not a refresh boundary, so
                // learning from it would destroy the grid. Turning vsync off
                // therefore freezes the grid at its last good estimate, which
                // is exactly what software vsync needs.
                if (displaySync) {
                if (gridSamples == 0) {
                    gridFirstPresented = gridLastPresented = pt;
                    gridFirstFrame = gridLastFrame = 0;
                    gridSamples = 1;
                } else {
                    double period = (measuredIFI > 0) ? measuredIFI : ifi;
                    int64_t f = (int64_t)llround((pt - gridFirstPresented) / period);
                    if (f > gridLastFrame) {
                        gridLastPresented = pt;
                        gridLastFrame = f;
                        gridSamples++;
                        // Require both a reasonable number of samples and a long
                        // enough baseline. Keying only on the frame-index span
                        // left the estimate unset whenever presentations were
                        // spaced more than one refresh apart.
                        int64_t span = gridLastFrame - gridFirstFrame;
                        if (gridSamples >= 16 && span >= 16)
                            measuredIFI = (gridLastPresented - gridFirstPresented) /
                                          (double)span;
                    }
                }
                }
                // A frame that missed its target has an inflated lead. Feeding
                // that back would push the estimate up, wake the caller earlier,
                // lengthen the drawable hold and cause more misses. Learn only
                // from frames that landed where they were asked to.
                bool onTarget = !isfinite(q->requestedTime) ||
                                fabs(pt - q->requestedTime) < 0.5 * ifi;
                double lead = pt - q->scheduledAt;
                if (onTarget && lead > 0 && lead < 10.0 * ifi) {
                    leadSamples[leadIndex] = lead;
                    leadIndex = (leadIndex + 1) % LAGWIN;
                    if (leadCount < LAGWIN)
                        leadCount++;
                    if (leadCount >= 8)
                        leadEstimate = percentileOf(leadSamples, leadCount, 0.90);
                }
                lastTargetErrorMs = (pt - q->projected) * 1000.0;
                // Newest confirmation wins; handlers can retire out of order.
                if (!isfinite(lastConfirmedPresented) || pt > lastConfirmedPresented) {
                    lastConfirmedPresented = pt;
                    lastConfirmedProjected = q->projected;
                }
                lastConfirmDelayMs = (ct - pt) * 1000.0;
            } else
                missingPresentedCount++;
            notePipelineSample(q);
            if (q->inFlight && q->done && q->gpuDone) {
                q->inFlight = 0;
                inFlightCount--;
            }
        }
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
    }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> x) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(token);
        if (q) {
            q->commandStatus = (int)x.status;
            q->gpuStart = x.GPUStartTime;
            q->gpuEnd = x.GPUEndTime;
            q->gpuDone = 1;
            if (x.status == MTLCommandBufferStatusError && !q->done) {
                q->status = 3;
                q->done = 1;
            }
            notePipelineSample(q);
            if (q->inFlight && q->done && q->gpuDone) {
                q->inFlight = 0;
                inFlightCount--;
            }
        }
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
    }];
}

// Caller holds the lock. Records the uncontrollable part of the pipeline once
// both the GPU completion and the presentation timestamp are known.
static void notePipelineSample(Record *q) {
    // Only unscheduled frames measure the pipeline honestly. A frame presented
    // with presentDrawable:atTime: waits for its target, so presented - gpuEnd
    // would report whatever delay PsychMetal itself chose.
    if (!q || q->pipelineNoted || q->presented <= 0 || q->gpuEnd <= 0 ||
        isfinite(q->requestedTime))
        return;
    q->pipelineNoted = 1;
    double post = q->presented - q->gpuEnd;
    if (post > 0 && post < 10.0 * ifi) {
        pipelineSamples[pipelineIndex] = post;
        pipelineIndex = (pipelineIndex + 1) % LAGWIN;
        if (pipelineCount < LAGWIN)
            pipelineCount++;
        if (pipelineCount >= 8)
            pipelineEstimate = percentileOf(pipelineSamples, pipelineCount, 0.90);
    }
    double gpu = q->gpuEnd - q->gpuStart;
    if (gpu > 0 && gpu < ifi) {
        gpuSamples[gpuIndex] = gpu;
        gpuIndex = (gpuIndex + 1) % LAGWIN;
        if (gpuCount < LAGWIN)
            gpuCount++;
        if (gpuCount >= 8)
            gpuEstimate = percentileOf(gpuSamples, gpuCount, 0.90);
    }
}


static bool cmd(const mxArray *a, const char *s) {
    char b[64];
    if (!mxIsChar(a))
        return false;
    mxGetString(a, b, sizeof(b));
    return strcasecmp(b, s) == 0;
}
[[noreturn]] static void fail(const char *s) {
    mexErrMsgIdAndTxt("PsychMetal:Error", "%s", s);
    __builtin_unreachable();
}
[[noreturn]] static void failOpen(const char *id, NSString *message) {
    char text[1024];
    const char *utf8 = message.UTF8String;
    snprintf(text, sizeof(text), "%s", utf8 ? utf8 : "PsychMetal Open failed.");
    closeCore();
    mexErrMsgIdAndTxt(id, "%s", text);
    __builtin_unreachable();
}
static int waitRelative(double endTime) {
    double remaining = endTime - CACurrentMediaTime();
    if (remaining <= 0)
        return ETIMEDOUT;
    struct timespec relative;
    relative.tv_sec = (time_t)remaining;
    relative.tv_nsec = (long)((remaining - relative.tv_sec) * 1e9);
    return pthread_cond_timedwait_relative_np(&cond, &lock, &relative);
}
static double scalar(const mxArray *a, const char *name) {
    if (!mxIsNumeric(a) || mxIsComplex(a) || mxGetNumberOfElements(a) != 1) {
        char text[160];
        snprintf(text, sizeof(text), "%s must be a real numeric scalar.", name);
        fail(text);
    }
    double v = mxGetScalar(a);
    if (!isfinite(v)) {
        char text[160];
        snprintf(text, sizeof(text), "%s must be finite.", name);
        fail(text);
    }
    return v;
}
static uint64_t unsignedScalar(const mxArray *a, const char *name, uint64_t maximum) {
    double v = scalar(a, name);
    if (v < 0 || floor(v) != v || v > (double)maximum) {
        char text[160];
        snprintf(text, sizeof(text), "%s must be a nonnegative integer in range.", name);
        fail(text);
    }
    return (uint64_t)v;
}
static void closeCore(void) {
    // Prevent new display-link work before invalidating the link. A callback
    // already encoding a frame is allowed to finish before resources vanish.
    pthread_mutex_lock(&lock);
    closing = true;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    pthread_mutex_lock(&lock);
    // Completion and presented handlers also touch the record ring. Drain
    // submitted frames before a later Open clears and reuses those records.
    double gpuDeadline = CACurrentMediaTime() + 2.0;
    while (inFlightCount > 0)
        if (waitRelative(gpuDeadline) == ETIMEDOUT)
            break;
    pthread_mutex_unlock(&lock);
    // Hide the stimulus before tearing anything down, but keep the window object
    // alive until the display is released so the desktop cannot repaint under a
    // still-visible window.
    if (metalWindow)
        onMainSync(^{
            metalWindow.ignoresMouseEvents = YES;
            [metalWindow resignKeyWindow];
            [metalWindow orderOut:nil];
        });
    if (metalWindow)
        onMainSync(^{
            [metalWindow close];
            metalWindow = nil;
        });
    if (displayCaptured) {
        CGDisplayRelease(selectedDisplayID);
        displayCaptured = false;
    }
    settleAppKit(0.25);
    if (activationPolicyPromotionSucceeded && activationPolicyBefore >= 0)
        onMainSync(^{
            [NSApp setActivationPolicy:(NSApplicationActivationPolicy)activationPolicyBefore];
        });
    activationPolicyPromotionAttempted = false;
    activationPolicyPromotionSucceeded = false;
    appPrepared = false;
    preparedDrawable = nil;
    shapePipeline = nil;
    texturePipeline = nil;
    linearSampler = nil;
    nearestSampler = nil;
    for (int i = 0; i < PM_MAX_TEXTURES; i++)
        userTextures[i] = nil;
    drawCount = 0;
    texturesCreated = texturesDrawn = 0;
    heldDrawable = nil;
    prefetchDrawable = 0;
    for (int i = 0; i < PM_SHAPE_RING; i++)
        shapeBuffers[i] = nil;
    shapeOverflow = false;
    shapesAppended = shapesEncoded = shapeEncodeCalls = 0;
    haveLastShape = false;
    memset(&lastShape, 0, sizeof(lastShape));
    queue = nil;
    device = nil;
    layer = nil;
}
static void prepareApp(void) {
    // Unloading the bundle (clear PsychMetalCore, clear all, clear mex) after a
    // window has existed removes the Objective-C classes and blocks it
    // registered while AppKit, notification observers and Core Animation may
    // still reference them. Reloading and reopening then crashes. Detect it.
    if (!loadInitialized) {
        const char *marker = getenv("PSYCHMETAL_HOST_PREPARED");
        if (marker && marker[0] == '1')
            fail("PsychMetalCore was unloaded and reloaded in this process, most likely by "
                 "'clear PsychMetalCore', 'clear mex' or 'clear all' after a PsychMetal "
                 "window had been opened. AppKit state from the previous load cannot be "
                 "reused safely. Restart Octave or MATLAB before opening another window.");
        setenv("PSYCHMETAL_HOST_PREPARED", "1", 1);
        loadInitialized = true;
    }
    closeCore();
    onMainSync(^{
        NSApplication *app = [NSApplication sharedApplication];
        // A command-line host starts as Prohibited or Accessory and cannot show
        // a window or take focus until it is promoted to Regular.
        activationPolicyBefore = app.activationPolicy;
        activationPolicyPromotionAttempted =
            activationPolicyBefore != NSApplicationActivationPolicyRegular;
        activationPolicyPromotionSucceeded = false;
        if (activationPolicyPromotionAttempted)
            activationPolicyPromotionSucceeded =
                [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        activationPolicyAfter = app.activationPolicy;
    });
    appPrepared = true;
}
static void settleAppKit(double seconds) {
    onMainSync(^{
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while (limit.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    });
}
static void openCore(NSUInteger w, NSUInteger h, double period,
                     NSInteger screenIndex, double globalLeft, double globalTop, double globalRight,
                     double globalBottom, NSUInteger drawableCount,
                     bool waitConfirm, bool vsync, bool doCapture) {
    captureRequested = doCapture;
    if (!appPrepared)
        fail("PrepareApp must be called before Open.");
    if (metalWindow || device)
        fail("PsychMetal native resources are already open.");
    requestedDrawableCount = drawableCount;
    directWaitForConfirm = waitConfirm;
    displaySync = vsync;
    device = MTLCreateSystemDefaultDevice();
    if (!device)
        failOpen("PsychMetal:Metal", @"No Metal device.");
    queue = [device newCommandQueue];
    if (!queue)
        failOpen("PsychMetal:Metal", @"Could not create a Metal command queue.");
    __block NSString *mappingWarning = nil;
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
            mappingWarning = [NSString stringWithFormat:
                @"Could not match PTB's display rectangle exactly; using AppKit display index %ld.",
                (long)screenIndex];
        }
        if (!screen) {
            screen = NSScreen.mainScreen;
            selectedScreenIndex = 0;
            mappingWarning = @"Could not identify the requested display; using the main display.";
        }
        selectedDisplayID = (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        // Capture before the window exists, so the shield is already up when it
        // is ordered front and there is no frame in which the menu bar shows.
        // CGDisplayIsCaptured and kCGCaptureNoFill are both deprecated, so track
        // our own capture state rather than asking the system.
        displayCaptured = captureRequested &&
                          CGDisplayCapture(selectedDisplayID) == kCGErrorSuccess;
        // Borderless, display-sized, above the shielding level: what Psychtoolbox
        // does for its OpenGL path once it has captured the display. Deliberately
        // NOT AppKit fullscreen — on a display with a notch that places the window
        // at y = -safeAreaInsets.top, displacing the stimulus, and moving it back
        // makes AppKit clamp the content view to visibleFrame instead.
        metalWindow = [[NSWindow alloc] initWithContentRect:screen.frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO
                                                     screen:screen];
        metalWindow.releasedWhenClosed = NO;
        metalWindow.animationBehavior = NSWindowAnimationBehaviorNone;
        metalWindow.title = @"PsychMetal direct offscreen presenter";
        metalWindow.level = (NSInteger)CGShieldingWindowLevel();
        metalWindow.collectionBehavior = NSWindowCollectionBehaviorStationary |
                                         NSWindowCollectionBehaviorFullScreenNone |
                                         NSWindowCollectionBehaviorIgnoresCycle;
        NSView *view = [[NSView alloc] initWithFrame:metalWindow.contentView.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.wantsLayer = YES;
        layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.colorspace = nil;
        layer.wantsExtendedDynamicRangeContent = NO;
        layer.opaque = YES;
        layer.framebufferOnly = YES;
        layer.displaySyncEnabled = displaySync ? YES : NO;
        layer.maximumDrawableCount = drawableCount;
        drawableCountReadback = layer.maximumDrawableCount;
        layer.presentsWithTransaction = NO;
        layer.contentsScale = metalWindow.backingScaleFactor;
        layer.frame = view.bounds;
        layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        layer.drawableSize = CGSizeMake(view.bounds.size.width * layer.contentsScale,
                                        view.bounds.size.height * layer.contentsScale);
        view.layer = layer;
        metalWindow.contentView = view;
        [metalWindow makeKeyAndOrderFront:nil];
    });
    if (mappingWarning)
        mexWarnMsgIdAndTxt("PsychMetal:DisplayMapping", "%s", mappingWarning.UTF8String);
    if (captureRequested && !displayCaptured)
        mexWarnMsgIdAndTxt("PsychMetal:DisplayCapture",
                           "Could not capture the display; the window is above the shielding "
                           "level but the compositor may still be in the path.");
    // Let window ordering and any process reclassification settle before frames
    // start.
    settleAppKit(1.0);
    // The window is display-sized and was never moved, so its origin should be
    // the display origin. Check rather than assume: a nonzero offset would
    // displace every stimulus by that much.
    __block double originError = 0;
    onMainSync(^{
        NSScreen *sc = metalWindow.screen ? metalWindow.screen : NSScreen.mainScreen;
        if (sc)
            originError = fabs(metalWindow.frame.origin.y - sc.frame.origin.y) +
                          fabs(metalWindow.frame.origin.x - sc.frame.origin.x);
    });
    if (originError > 0.5)
        failOpen("PsychMetal:WindowOrigin",
                 [NSString stringWithFormat:
                    @"The presentation window sits %.0f points off the display origin, which "
                     "would displace every stimulus by that much.", originError]);
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
        failOpen("PsychMetal:DrawableSize",
                 [NSString stringWithFormat:
                    @"Metal drawable is %.0fx%.0f but the PTB drawing rectangle is %lux%lu. "
                     "Refusing to scale the stimulus.", actualDrawableSize.width,
                    actualDrawableSize.height, (unsigned long)w, (unsigned long)h]);
    ifi = period;
    renderWidth = w;
    renderHeight = h;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
                       // Instanced shape pass. vid selects a corner of the unit
                       // quad, iid selects the shape. Pixel coordinates use
                       // Psychtoolbox convention: origin top left, y downwards.
                       @"struct S{float4 rect;float4 color;uint kind;float param;float2 pad;"
                       @"float4 extra;};\n"
                       @"struct SV{float4 p[[position]];float4 color;float2 local;"
                       @"float2 hs;float param;float3 gab;uint kind[[flat]];};\n"
                       // The quad is inflated by one pixel so the fragment
                       // shader has room to fade an edge; coverage below does
                       // the shaping, which is why curved shapes need no
                       // tessellation and antialias for free.
                       @"vertex SV svmain(uint vid[[vertex_id]],uint iid[[instance_id]],"
                       @"constant S*sh[[buffer(0)]],constant float2&size[[buffer(1)]]){\n"
                       @"  float2 c[4]={float2(0,0),float2(1,0),float2(0,1),float2(1,1)};\n"
                       @"  float2 f=c[vid];S s=sh[iid];SV o;float2 px;\n"
                       @"  if(s.kind==5u){\n"
                       @"    float2 p0=s.rect.xy,p1=s.rect.zw;float2 d=p1-p0;\n"
                       @"    float len=max(length(d),1e-6);float2 u=d/len;\n"
                       @"    float hw=s.param*0.5+1.0;float2 n=float2(-u.y,u.x)*hw;\n"
                       @"    px=mix(p0,p1,f.x)+n*(f.y*2.0-1.0);\n"
                       @"    o.local=float2(0.0,(f.y*2.0-1.0)*hw);\n"
                       @"    o.hs=float2(len,s.param*0.5);\n"
                       @"  }else{\n"
                       @"    float2 lo=min(s.rect.xy,s.rect.zw);\n"
                       @"    float2 hi=max(s.rect.xy,s.rect.zw);\n"
                       @"    float2 ctr=(lo+hi)*0.5;float2 hs=(hi-lo)*0.5;\n"
                       @"    float2 grown=hs+1.0;\n"
                       @"    px=ctr+(f*2.0-1.0)*grown;\n"
                       @"    o.local=(f*2.0-1.0)*grown;o.hs=hs;\n"
                       @"  }\n"
                       @"  o.p=float4(px.x/size.x*2.0-1.0,1.0-px.y/size.y*2.0,0,1);\n"
                       @"  o.color=s.color;o.param=s.param;o.gab=s.extra.xyz;\n"
                       @"  o.kind=s.kind;return o;}\n"
                       // Noise helpers. THIS ARITHMETIC IS DUPLICATED in
                       // pmHash/noiseDeviate above and the two must match
                       // exactly, or NoiseValues will not describe what was
                       // shown. Both depend on uint32 wraparound.
                       @"uint pmHash(uint v){uint s=v*747796405u+2891336453u;\n"
                       @"  uint w=((s>>((s>>28)+4u))^s)*277803737u;return (w>>22)^w;}\n"
                       @"float pmUnit(uint k){return float(k)*2.3283064365386963e-10;}\n"
                       @"float pmDeviate(uint base,uint ch,bool nrm){\n"
                       @"  uint k=pmHash(base+ch*0x9E3779B9u);\n"
                       @"  if(!nrm) return pmUnit(k)*2.0-1.0;\n"
                       @"  float u1=pmUnit(k)*0.9999998+1e-7;\n"
                       @"  float u2=pmUnit(pmHash(k+1u));\n"
                       @"  return sqrt(-2.0*log(u1))*cos(6.28318530718*u2);}\n"
                       @"fragment float4 sfmain(SV in[[stage_in]]){\n"
                       @"  float2 p=in.local;float2 h=max(in.hs,float2(1e-6));float a=1.0;\n"
                       @"  float3 rgb=in.color.rgb;\n"
                       @"  if(in.kind==0u){\n"
                       @"    float2 d=abs(p)-h;a=saturate(0.5-max(d.x,d.y));\n"
                       @"  }else if(in.kind==1u){\n"
                       @"    float2 d=abs(p)-h;float outer=saturate(0.5-max(d.x,d.y));\n"
                       @"    float2 hi=max(h-in.param,float2(0.0));\n"
                       @"    float2 di=abs(p)-hi;float inner=saturate(0.5-max(di.x,di.y));\n"
                       @"    a=outer-inner;\n"
                       @"  }else if(in.kind==2u||in.kind==4u){\n"
                       @"    float r=length(p/h);float w=max(fwidth(r),1e-5);\n"
                       @"    a=1.0-smoothstep(1.0-w,1.0+w,r);\n"
                       @"  }else if(in.kind==3u){\n"
                       @"    float r=length(p/h);float w=max(fwidth(r),1e-5);\n"
                       @"    float outer=1.0-smoothstep(1.0-w,1.0+w,r);\n"
                       @"    float2 hi=max(h-in.param,float2(1e-6));\n"
                       @"    float ri=length(p/hi);float wi=max(fwidth(ri),1e-5);\n"
                       @"    float inner=1.0-smoothstep(1.0-wi,1.0+wi,ri);\n"
                       @"    a=outer-inner;\n"
                       @"  }else if(in.kind==6u){\n"
                       // Gabor: a sinusoidal carrier under a Gaussian envelope,
                       // both evaluated analytically, so no texture and no
                       // resolution dependence in the envelope. param is sigma
                       // as a fraction of the half-size. gab is (cycles per
                       // pixel, orientation, phase); p is already a pixel offset
                       // from the centre, so the frequency needs no rescaling.
                       //
                       // AT ZERO FREQUENCY THE CARRIER IS EXACTLY 1 and this
                       // reduces, bit for bit, to the plain Gaussian envelope
                       // this shape used to be. That is the documented contract
                       // for DrawGabor with no frequency argument.
                       @"    float2 q=p/h;float sg=max(in.param,1e-3);\n"
                       @"    a=exp(-dot(q,q)/(2.0*sg*sg));\n"
                       @"    if(in.gab.x>0.0){\n"
                       // y runs downwards in Psychtoolbox pixel coordinates, so
                       // the sign on the y term makes a positive orientation
                       // rotate counterclockwise on screen, which is what the
                       // vision literature means by orientation.
                       @"      float d=p.x*cos(in.gab.y)-p.y*sin(in.gab.y);\n"
                       @"      float c=cos(6.28318530718*in.gab.x*d+in.gab.z);\n"
                       @"      rgb=rgb*(0.5+0.5*c);\n"
                       @"    }\n"
                       @"  }else if(in.kind==7u){\n"
                       // White noise. gab is (seed, normal flag, colour flag);
                       // param is the spread; color.rgb is the mean. The pixel
                       // index is taken inside the rect so the same seed gives
                       // the same pattern wherever the patch is placed, which
                       // is what makes NoiseValues a plain [h x w] array.
                       @"    float2 q=p+h;\n"
                       @"    int ix=int(floor(q.x)),iy=int(floor(q.y));\n"
                       @"    int wp=int(2.0*h.x),hp=int(2.0*h.y);\n"
                       // The quad is inflated by a pixel for edge fading, which
                       // the other shapes need and this one must reject: a
                       // noise pixel outside the rect would be a bright fringe.
                       @"    if(ix<0||iy<0||ix>=wp||iy>=hp){a=0.0;}else{\n"
                       @"      uint sd=uint(in.gab.x);\n"
                       @"      uint base=pmHash(pmHash(pmHash(sd)+uint(ix))+uint(iy));\n"
                       @"      bool nrm=in.gab.y>0.5;\n"
                       @"      if(in.gab.z>0.5){\n"
                       @"        rgb=in.color.rgb+in.param*float3(pmDeviate(base,0u,nrm),\n"
                       @"            pmDeviate(base,1u,nrm),pmDeviate(base,2u,nrm));\n"
                       @"      }else{\n"
                       @"        rgb=in.color.rgb+in.param*pmDeviate(base,0u,nrm);\n"
                       @"      }\n"
                       @"      rgb=saturate(rgb);a=1.0;\n"
                       @"    }\n"
                       @"  }else{\n"
                       @"    a=saturate(h.y-abs(p.y)+0.5);\n"
                       @"  }\n"
                       @"  return float4(rgb,in.color.a*saturate(a));}\n"
                       // Textured quad. One draw per texture, so the uniforms
                       // go in as setVertexBytes rather than an instance buffer.
                       @"struct TU{float4 dst;float4 src;float4 tint;float2 size;"
                       @"float angle;float pad;};\n"
                       @"struct TV{float4 p[[position]];float2 uv;float4 tint;};\n"
                       @"vertex TV tvmain(uint vid[[vertex_id]],constant TU&u[[buffer(0)]]){\n"
                       @"  float2 c[4]={float2(0,0),float2(1,0),float2(0,1),float2(1,1)};\n"
                       @"  float2 f=c[vid];\n"
                       @"  float2 ctr=(u.dst.xy+u.dst.zw)*0.5;\n"
                       @"  float2 hs=(u.dst.zw-u.dst.xy)*0.5;\n"
                       @"  float2 lo=(f*2.0-1.0)*hs;\n"
                       @"  float ca=cos(u.angle),sa=sin(u.angle);\n"
                       @"  float2 px=ctr+float2(lo.x*ca-lo.y*sa,lo.x*sa+lo.y*ca);\n"
                       @"  TV o;o.p=float4(px.x/u.size.x*2.0-1.0,1.0-px.y/u.size.y*2.0,0,1);\n"
                       @"  o.uv=mix(u.src.xy,u.src.zw,f);o.tint=u.tint;return o;}\n"
                       @"fragment float4 tfmain(TV in[[stage_in]],"
                       @"texture2d<float> t[[texture(0)]],sampler s[[sampler(0)]]){\n"
                       @"  return t.sample(s,in.uv)*in.tint;}";
    NSError *shaderError = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&shaderError];
    if (!lib)
        failOpen("PsychMetal:Shader", [NSString stringWithFormat:@"Metal shader failed: %@",
                                       shaderError.localizedDescription]);
    MTLRenderPipelineDescriptor *sp = [MTLRenderPipelineDescriptor new];
    sp.vertexFunction = [lib newFunctionWithName:@"svmain"];
    sp.fragmentFunction = [lib newFunctionWithName:@"sfmain"];
    sp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Straight alpha, so a shape with alpha < 1 blends over the Screen image.
    sp.colorAttachments[0].blendingEnabled = YES;
    sp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    sp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    sp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    sp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    sp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    sp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    shapePipeline = [device newRenderPipelineStateWithDescriptor:sp error:&shaderError];
    if (!shapePipeline)
        failOpen("PsychMetal:Pipeline", [NSString stringWithFormat:@"Metal shape pipeline failed: %@",
                                         shaderError.localizedDescription]);
    for (int i = 0; i < PM_SHAPE_RING; i++) {
        shapeBuffers[i] = [device newBufferWithLength:PM_MAX_SHAPES * sizeof(PMShape)
                                              options:MTLResourceStorageModeShared];
        if (!shapeBuffers[i])
            failOpen("PsychMetal:Metal", @"Could not allocate the shape instance buffer.");
    }
    shapeBufferIndex = 0;
    shapeOverflow = false;
    drawCount = 0;

    MTLRenderPipelineDescriptor *tp = [MTLRenderPipelineDescriptor new];
    tp.vertexFunction = [lib newFunctionWithName:@"tvmain"];
    tp.fragmentFunction = [lib newFunctionWithName:@"tfmain"];
    tp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    tp.colorAttachments[0].blendingEnabled = YES;
    tp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    tp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    tp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    tp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    tp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    tp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    texturePipeline = [device newRenderPipelineStateWithDescriptor:tp error:&shaderError];
    if (!texturePipeline)
        failOpen("PsychMetal:Pipeline",
                 [NSString stringWithFormat:@"Metal texture pipeline failed: %@",
                  shaderError.localizedDescription]);

    // Two samplers, because Screen('DrawTexture') filterMode 0 means nearest and
    // that is not a nicety: an experiment drawing a noise or checkerboard
    // texture at 1:1 wants the exact pixels, and bilinear filtering would blur
    // them by a fraction of a pixel wherever the destination is not integral.
    MTLSamplerDescriptor *ls = [MTLSamplerDescriptor new];
    ls.minFilter = MTLSamplerMinMagFilterLinear;
    ls.magFilter = MTLSamplerMinMagFilterLinear;
    ls.sAddressMode = MTLSamplerAddressModeClampToEdge;
    ls.tAddressMode = MTLSamplerAddressModeClampToEdge;
    linearSampler = [device newSamplerStateWithDescriptor:ls];
    if (!linearSampler)
        failOpen("PsychMetal:Metal", @"Could not create the texture sampler.");

    MTLSamplerDescriptor *ns = [MTLSamplerDescriptor new];
    ns.minFilter = MTLSamplerMinMagFilterNearest;
    ns.magFilter = MTLSamplerMinMagFilterNearest;
    ns.sAddressMode = MTLSamplerAddressModeClampToEdge;
    ns.tAddressMode = MTLSamplerAddressModeClampToEdge;
    nearestSampler = [device newSamplerStateWithDescriptor:ns];
    if (!nearestSampler)
        failOpen("PsychMetal:Metal", @"Could not create the nearest-neighbour sampler.");

    // Through 0.3.1 a pair of IOSurfaces was allocated here, wrapped as OpenGL
    // textures with CGLTexImageIOSurface2D and attached to Psychtoolbox's
    // framebuffer, so that Screen could draw into something Metal could blit.
    // That was 43 MB of surfaces and the only reason this file needed a GL
    // context. Shapes and textures render straight into the drawable.
    memset(rec, 0, sizeof(rec));
    nextToken = 1;
    confirmedCount = 0;
    missingPresentedCount = 0;
    lastTargetErrorMs = NAN;
    lastConfirmDelayMs = NAN;
    inFlightCount = 0;
    lastConfirmedPresented = NAN;
    lastConfirmedProjected = NAN;
    pendingSlipRefreshes = 0.0;
    prefetchDrawable = 0;
    heldDrawable = nil;
    gridFirstPresented = gridLastPresented = 0;
    lastProjected = NAN;
    shapeOverflow = false;
    gridFirstFrame = gridLastFrame = 0;
    gridSamples = 0;
    measuredIFI = 0;
    directNoDrawableCount = 0;
    directTimeoutCount = 0;
    memset(leadSamples, 0, sizeof(leadSamples));
    leadCount = leadIndex = 0;
    leadEstimate = 0;
    memset(pipelineSamples, 0, sizeof(pipelineSamples));
    memset(gpuSamples, 0, sizeof(gpuSamples));
    pipelineCount = pipelineIndex = gpuCount = gpuIndex = 0;
    pipelineEstimate = gpuEstimate = 0;
    pthread_mutex_lock(&lock);
    closing = false;
    pthread_mutex_unlock(&lock);
    mexAtExit(closeCore);
}
static double gridPeriod(void) { return (measuredIFI > 0) ? measuredIFI : ifi; }

// First predicted refresh boundary at or after `t`, or NAN until a confirmed
// presentation has supplied an anchor. Caller holds the lock.
static double gridPointAtOrAfter(double t) {
    if (gridSamples == 0)
        return NAN;
    double period = gridPeriod();
    double k = ceil((t - gridLastPresented) / period - 1e-9);
    return gridLastPresented + k * period;
}

// Wait on the condition variable until `deadline`. False if Close began.
static bool sleepUntil(double deadline) {
    while (CACurrentMediaTime() < deadline) {
        if (closing)
            return false;
        waitRelative(deadline);
    }
    return !closing;
}

// Direct presentation: acquire a drawable, encode, present, commit, all on the
// calling (interpreter) thread. No display link is involved, so the frame is
// presented at the next refresh the GPU can make rather than at a slot two or
// three refreshes ahead. Entered with the lock held; always returns unlocked.
static uint64_t enqueueDirect(double when, bool haveWhen) {
    uint64_t t = nextToken++;
    Record *r = &rec[t % NREC];
    memset(r, 0, sizeof(*r));
    r->token = t;
    r->status = 2;
    r->requestedTime = haveWhen ? when : NAN;
    r->presentRequest = NAN;
    r->projected = NAN;

    // A deadline already in the past cannot be honoured: the frame will be
    // presented at the next available boundary. Clamp the request to now before
    // choosing a grid point, so the returned prediction is the boundary the
    // frame can actually reach rather than one that has already gone by. Without
    // this, Flip reported a presentation timestamp earlier than the call itself
    // and Missed came back negative for a missed deadline.
    double target = haveWhen ? gridPointAtOrAfter(fmax(when, CACurrentMediaTime())) : NAN;
    if (isfinite(target)) {
        // BOUND THE POOL. DO NOT SCHEDULE.
        //
        // Apple places the frame; see presentDrawable:atTime: below. Nothing
        // here decides which boundary it reaches. Two things do need bounding,
        // both about drawable occupancy rather than timing.
        //
        // FIRST, frames in flight. A frame holds its drawable from commit until
        // presentation, and with nothing to stop it the loop runs as far ahead
        // as the pool allows: at an eight-refresh cadence that measured a
        // commit 15.65 refreshes before the target and 60% of frames late. Two
        // outstanding frames leave a third drawable free at any cadence.
        //
        // SECOND, genuinely distant targets. A request three seconds out would
        // otherwise hold a drawable for three seconds, and two of those stall
        // the loop completely. So sleep for those - but only for those. The
        // threshold is far beyond any stimulus cadence, and the sleep stops
        // twelve refreshes short of the target, which is past the range where
        // cadence was measured (1 to 12 refreshes, 0 to 1% late). It cannot
        // influence which boundary is chosen.
        //
        // An earlier version deferred every target beyond four refreshes and
        // put a four-refresh request a full refresh late on 96% of frames. The
        // rule is: defer only to protect the pool, never to place the frame.
        const double kHoldLimit = 15.0;   // refreshes; beyond this, sleep
        const double kWakeLead  = 12.0;   // refreshes before target to wake
        double aheadRefreshes = (target - CACurrentMediaTime()) / gridPeriod();
        if (aheadRefreshes > kHoldLimit) {
            double submitAt = target - kWakeLead * gridPeriod();
            bool ok = sleepUntil(submitAt);
            if (!ok) {
                pthread_mutex_unlock(&lock);
                fail("Close interrupted a scheduled presentation.");
            }
        }

        double poolDeadline = CACurrentMediaTime() + 2.0;
        while (inFlightCount >= 2)
            if (waitRelative(poolDeadline) == ETIMEDOUT)
                break;
    }
    double now = CACurrentMediaTime();
    // Fallback prediction. Before any confirmed presentation there is no grid
    // anchor, so estimate the next boundary as one refresh out rather than
    // returning NAN: Flip must always return a usable timestamp.
    // REPORT the previous frame's slip; do NOT feed it back into the
    // prediction. Re-anchoring lastProjected to the last confirmed
    // presentation was tried and made things much worse: scheduled-gap
    // failures went from 6 in 508 to 120, in a stable limit cycle where the
    // returned timestamp lagged the confirmed presentation by exactly one
    // refresh for the rest of the run. The presentations themselves stayed on
    // the requested cadence; it was the number handed back to the caller that
    // drifted. Re-anchoring the internal clamp without also correcting the
    // returned value is worse than not re-anchoring at all.
    double slip = 0.0;
    if (isfinite(lastConfirmedPresented) && isfinite(lastConfirmedProjected)) {
        double err = (lastConfirmedPresented - lastConfirmedProjected) / gridPeriod();
        slip = (fabs(err) >= 0.5) ? (double)llround(err) : 0.0;
    }
    pendingSlipRefreshes = slip;

    // PROVISIONAL. The real prediction is made after the commit, below, once
    // committedAt is known. This value only fills the record in the paths that
    // return early without ever committing.
    double predicted = isfinite(target) ? target : gridPointAtOrAfter(now);
    if (!isfinite(predicted))
        predicted = now + ifi;
    // Never report a presentation at or before the previous one.
    if (isfinite(lastProjected) && predicted <= lastProjected + 0.5 * gridPeriod())
        predicted = lastProjected + gridPeriod();
    // lastProjected is deliberately NOT advanced here. The post-commit block
    // below makes the real prediction and applies the same monotonic clamp; if
    // this provisional value were published first, that clamp would compare the
    // prediction against itself, find it not greater, and push every frame a
    // full refresh into the future. It did exactly that, and the 30-refresh
    // hold reported Missed +8.33 ms instead of -8.33.
    r->projected = predicted;
    r->presentRequest = target;
    r->scheduledAt = now;
    r->scheduled = 1;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);

    // Use the drawable acquired at the end of the previous Flip if there is one.
    id<CAMetalDrawable> d = heldDrawable;
    heldDrawable = nil;
    if (!d)
        d = layer.nextDrawable;
    if (!d) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(t);
        if (q) {
            q->status = 4;
            q->done = 1;
            q->gpuDone = 1;
        }
        directNoDrawableCount++;
        // Nothing was committed, so the provisional prediction is all there is.
        lastProjected = predicted;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        return t;
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!encodeFrame(cb, d)) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(t);
        if (q) {
            q->status = 3;
            q->done = 1;
            q->gpuDone = 1;
        }
        lastProjected = predicted;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        return t;
    }
    attachHandlers(cb, d, t);
    // inFlight must be raised before commit: the completion handler can run
    // immediately afterwards and would otherwise decrement a count never raised.
    pthread_mutex_lock(&lock);
    Record *q = recordFor(t);
    if (q) {
        q->inFlight = 1;
        q->committedAt = CACurrentMediaTime();
        inFlightCount++;
    }
    pthread_mutex_unlock(&lock);
    // TWO GUARDS, because one is not enough in both directions.
    //
    // Commit timing bounds the frame from being LATE. Sleeping into cycle
    // N-2 means the frame is ready with a boundary to spare.
    //
    // atTime bounds it from being EARLY. The commit-to-present rule is not
    // a constant: it is two boundaries when the pipeline is busy, but about
    // one when the queue has been drained, which section 7 recorded as a
    // 1.035 refresh floor. A 30-refresh hold drains it, and committing 1.5
    // refreshes ahead then landed the frame a full refresh EARLY.
    //
    // atTime must NOT be the target itself. A target is a grid point, and a
    // grid point is the instant a latch deadline closes, so asking for
    // exactly that made the outcome turn on a sub-microsecond phase fixed
    // at window open: deterministic within a run, different between runs.
    // Half a refresh earlier is unambiguously inside the preceding cycle,
    // and the first boundary at or after it is the target either way.
    if (isfinite(target))
        [cb presentDrawable:d atTime:(target - 0.5 * gridPeriod())];
    else
        [cb presentDrawable:d];
    [cb commit];

    // PREDICT FROM THE COMMIT, AT THE SECOND BOUNDARY.
    //
    // Nothing about this needs estimating. The refresh grid is fitted to
    // confirmed presentedTime samples and is good to 0.03 microseconds RMS, and
    // the anchor is itself a confirmed presentation, so any future boundary is
    // just anchor + n * period. The only unknown is the integer n, and that was
    // measured: commit to presented is 1.751 refreshes with p01 1.710 and p99
    // 1.843 over 300 frames, so the frame lands on the SECOND grid point at or
    // after the commit, without exception.
    //
    // The old prediction took the FIRST grid point at or after `now`, where
    // `now` was sampled before nextDrawable and before the commit. Wrong
    // reference point and wrong index, which is why the returned timestamp
    // disagreed with the confirmed presentation by a full refresh on half the
    // frames.
    //
    // A scheduled target cannot be honoured earlier than that boundary either,
    // so it is raised to it rather than reported as though it were reachable.
    pthread_mutex_lock(&lock);
    Record *pr = recordFor(t);
    if (pr && pr->committedAt > 0.0) {
        // gridPointAtOrAfter returns NaN until the grid has an anchor, which
        // needs one confirmed presentation. The FIRST few flips after
        // OpenWindow therefore have no grid, and this arithmetic used to
        // propagate the NaN straight into the record: Flip returned NaN as the
        // presentation time, and a caller doing the standard
        // vbl + (n - 0.5) * ifi then passed NaN back in and was told its
        // `when` was not finite. Every timing test warms up first and never
        // saw it; PsychMetalInventoryTest, which flips a handful of times from
        // a cold window, did.
        //
        // With no grid, fall back to the provisional estimate computed above,
        // which is a plain now + ifi. It is worse than the grid answer by
        // whatever the phase error happens to be, and it is finite.
        double earliest = gridPointAtOrAfter(pr->committedAt) + gridPeriod();
        double pred;
        if (isfinite(earliest))
            pred = isfinite(target) ? fmax(target, earliest) : earliest;
        else
            pred = isfinite(target) ? target : predicted;
        if (!isfinite(pred))
            pred = predicted;
        // Monotonic: never report a presentation at or before the previous one.
        if (isfinite(lastProjected) && pred <= lastProjected + 0.5 * gridPeriod())
            pred = lastProjected + gridPeriod();
        if (isfinite(pred)) {
            lastProjected = pred;
            pr->projected = pred;
        }
    }
    pthread_mutex_unlock(&lock);

    // Take the next frame's drawable now, so this call absorbs the wait rather
    // than the next one. Blocks here instead of after the caller's next input
    // sample, which is the entire point.
    if (prefetchDrawable && !heldDrawable)
        heldDrawable = layer.nextDrawable;
    return t;
}
// Phase one: everything except the swap. Returns with the drawable held and
// the command buffer scheduled, so PresentNow has only one call left to make.
static uint64_t prepareFlip(void) {
    if (preparedToken)
        fail("A frame is already prepared; call PresentNow before preparing another.");

    pthread_mutex_lock(&lock);
    uint64_t t = nextToken++;
    Record *r = &rec[t % NREC];
    memset(r, 0, sizeof(*r));
    r->token = t;
    r->status = 2;
    r->requestedTime = NAN;
    r->presentRequest = NAN;
    r->projected = NAN;
    pthread_mutex_unlock(&lock);

    id<CAMetalDrawable> d = layer.nextDrawable;
    if (!d) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(t);
        if (q) { q->status = 4; q->done = 1; q->gpuDone = 1; q->scheduled = 1; }
        directNoDrawableCount++;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        return t;
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!encodeFrame(cb, d)) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(t);
        if (q) { q->status = 3; q->done = 1; q->gpuDone = 1; q->scheduled = 1; }
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        return t;
    }
    attachHandlers(cb, d, t);
    pthread_mutex_lock(&lock);
    Record *q = recordFor(t);
    if (q) {
        q->inFlight = 1;
        q->committedAt = CACurrentMediaTime();
        inFlightCount++;
    }
    pthread_mutex_unlock(&lock);
    [cb commit];
    [cb waitUntilScheduled];

    preparedDrawable = d;
    preparedToken = t;
    return t;
}

// Phase two: the swap, and nothing else.
static void presentNow(double *outTime, double *outCallMs) {
    if (!preparedToken)
        fail("No prepared frame; call PrepareFlip first.");
    id<CAMetalDrawable> d = preparedDrawable;
    uint64_t t = preparedToken;
    preparedDrawable = nil;
    preparedToken = 0;
    double t0 = CACurrentMediaTime();
    [d present];
    double t1 = CACurrentMediaTime();
    pthread_mutex_lock(&lock);
    Record *r = recordFor(t);
    if (r) {
        r->scheduledAt = t0;
        r->presentCallMs = (t1 - t0) * 1000.0;
        r->scheduled = 1;
    }
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    if (outTime) *outTime = t0;
    if (outCallMs) *outCallMs = (t1 - t0) * 1000.0;
}
static uint64_t enqueue(double when, bool haveWhen) {
    pthread_mutex_lock(&lock);
    return enqueueDirect(when, haveWhen);
}
static Record waitScheduled(uint64_t t, double timeoutAt) {
    pthread_mutex_lock(&lock);
    Record *r = recordFor(t);
    if (!r) {
        pthread_mutex_unlock(&lock);
        fail("Unknown or expired frame token.");
    }
    // The frame is already submitted when enqueueDirect returns, so there is
    // nothing to wait for unless the caller wants the CONFIRMED presentedTime
    // rather than the prediction. That costs the whole submit-to-present lead,
    // which exceeds a refresh, so it halves the achievable rate and is off by
    // default; Flip returns the predicted grid boundary instead and the
    // confirmations arrive asynchronously for Diagnostic.
    if (directWaitForConfirm)
        while (!r->done)
            if (waitRelative(timeoutAt) == ETIMEDOUT) {
                directTimeoutCount++;
                break;
            }
    Record out = *r;
    pthread_mutex_unlock(&lock);
    return out;
}
static void drainRecords(void) {
    pthread_mutex_lock(&lock);
    double d = CACurrentMediaTime() + 2.0;
    while (inFlightCount > 0)
        if (waitRelative(d) == ETIMEDOUT)
            break;
    pthread_mutex_unlock(&lock);
}
static mxArray *historyMatrix(void) {
    std::vector<Record> snapshot;
    pthread_mutex_lock(&lock);
    uint64_t end = nextToken;
    uint64_t start = (end > NREC) ? end - NREC : 1;
    mwSize count = (mwSize)(end - start);
    snapshot.reserve(count);
    for (uint64_t t = start; t < end; t++) {
        Record *r = recordFor(t);
        snapshot.push_back(r ? *r : Record{});
    }
    pthread_mutex_unlock(&lock);
    // Thirteen columns. Six more existed until 0.4.0 and every one of them
    // reported something only the CAMetalDisplayLink path could produce: its
    // tick counter, Apple's raw and corrected target timestamps, and the
    // missed/slipped tick counts derived from them. With that path gone they
    // were structurally zero.
    mxArray *out = mxCreateDoubleMatrix(count, 13, mxREAL);
    double *v = mxGetPr(out);
    for (mwSize row = 0; row < count; row++) {
        const Record *r = &snapshot[row];
        v[row + count * 0] = (double)r->token;
        v[row + count * 1] = r->projected;
        v[row + count * 2] = r->presented;
        v[row + count * 3] = r->done ? r->status : 2;
        v[row + count * 4] = r->scheduledAt;
        v[row + count * 5] = r->callback;
        v[row + count * 6] = (double)r->commandStatus;
        v[row + count * 7] = r->requestedTime;
        v[row + count * 8] = r->gpuStart;
        v[row + count * 9] = r->gpuEnd;
        v[row + count * 10] = r->presentRequest;
        v[row + count * 11] = r->presentCallMs;
        v[row + count * 12] = r->committedAt;
    }
    return out;
}

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    @autoreleasepool {
        if (nrhs < 1)
            fail("Command required.");
        if (cmd(prhs[0], "PrepareApp")) {
            if (nrhs != 1 || nlhs != 0)
                fail("PrepareApp takes no arguments or outputs.");
            prepareApp();
            return;
        }
        if (cmd(prhs[0], "Open")) {
            // Open(screenIndex, drawableCount[, waitForConfirm
            //      [, displaySync[, captureDisplay]]])
            //   -> [width, height, ifi, pointWidth, pointHeight]
            //
            // GEOMETRY AND REFRESH NOW COME FROM CORE GRAPHICS, not from
            // Psychtoolbox. Through 0.3.1 the wrapper opened a Screen window
            // purely to hand width, height and the flip interval back to this
            // function, along with an OpenGL texture to attach an IOSurface to.
            // None of that is needed: CGDisplayBounds gives the geometry and
            // CGDisplayModeGetRefreshRate the nominal rate, after which the
            // fitted refresh grid supersedes it anyway. Removing it removes the
            // Psychtoolbox window, its sync tests and its startup warnings,
            // which described a window that never flipped.
            if ((nrhs < 3 || nrhs > 6) || nlhs != 5)
                fail("Open needs screenIndex,drawableCount[,waitForConfirm"
                     "[,displaySync[,captureDisplay]]] "
                     "and returns width,height,ifi,pointWidth,pointHeight.");
            // -1 means the last active display, which is what
            // max(Screen('Screens')) resolved to and is the usual choice for a
            // stimulus display on a two-monitor rig.
            double screenIndex = scalar(prhs[1], "screen index");
            if (screenIndex != floor(screenIndex) || screenIndex < -1)
                fail("screen index must be a non-negative integer, or -1 for the last display.");
            uint64_t drawableCount = unsignedScalar(prhs[2], "maximum drawable count", 3);
            if (drawableCount < 2)
                fail("Drawable count must be 2 or 3.");
            bool waitConfirm = true;
            bool vsync = true;
            bool doCapture = true;
            if (nrhs >= 6)
                doCapture = unsignedScalar(prhs[5], "capture display", 1) != 0;
            if (nrhs >= 5)
                vsync = unsignedScalar(prhs[4], "display sync", 1) != 0;
            if (nrhs >= 4)
                waitConfirm = unsignedScalar(prhs[3], "wait for confirmation", 1) != 0;

            // Resolve the display before opening, so a bad screen index fails
            // here rather than half way through window creation.
            uint32_t count = 0;
            CGDirectDisplayID ids[16];
            if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || count == 0)
                fail("No active displays.");
            if (screenIndex < 0)
                screenIndex = (double)count - 1;
            if ((uint32_t)screenIndex >= count)
                mexErrMsgIdAndTxt("PsychMetal:Screen",
                    "Screen index %d is out of range; %u display(s) are active.",
                    (int)screenIndex, count);
            // Psychtoolbox numbers screens with 0 as the main display, which is
            // the order CGGetActiveDisplayList returns, so indices match what a
            // caller migrating from Screen('Screens') already uses.
            CGDirectDisplayID did = ids[(uint32_t)screenIndex];
            CGRect b = CGDisplayBounds(did);
            size_t pxW = CGDisplayPixelsWide(did), pxH = CGDisplayPixelsHigh(did);
            CGDisplayModeRef dm = CGDisplayCopyDisplayMode(did);
            double hz = dm ? CGDisplayModeGetRefreshRate(dm) : 0.0;
            if (dm) {
                // The backing store can exceed the mode's point size on a
                // Retina panel, and the drawable is sized in pixels.
                size_t mw = CGDisplayModeGetPixelWidth(dm);
                size_t mh = CGDisplayModeGetPixelHeight(dm);
                if (mw && mh) { pxW = mw; pxH = mh; }
                CGDisplayModeRelease(dm);
            }
            // A refresh rate of 0 means the display does not report one, which
            // built-in Apple panels do. 60 is the documented fallback, and the
            // fitted grid replaces it within a hundred frames anyway.
            if (!(hz > 0.0))
                hz = 60.0;
            double period = 1.0 / hz;
            if (!pxW || !pxH)
                fail("Could not determine the display's pixel size.");

            // Black until the wrapper says otherwise, so a colour left over
            // from a previous window in this session cannot leak into a new one.
            clearRGBA[0] = clearRGBA[1] = clearRGBA[2] = 0.0f;
            clearRGBA[3] = 1.0f;
            openCore((NSUInteger)pxW, (NSUInteger)pxH, period,
                     (NSInteger)screenIndex,
                     b.origin.x, b.origin.y,
                     b.origin.x + b.size.width, b.origin.y + b.size.height,
                     (NSUInteger)drawableCount, waitConfirm, vsync, doCapture);
            plhs[0] = mxCreateDoubleScalar((double)pxW);
            plhs[1] = mxCreateDoubleScalar((double)pxH);
            plhs[2] = mxCreateDoubleScalar(period);
            // Point size as well as pixel size. GetMouse reports points and
            // every drawing command takes pixels, so the caller needs both to
            // convert between them; on a Retina panel they differ by the
            // backing scale, and in a scaled mode by something that is not an
            // integer.
            plhs[3] = mxCreateDoubleScalar(b.size.width);
            plhs[4] = mxCreateDoubleScalar(b.size.height);
            return;
        }
        if (cmd(prhs[0], "Queue")) {
            if ((nrhs != 1 && nrhs != 2) || nlhs != 1)
                fail("Queue takes an optional presentation time.");
            bool haveWhen = nrhs == 2;
            double when = haveWhen ? scalar(prhs[1], "presentation time") : 0;
            plhs[0] = mxCreateDoubleScalar(enqueue(when, haveWhen));
            return;
        }
        if (cmd(prhs[0], "WaitScheduled")) {
            if ((nrhs != 2 && nrhs != 3) || nlhs != 1)
                fail("WaitScheduled needs a token and optional presentation time.");
            double timeoutAt = CACurrentMediaTime() + 2.0;
            if (nrhs == 3) {
                double when = scalar(prhs[2], "presentation time");
                if (when + 2.0 > timeoutAt)
                    timeoutAt = when + 2.0;
            }
            Record r = waitScheduled(unsignedScalar(prhs[1], "frame token", UINT64_MAX), timeoutAt);
            bool confirmed = (r.status == 0 && r.presented > 0);
            plhs[0] = mxCreateDoubleMatrix(1, 6, mxREAL);
            double *v = mxGetPr(plhs[0]);
            // Direct mode with WaitForConfirm returns the measured presentedTime.
            // Otherwise this is the predicted boundary, as in 0.2.0.
            v[0] = confirmed ? r.presented : r.projected;
            v[1] = r.scheduled ? 0 : 2;
            v[2] = 0;
            v[3] = 0;
            v[4] = confirmed ? 1 : 0;
            // Refreshes by which the PREVIOUS confirmed presentation missed its
            // prediction. Nonzero means a frame was already dropped.
            v[5] = pendingSlipRefreshes;
            return;
        }
        if (cmd(prhs[0], "PrepareFlip")) {
            if (nrhs != 1 || nlhs != 1)
                fail("PrepareFlip takes no arguments and one output.");
            plhs[0] = mxCreateDoubleScalar(prepareFlip());
            return;
        }
        if (cmd(prhs[0], "PresentNow")) {
            if (nrhs != 1 || nlhs != 1)
                fail("PresentNow takes no arguments and one output.");
            double when = 0, callMs = 0;
            presentNow(&when, &callMs);
            plhs[0] = mxCreateDoubleMatrix(1, 2, mxREAL);
            double *v = mxGetPr(plhs[0]);
            v[0] = when;
            v[1] = callMs;
            return;
        }
        if (cmd(prhs[0], "SetDisplaySync")) {
            if (nrhs != 2 || nlhs != 0)
                fail("SetDisplaySync needs one flag and no outputs.");
            if (!layer)
                fail("PsychMetal is not open.");
            __block BOOL on = unsignedScalar(prhs[1], "display sync", 1) != 0 ? YES : NO;
            onMainSync(^{ layer.displaySyncEnabled = on; });
            pthread_mutex_lock(&lock);
            displaySync = (on == YES);
            pthread_mutex_unlock(&lock);
            return;
        }
        if (cmd(prhs[0], "GridAnchor")) {
            if (nrhs != 1 || nlhs != 1)
                fail("GridAnchor takes no arguments and one output.");
            pthread_mutex_lock(&lock);
            double anchor = (gridSamples > 0) ? gridLastPresented : NAN;
            double period = gridPeriod();
            double n = (double)gridSamples;
            pthread_mutex_unlock(&lock);
            plhs[0] = mxCreateDoubleMatrix(1, 3, mxREAL);
            double *v = mxGetPr(plhs[0]);
            v[0] = anchor; v[1] = period; v[2] = n;
            return;
        }
        if (cmd(prhs[0], "NextPhase")) {
            // Next time at a given fractional phase within the refresh cycle,
            // at or after `after`. Phase 0 is a refresh boundary.
            if (nrhs != 3 || nlhs != 1)
                fail("NextPhase needs a time, a phase and one output.");
            double after = scalar(prhs[1], "time");
            double phase = scalar(prhs[2], "phase");
            pthread_mutex_lock(&lock);
            double t = NAN;
            if (gridSamples > 0) {
                double p = gridPeriod();
                double base = gridLastPresented + phase * p;
                double k = ceil((after - base) / p - 1e-9);
                t = base + k * p;
            }
            pthread_mutex_unlock(&lock);
            plhs[0] = mxCreateDoubleScalar(t);
            return;
        }
        if (cmd(prhs[0], "NextRefresh")) {
            if (nrhs != 2 || nlhs != 1)
                fail("NextRefresh needs one time and one output.");
            double after = scalar(prhs[1], "time");
            pthread_mutex_lock(&lock);
            double next = gridPointAtOrAfter(after);
            pthread_mutex_unlock(&lock);
            plhs[0] = mxCreateDoubleScalar(next);
            return;
        }
        if (cmd(prhs[0], "WaitToDraw")) {
            if (nrhs != 3 || nlhs != 1)
                fail("WaitToDraw needs a target presentation time and a drawing budget.");
            double target = scalar(prhs[1], "target presentation time");
            double budget = scalar(prhs[2], "drawing budget");
            if (budget < 0)
                fail("Drawing budget must be nonnegative.");
            pthread_mutex_lock(&lock);
            // Before enough confirmations exist, assume the unthrottled depth so
            // the first frames are submitted early rather than late.
            // Work backwards from the target through the parts of the pipeline
            // that are measured rather than chosen: presentation pipeline, GPU
            // pass, submission overhead, then the caller's drawing budget.
            double pipeline = (pipelineEstimate > 0) ? pipelineEstimate : (1.7 * ifi);
            double gpu = (gpuEstimate > 0) ? gpuEstimate : 0.002;
            double lead = pipeline + gpu + 0.002;
            double deadline = target - lead - budget;
            if (deadline > CACurrentMediaTime())
                sleepUntil(deadline);
            double wokeAt = CACurrentMediaTime();
            pthread_mutex_unlock(&lock);
            plhs[0] = mxCreateDoubleMatrix(1, 3, mxREAL);
            double *v = mxGetPr(plhs[0]);
            v[0] = wokeAt;
            v[1] = lead;
            v[2] = deadline;
            return;
        }
        if (cmd(prhs[0], "PrefetchDrawable")) {
            if (nrhs != 2 || nlhs != 0)
                fail("PrefetchDrawable takes one logical argument.");
            if (!device)
                fail("PsychMetal is not open.");
            if ((!mxIsNumeric(prhs[1]) && !mxIsLogical(prhs[1])) ||
                mxGetNumberOfElements(prhs[1]) != 1)
                fail("PrefetchDrawable takes one logical argument.");
            prefetchDrawable = (mxGetScalar(prhs[1]) != 0.0) ? 1 : 0;
            if (!prefetchDrawable)
                heldDrawable = nil;
            return;
        }
        if (cmd(prhs[0], "NoiseValues")) {
            // NoiseValues(width, height, seed, normalFlag, colourFlag,
            //             mean[1x3], spread) -> [h x w] or [h x w x 3] double.
            //
            // Recomputes on the CPU exactly what the shader draws, from the
            // seed alone, so a session stores one integer per frame instead of
            // a 21 MB array and can still reconstruct the stimulus afterwards
            // for reverse correlation.
            //
            // It shares pmHash and noiseDeviate with nothing else in this file
            // BUT duplicates them in the Metal source, which is the one place
            // this design can go wrong. See the note on pmHash.
            if (nrhs != 8 || nlhs != 1)
                fail("NoiseValues needs width,height,seed,normal,colour,mean,spread.");
            double dw = scalar(prhs[1], "width"), dh = scalar(prhs[2], "height");
            if (dw < 1 || dh < 1 || dw != floor(dw) || dh != floor(dh))
                fail("Noise width and height must be positive integers.");
            double dseed = scalar(prhs[3], "seed");
            if (dseed < 0 || dseed > 16777215.0 || dseed != floor(dseed))
                fail("Seed must be an integer from 0 to 16777215.");
            bool normal = scalar(prhs[4], "normal flag") != 0.0;
            bool colour = scalar(prhs[5], "colour flag") != 0.0;
            if (!mxIsDouble(prhs[6]) || mxGetNumberOfElements(prhs[6]) != 3)
                fail("Noise mean must be a 3-element RGB vector.");
            const double *mean = mxGetPr(prhs[6]);
            double spread = scalar(prhs[7], "spread");
            size_t W = (size_t)dw, H = (size_t)dh;
            uint32_t seed = (uint32_t)dseed;
            mwSize dims[3] = {(mwSize)H, (mwSize)W, 3};
            plhs[0] = mxCreateNumericArray(colour ? 3 : 2, dims, mxDOUBLE_CLASS, mxREAL);
            double *out = mxGetPr(plhs[0]);
            // Column-major, and the shader's ix is the column: element (iy, ix)
            // sits at iy + ix*H, which is the loop order below.
            for (size_t ix = 0; ix < W; ix++) {
                for (size_t iy = 0; iy < H; iy++) {
                    uint32_t base = noiseBase(seed, (uint32_t)ix, (uint32_t)iy);
                    size_t o = iy + ix * H;
                    if (colour) {
                        for (uint32_t c = 0; c < 3; c++) {
                            double v = mean[c] + spread * noiseDeviate(base, c, normal);
                            out[o + c * W * H] = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
                        }
                    } else {
                        double v = mean[0] + spread * noiseDeviate(base, 0, normal);
                        out[o] = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
                    }
                }
            }
            return;
        }
        if (cmd(prhs[0], "Modes")) {
            // Modes(screenIndex) -> [width height pixelWidth pixelHeight hz] per row,
            // with the CURRENT mode first.
            //
            // Display-mode management is the last thing PsychMetal needed
            // Psychtoolbox for, and it is Core Graphics underneath either way.
            if (nrhs != 2 || nlhs != 1)
                fail("Modes needs a screen index and returns one matrix.");
            uint32_t count = 0;
            CGDirectDisplayID ids[16];
            if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || count == 0)
                fail("No active displays.");
            double si = scalar(prhs[1], "screen index");
            if (si < 0) si = (double)count - 1;
            if (si != floor(si) || (uint32_t)si >= count)
                fail("Screen index is out of range.");
            CGDirectDisplayID did = ids[(uint32_t)si];

            // Ask for the scaled duplicates too. Without this the HiDPI modes
            // are hidden, and those are exactly the ones a Retina panel runs.
            const void *keys[] = { kCGDisplayShowDuplicateLowResolutionModes };
            const void *vals[] = { kCFBooleanTrue };
            CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFArrayRef all = CGDisplayCopyAllDisplayModes(did, opts);
            if (opts) CFRelease(opts);
            if (!all)
                fail("Could not list display modes.");
            CFIndex n = CFArrayGetCount(all);
            CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
            plhs[0] = mxCreateDoubleMatrix((mwSize)n, 5, mxREAL);
            double *v = mxGetPr(plhs[0]);
            mwSize row = 0;
            // Current mode first, so a caller can save row 1 and restore it.
            for (CFIndex pass = 0; pass < 2; pass++) {
                for (CFIndex i = 0; i < n; i++) {
                    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
                    bool isCur = cur && CFEqual(m, cur);
                    if ((pass == 0) != isCur)
                        continue;
                    double hz = CGDisplayModeGetRefreshRate(m);
                    if (!(hz > 0.0)) hz = 60.0;
                    v[row + n * 0] = (double)CGDisplayModeGetWidth(m);
                    v[row + n * 1] = (double)CGDisplayModeGetHeight(m);
                    v[row + n * 2] = (double)CGDisplayModeGetPixelWidth(m);
                    v[row + n * 3] = (double)CGDisplayModeGetPixelHeight(m);
                    v[row + n * 4] = hz;
                    row++;
                }
            }
            if (cur) CGDisplayModeRelease(cur);
            CFRelease(all);
            return;
        }
        if (cmd(prhs[0], "SetMode")) {
            // SetMode(screenIndex, width, height) -> 1 if the mode changed.
            //
            // Point size, matching Screen('Resolution'). The first mode whose
            // point size matches and whose pixel size is largest is chosen, so
            // a HiDPI variant wins over its low-resolution duplicate.
            if (nrhs != 4 || nlhs != 1)
                fail("SetMode needs screenIndex, width and height.");
            if (device)
                fail("Close the PsychMetal window before changing the display mode.");
            uint32_t count = 0;
            CGDirectDisplayID ids[16];
            if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || count == 0)
                fail("No active displays.");
            double si = scalar(prhs[1], "screen index");
            if (si < 0) si = (double)count - 1;
            if (si != floor(si) || (uint32_t)si >= count)
                fail("Screen index is out of range.");
            CGDirectDisplayID did = ids[(uint32_t)si];
            double wantW = scalar(prhs[2], "width"), wantH = scalar(prhs[3], "height");

            const void *keys[] = { kCGDisplayShowDuplicateLowResolutionModes };
            const void *vals[] = { kCFBooleanTrue };
            CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFArrayRef all = CGDisplayCopyAllDisplayModes(did, opts);
            if (opts) CFRelease(opts);
            if (!all)
                fail("Could not list display modes.");
            CGDisplayModeRef best = NULL;
            size_t bestPixels = 0;
            for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
                if ((double)CGDisplayModeGetWidth(m) != wantW ||
                    (double)CGDisplayModeGetHeight(m) != wantH)
                    continue;
                size_t px = CGDisplayModeGetPixelWidth(m) * CGDisplayModeGetPixelHeight(m);
                if (px >= bestPixels) { bestPixels = px; best = m; }
            }
            if (!best) {
                CFRelease(all);
                mexErrMsgIdAndTxt("PsychMetal:Mode",
                    "No display mode is %g x %g points on that display.", wantW, wantH);
            }
            CGError e = CGDisplaySetDisplayMode(did, best, NULL);
            CFRelease(all);
            if (e != kCGErrorSuccess)
                mexErrMsgIdAndTxt("PsychMetal:Mode",
                    "CGDisplaySetDisplayMode failed with error %d.", (int)e);
            plhs[0] = mxCreateDoubleScalar(1);
            return;
        }
        if (cmd(prhs[0], "Cursor")) {
            // Cursor(show) -> hide or show the pointer.
            //
            // Psychtoolbox's HideCursor is Screen('HideCursorHelper'), so it
            // pulls in the whole Screen mex and prints its startup banner for
            // what is, on macOS, one Core Graphics call. Doing it here keeps a
            // PsychMetal-only session free of Psychtoolbox output entirely.
            //
            // Display-scoped rather than [NSCursor hide], which only applies
            // while the cursor is over one of this application's windows and is
            // therefore unreliable behind a captured display.
            if (nrhs != 2 || nlhs != 0)
                fail("Cursor takes one logical argument.");
            bool show = scalar(prhs[1], "show cursor") != 0.0;
            CGDirectDisplayID d = selectedDisplayID ? selectedDisplayID
                                                    : CGMainDisplayID();
            if (show)
                CGDisplayShowCursor(d);
            else
                CGDisplayHideCursor(d);
            return;
        }
        if (cmd(prhs[0], "Mouse")) {
            // Mouse() -> [x, y, buttons] in PIXELS on the presentation display.
            //
            // Psychtoolbox's GetMouse is Screen('GetMouseHelper') and reports
            // points with the origin at the bottom left of the main display.
            // Everything drawn here is in pixels with the origin at the top
            // left of the presentation display, so the wrapper had to convert
            // by a scale factor it obtained from Screen. Reading NSEvent
            // directly and converting here removes both the Screen call and the
            // conversion the caller could get wrong.
            if (nrhs != 1 || nlhs != 3)
                fail("Mouse takes no arguments and returns x, y and buttons.");
            NSPoint p = [NSEvent mouseLocation];
            NSUInteger mask = [NSEvent pressedMouseButtons];
            CGDirectDisplayID d = selectedDisplayID ? selectedDisplayID
                                                    : CGMainDisplayID();
            CGRect b = CGDisplayBounds(d);
            // NSEvent's origin is the bottom left of the primary screen and y
            // increases upwards; CGDisplayBounds is top-left origin, y down.
            CGFloat primaryH = CGDisplayBounds(CGMainDisplayID()).size.height;
            double gx = p.x, gy = primaryH - p.y;
            // Into this display's own space, then points to pixels.
            double sx = (b.size.width > 0) ? (double)CGDisplayPixelsWide(d) / b.size.width : 1.0;
            double sy = (b.size.height > 0) ? (double)CGDisplayPixelsHigh(d) / b.size.height : 1.0;
            plhs[0] = mxCreateDoubleScalar((gx - b.origin.x) * sx);
            plhs[1] = mxCreateDoubleScalar((gy - b.origin.y) * sy);
            mxArray *btn = mxCreateLogicalMatrix(1, 3);
            mxLogical *bv = mxGetLogicals(btn);
            for (int i = 0; i < 3; i++)
                bv[i] = (mask & (1u << i)) ? 1 : 0;
            plhs[2] = btn;
            return;
        }
        if (cmd(prhs[0], "Keys")) {
            // Keys() -> [keyIsDown, secs, keyCode(1x256 logical), secureInput]
            //
            // Every keyboard at once, without knowing that any of them exist.
            // WindowServer has already enumerated the HID devices, applied the
            // layout and merged them into one system-wide state, and
            // kCGEventSourceStateHIDSystemState is a read of exactly that
            // merged state. A USB keyboard on a Mac mini and the built-in one
            // on a laptop are the same bytes by the time they reach here, so
            // there is no device enumeration and nothing device-specific. That
            // is the whole reason this is thirty lines instead of PsychHID.
            //
            // What it therefore CANNOT do: say which keyboard a key came from,
            // reach a response box that presents on a vendor usage page, or
            // give a press timestamp better than the moment of this poll.
            // Those are PsychHID's job and remain so.
            if (nrhs != 1 || nlhs != 4)
                fail("Keys takes no arguments and returns four values.");

            // Virtual keycode -> HID usage. CGEventSourceKeyState speaks
            // virtual keycodes, which are a Mac-only layout-position encoding;
            // Psychtoolbox's KbCheck indexes keyCode by HID usage. Reporting
            // virtual codes would be easier and would silently break every
            // script that has a KbName constant in it, so the table is here.
            // Left column virtual, right column usage; a usage of 0 means the
            // key has no keyboard-page equivalent and is skipped.
            static const unsigned char vkToUsage[128] = {
                /* 0x00 */  4, 22,  7,  9, 11, 10, 29, 27,
                /* 0x08 */  6, 25,100,  5, 20, 26,  8, 21,
                /* 0x10 */ 28, 23, 30, 31, 32, 33, 35, 34,
                /* 0x18 */ 46, 38, 36, 45, 37, 39, 48, 18,
                /* 0x20 */ 24, 47, 12, 19, 40, 15, 13, 52,
                /* 0x28 */ 14, 51, 49, 54, 56, 17, 16, 55,
                /* 0x30 */ 43, 44, 53, 42,  0, 41,231,227,
                /* 0x38 */225, 57,226,224,229,230,228,  0,
                /* 0x40 */108, 99,  0, 85,  0, 87,  0, 83,
                /* 0x48 */  0,  0,  0, 84, 88,  0, 86,109,
                /* 0x50 */110,103, 98, 89, 90, 91, 92, 93,
                /* 0x58 */ 94, 95,111, 96, 97,137,135,133,
                /* 0x60 */ 62, 63, 64, 60, 65, 66,145, 68,
                /* 0x68 */144,104,107,105,  0, 67,101, 69,
                /* 0x70 */  0,106,117, 74, 75, 76, 61, 77,
                /* 0x78 */ 59, 78, 58, 80, 79, 81, 82,  0
            };

            mxArray *kc = mxCreateLogicalMatrix(1, 256);
            mxLogical *kv = mxGetLogicals(kc);
            for (int vk = 0; vk < 128; vk++) {
                unsigned char usage = vkToUsage[vk];
                if (usage == 0) continue;
                if (CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,
                                          (CGKeyCode)vk)) {
                    // usage - 1, because the caller indexes from 1 and
                    // KbName('ESCAPE') is 41 for a key whose usage is 41.
                    // Writing kv[usage] would put every key one slot late and
                    // still return a plausible-looking vector.
                    kv[usage - 1] = 1;
                }
            }
            // PAIRED MODIFIERS ARE NOT SIDED IN THE KEYCODE STATE.
            //
            // CGEventSourceKeyState collapses each modifier pair onto its
            // left-hand virtual keycode: press the right shift and 0x38 reads
            // down while 0x3C, the right shift's own code, stays up. The scan
            // above therefore reports every right modifier as its left twin.
            //
            // That is not cosmetic. Left shift and right shift are a standard
            // pair of 2AFC response keys, and under the collapsed state the two
            // responses are identical and keyCode(229) never fires at all — an
            // experiment that looks like it is running and records one response
            // for both buttons.
            //
            // The sidedness is in the device-dependent flag bits instead, the
            // NX_DEVICE*KEYMASK values from IOKit/hidsystem/IOLLEvent.h. Named
            // here rather than imported, because four stable constants are
            // cheaper than a header dependency, but that is where to check
            // them.
            static const struct {
                int leftUsage, rightUsage;
                uint32_t leftBit, rightBit;
                int leftVK, rightVK;
            } modFamily[4] = {
                { 225, 229, 0x00000002, 0x00000004, 0x38, 0x3C },  // shift
                { 224, 228, 0x00000001, 0x00002000, 0x3B, 0x3E },  // control
                { 226, 230, 0x00000020, 0x00000040, 0x3A, 0x3D },  // option
                { 227, 231, 0x00000008, 0x00000010, 0x37, 0x36 },  // command
            };
            CGEventFlags mf =
                CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
            for (int m = 0; m < 4; m++) {
                bool L = (mf & modFamily[m].leftBit) != 0;
                bool R = (mf & modFamily[m].rightBit) != 0;
                if (!L && !R) {
                    // No device bit set. Either the modifier is genuinely up,
                    // or this keyboard does not report sidedness at all; fall
                    // back to the keycodes so such a keyboard still reports the
                    // key rather than losing it to a cleverer method.
                    L = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,
                            (CGKeyCode)modFamily[m].leftVK) != 0;
                    R = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,
                            (CGKeyCode)modFamily[m].rightVK) != 0;
                }
                // Assigned, not or-ed: the scan above may have set the left
                // usage from the collapsed state and that is the reading being
                // corrected.
                kv[modFamily[m].leftUsage - 1] = L ? 1 : 0;
                kv[modFamily[m].rightUsage - 1] = R ? 1 : 0;
            }

            // Derived from the vector rather than accumulated alongside it, so
            // keyIsDown cannot disagree with keyCode. Accumulating was fine
            // until the correction above began CLEARING entries the scan had
            // set, at which point a modifier that read down in the scan and up
            // in the flags would have left keyIsDown true over an all-up
            // vector.
            bool anyDown = false;
            for (int u = 0; u < 256; u++)
                if (kv[u]) { anyDown = true; break; }

            // Stamped AFTER the scan, so it is the time by which every element
            // of keyCode was true. Stamping before would name a moment at which
            // the later keys had not been read.
            double secs = CACurrentMediaTime();

            // Secure input is the one failure that is otherwise invisible: with
            // it active every key reads up, so a subject can hold a key down
            // and the experiment sees nothing and reports no error. Any process
            // with a password field can turn it on. CGSessionCopyCurrentDict-
            // ionary carries the owning pid, and it is already CoreGraphics, so
            // detecting it costs no new framework.
            double securePid = 0.0;
            CFDictionaryRef sess = CGSessionCopyCurrentDictionary();
            if (sess) {
                CFTypeRef v = CFDictionaryGetValue(sess,
                    CFSTR("kCGSSessionSecureInputPID"));
                if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                    int pid = 0;
                    CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &pid);
                    securePid = (double)pid;
                }
                CFRelease(sess);
            }

            plhs[0] = mxCreateLogicalScalar(anyDown);
            plhs[1] = mxCreateDoubleScalar(secs);
            plhs[2] = kc;
            plhs[3] = mxCreateDoubleScalar(securePid);
            return;
        }
        if (cmd(prhs[0], "SetBackgroundColor")) {
            // SetBackgroundColor(r, g, b, a), each 0 to 1. This is the colour a
            // frame is cleared to before any drawing, which is what
            // Screen('Flip') does with the colour given to OpenWindow.
            if (nrhs != 5 || nlhs != 0)
                fail("SetBackgroundColor needs r, g, b and a.");
            for (int a = 1; a <= 4; a++) {
                double v = scalar(prhs[a], "background colour component");
                if (!(v >= 0.0 && v <= 1.0))
                    fail("Background colour components run 0 to 1.");
                clearRGBA[a - 1] = (float)v;
            }
            return;
        }
        if (cmd(prhs[0], "AddShapes")) {
            // AddShapes(kind[1xN], param[1xN], rect[4xN], color[4xN],
            //           extra[4xN]).
            // Batched deliberately: DrawDots with a few thousand dots must be
            // one call, not one call per dot. The wrapper resolves colour range
            // and Psychtoolbox rect conventions before we see them.
            //
            // extra is REQUIRED rather than optional. Only the Gabor reads it,
            // and every other shape passes zeros, so accepting the old
            // five-argument form would cost nothing and work — which is exactly
            // the problem. A wrapper newer than the mex would then draw Gabors
            // silently as plain Gaussians instead of failing, and a stale binary
            // that produces a subtly wrong stimulus is worse than one that
            // refuses to run.
            if (nrhs != 6 || nlhs != 0)
                fail("AddShapes needs kind, param, rect, color and extra arrays.");
            if (!device)
                fail("PsychMetal is not open.");
            for (int a = 1; a <= 5; a++)
                if (!mxIsDouble(prhs[a]) || mxIsComplex(prhs[a]))
                    fail("AddShapes arguments must be real double arrays.");
            // size_t, not mwSize: Octave defines mwSize as a signed long long
            // while mxGetM/mxGetN return size_t, so mixing them warns.
            size_t n = mxGetN(prhs[1]);
            if (mxGetM(prhs[1]) != 1 || mxGetM(prhs[2]) != 1 ||
                mxGetN(prhs[2]) != n || mxGetM(prhs[3]) != 4 ||
                mxGetN(prhs[3]) != n || mxGetM(prhs[4]) != 4 || mxGetN(prhs[4]) != n ||
                mxGetM(prhs[5]) != 4 || mxGetN(prhs[5]) != n)
                fail("AddShapes expects kind and param as 1xN and rect, color and extra as 4xN.");
            if (n == 0)
                return;
            const double *kind = mxGetPr(prhs[1]);
            const double *param = mxGetPr(prhs[2]);
            const double *rect = mxGetPr(prhs[3]);
            const double *color = mxGetPr(prhs[4]);
            const double *extra = mxGetPr(prhs[5]);
            pthread_mutex_lock(&lock);
            for (size_t k = 0; k < n; k++) {
                if (drawCount >= PM_MAX_SHAPES) {
                    shapeOverflow = true;
                    break;
                }
                PMDrawItem *item = &drawList[drawCount++];
                memset(item, 0, sizeof(*item));
                item->type = PM_ITEM_SHAPE;
                item->texIndex = -1;
                PMShape *sh = &item->shape;
                sh->kind = (uint32_t)kind[k];
                sh->param = (float)param[k];
                for (int c = 0; c < 4; c++) {
                    sh->rect[c] = (float)rect[4 * k + c];
                    sh->color[c] = (float)color[4 * k + c];
                    sh->extra[c] = (float)extra[4 * k + c];
                }
                sh->pad[0] = sh->pad[1] = 0.0f;
                if (!haveLastShape) {
                    lastShape = *sh;
                    haveLastShape = true;
                }
                shapesAppended++;
            }
            pthread_mutex_unlock(&lock);
            return;
        }
        if (cmd(prhs[0], "MakeTexture")) {
            // MakeTexture(width, height, rgba) with rgba a 4*W*H double array
            // ordered channel-fastest then x then y, which is what the wrapper
            // produces from a Psychtoolbox HxWxC image by permuting.
            if (nrhs != 4 || nlhs != 1)
                fail("MakeTexture needs width, height and an RGBA array, and returns a handle.");
            if (!device)
                fail("PsychMetal is not open.");
            size_t tw = (size_t)unsignedScalar(prhs[1], "texture width", UINT_MAX);
            size_t th = (size_t)unsignedScalar(prhs[2], "texture height", UINT_MAX);
            if (tw == 0 || th == 0)
                fail("Texture width and height must be positive.");
            if (!mxIsDouble(prhs[3]) || mxIsComplex(prhs[3]) ||
                mxGetNumberOfElements(prhs[3]) != 4 * tw * th)
                fail("The RGBA array must be real doubles with 4*width*height elements.");
            int slot = -1;
            for (int i = 0; i < PM_MAX_TEXTURES; i++)
                if (!userTextures[i]) { slot = i; break; }
            if (slot < 0)
                fail("No free texture slots; close some textures first.");
            // RGBA16Float, not RGBA32Float. Half float has an 11-bit mantissa,
            // comfortably beyond the 8-bit drawable, and it is filterable in
            // hardware on Apple GPUs. 32-bit float is not reliably filterable,
            // and using a linear sampler on it dropped this demo from 60 Hz to
            // 36 Hz with a third of frames skipped. Half the memory too.
            MTLTextureDescriptor *td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                             width:tw
                                            height:th
                                         mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> tex = [device newTextureWithDescriptor:td];
            if (!tex)
                fail("Could not allocate the Metal texture.");
            const double *src = mxGetPr(prhs[3]);
            __fp16 *tmp = (__fp16 *)malloc(4 * tw * th * sizeof(__fp16));
            if (!tmp)
                fail("Out of memory converting the texture.");
            for (size_t i = 0; i < 4 * tw * th; i++)
                tmp[i] = (__fp16)src[i];
            [tex replaceRegion:MTLRegionMake2D(0, 0, tw, th)
                   mipmapLevel:0
                     withBytes:tmp
                   bytesPerRow:tw * 4 * sizeof(__fp16)];
            free(tmp);
            userTextures[slot] = tex;
            texturesCreated++;
            plhs[0] = mxCreateDoubleScalar((double)slot);
            return;
        }
        if (cmd(prhs[0], "DrawTexture")) {
            // DrawTexture(handle, src[4], dst[4], angle, tint[4], filterMode)
            if (nrhs != 7 || nlhs != 0)
                fail("DrawTexture needs handle, srcRect, dstRect, angle, tint and filterMode.");
            if (!device)
                fail("PsychMetal is not open.");
            int slot = (int)scalar(prhs[1], "texture handle");
            if (slot < 0 || slot >= PM_MAX_TEXTURES || !userTextures[slot])
                fail("Invalid texture handle.");
            for (int a = 2; a <= 5; a++)
                if (!mxIsDouble(prhs[a]) || mxIsComplex(prhs[a]))
                    fail("DrawTexture rectangles and tint must be real doubles.");
            if (mxGetNumberOfElements(prhs[2]) != 4 ||
                mxGetNumberOfElements(prhs[3]) != 4 ||
                mxGetNumberOfElements(prhs[5]) != 4)
                fail("srcRect, dstRect and tint must each have four elements.");
            const double *sr = mxGetPr(prhs[2]);
            const double *dr = mxGetPr(prhs[3]);
            const double *ti = mxGetPr(prhs[5]);
            pthread_mutex_lock(&lock);
            if (drawCount >= PM_MAX_SHAPES) {
                shapeOverflow = true;
                pthread_mutex_unlock(&lock);
                return;
            }
            PMDrawItem *item = &drawList[drawCount++];
            memset(item, 0, sizeof(*item));
            item->type = PM_ITEM_TEXTURE;
            item->texIndex = slot;
            for (int c = 0; c < 4; c++) {
                item->src[c] = (float)sr[c];
                item->dst[c] = (float)dr[c];
                item->tint[c] = (float)ti[c];
            }
            item->angle = (float)scalar(prhs[4], "rotation angle");
            item->filterMode = (scalar(prhs[6], "filter mode") != 0.0) ? 1 : 0;
            pthread_mutex_unlock(&lock);
            return;
        }
        if (cmd(prhs[0], "CloseTexture")) {
            if (nrhs != 2 || nlhs != 0)
                fail("CloseTexture needs a texture handle.");
            int slot = (int)scalar(prhs[1], "texture handle");
            if (slot < 0 || slot >= PM_MAX_TEXTURES)
                fail("Invalid texture handle.");
            userTextures[slot] = nil;
            return;
        }
        if (cmd(prhs[0], "Wait")) {
            // Wait(untilTime) -> actual time on return.
            //
            // mach_wait_until takes an absolute deadline in mach ticks, which is
            // the same counter CACurrentMediaTime reports, so there is no clock
            // conversion between the deadline asked for and the one the kernel
            // uses. A relative nanosleep would instead accumulate the cost of
            // reading the clock into every wait.
            //
            // THE SPIN MARGIN IS SET BY MEASURED SLACK, not by taste. A 500 us
            // margin was tried first and the wait overshot by 2.0 ms: the kernel
            // returned from mach_wait_until well past its own deadline, so the
            // spin never ran. Timer slack on a non-realtime thread is a few
            // milliseconds, so the margin has to exceed it or it buys nothing.
            //
            // The cost is real but bounded: the last few ms of any wait burn a
            // core. A stimulus loop should schedule with Flip's `when` and not
            // call this at all; this is for the waits between trials.
            if (nrhs != 2 || nlhs != 1)
                fail("Wait needs an absolute deadline and returns the time on return.");
            double untilTime = scalar(prhs[1], "deadline");
            static double spinMargin = 0.004;
            double sleepUntilT = untilTime - spinMargin;
            double afterSleep = CACurrentMediaTime();
            if (afterSleep < sleepUntilT) {
                mach_timebase_info_data_t tb;
                mach_timebase_info(&tb);
                if (tb.numer && tb.denom) {
                    // seconds -> mach ticks: t * 1e9 * denom / numer
                    long double ticks = (long double)sleepUntilT * 1.0e9L *
                                        (long double)tb.denom / (long double)tb.numer;
                    if (ticks > 0)
                        mach_wait_until((uint64_t)ticks);
                }
                afterSleep = CACurrentMediaTime();
                // Grow the margin if the kernel overran it, so a machine with
                // worse slack than this one corrects itself after one wait
                // instead of missing every deadline.
                double overrun = afterSleep - sleepUntilT;
                if (overrun > spinMargin * 0.5 && spinMargin < 0.020)
                    spinMargin = fmin(0.020, overrun * 2.0);
            }
            while (CACurrentMediaTime() < untilTime) { }
            plhs[0] = mxCreateDoubleScalar(CACurrentMediaTime());
            return;
        }
        if (cmd(prhs[0], "Now")) {
            if (nrhs != 1 || nlhs != 1)
                fail("Now takes no arguments and one output.");
            plhs[0] = mxCreateDoubleScalar(CACurrentMediaTime());
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
            uint64_t snapshotConfirmed = confirmedCount;
            uint64_t snapshotMissing = missingPresentedCount;
            double snapshotTargetError = lastTargetErrorMs;
            double snapshotConfirmDelay = lastConfirmDelayMs;
            int snapshotInFlight = inFlightCount;
            NSUInteger snapshotRequestedDrawables = requestedDrawableCount;
            NSUInteger snapshotDrawableReadback = drawableCountReadback;
            pthread_mutex_unlock(&lock);
            NSBundle *hostBundle = NSBundle.mainBundle;
            NSString *hostIdentifier = hostBundle.bundleIdentifier;
            if (!hostIdentifier)
                hostIdentifier = @"";
            NSProcessInfo *processInfo = NSProcessInfo.processInfo;
            mach_timebase_info_data_t timebase = {};
            mach_timebase_info(&timebase);
            double machTickNs = timebase.denom ? (double)timebase.numer / timebase.denom : NAN;
            double machHz = isfinite(machTickNs) ? 1.0e9 / machTickNs : NAN;
            const char *n[] = {
                "confirmedPresentations", "missingPresentedTimes",
                "lastTargetErrorMs",     "lastConfirmDelayMs",     "appKitScreenIndex",
                "cgDisplayID",           "renderWidth",            "renderHeight",
                "drawableWidth",         "drawableHeight",        "inFlight",
                "requestedDrawableCount",  "drawableCountReadback",
                "hostBundleIdentifier",  "activationPolicyBefore",
                "activationPolicyAfter", "activationPolicyPromotionAttempted",
                "activationPolicyPromotionSucceeded", "macOSVersion", "processName",
                "machTimebaseHz",        "machTickNanoseconds",
                "waitForConfirm",        "measuredRefreshHz",
                "gridSamples",           "directNoDrawable",       "directConfirmTimeouts",
                "leadEstimateMs",
                "pipelineEstimateMs",      "gpuEstimateMs",          "displaySyncEnabled",
                "displayCaptured",
                "modePointWidth",          "modePixelWidth",         "nativePixelWidth",
                "shapesAppended",          "shapesEncoded",          "shapeEncodeCalls",
                "texturesCreated",         "texturesDrawn",
                "lastShapeRect",           "lastShapeColor",         "lastShapeKind",
                "windowFrame",             "viewBounds",             "layerFrame",
                "screenFrame",             "screenVisibleFrame",     "screenSafeAreaInsets",
                "cgDisplayBounds",         "backingScaleFactor"};
            plhs[1] = mxCreateStructMatrix(1, 1,
                                           (int)(sizeof(n) / sizeof(n[0])), n);
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
            mxSetField(plhs[1], 0, "displayCaptured", mxCreateLogicalScalar(displayCaptured));
            // A scaled HiDPI mode renders to an oversized framebuffer which the
            // display pipeline then resamples to the panel. modePixelWidth below
            // nativePixelWidth means that resampling pass is in the path, and no
            // layer configuration can remove it.
            double modePointWidth = NAN, modePixelWidth = NAN, nativePixelWidth = NAN;
            if (selectedDisplayID) {
                CGDisplayModeRef current = CGDisplayCopyDisplayMode(selectedDisplayID);
                if (current) {
                    modePointWidth = (double)CGDisplayModeGetWidth(current);
                    modePixelWidth = (double)CGDisplayModeGetPixelWidth(current);
                    CGDisplayModeRelease(current);
                }
                CFArrayRef all = CGDisplayCopyAllDisplayModes(selectedDisplayID, NULL);
                if (all) {
                    for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
                        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
                        double px = (double)CGDisplayModeGetPixelWidth(m);
                        if (!(px <= nativePixelWidth))
                            nativePixelWidth = px;
                    }
                    CFRelease(all);
                }
            }
            mxSetField(plhs[1], 0, "modePointWidth", mxCreateDoubleScalar(modePointWidth));
            mxSetField(plhs[1], 0, "modePixelWidth", mxCreateDoubleScalar(modePixelWidth));
            mxSetField(plhs[1], 0, "nativePixelWidth", mxCreateDoubleScalar(nativePixelWidth));
            mxSetField(plhs[1], 0, "shapesAppended", mxCreateDoubleScalar((double)shapesAppended));
            mxSetField(plhs[1], 0, "shapesEncoded", mxCreateDoubleScalar((double)shapesEncoded));
            mxSetField(plhs[1], 0, "shapeEncodeCalls",
                       mxCreateDoubleScalar((double)shapeEncodeCalls));
            mxSetField(plhs[1], 0, "texturesCreated",
                       mxCreateDoubleScalar((double)texturesCreated));
            mxSetField(plhs[1], 0, "texturesDrawn",
                       mxCreateDoubleScalar((double)texturesDrawn));
            mxSetField(plhs[1], 0, "lastShapeRect",
                       rect4(lastShape.rect[0], lastShape.rect[1],
                             lastShape.rect[2], lastShape.rect[3]));
            mxSetField(plhs[1], 0, "lastShapeColor",
                       rect4(lastShape.color[0], lastShape.color[1],
                             lastShape.color[2], lastShape.color[3]));
            mxSetField(plhs[1], 0, "lastShapeKind",
                       mxCreateDoubleScalar((double)lastShape.kind));
            // Every rectangle in the chain from the display down to the layer.
            // If one of them is short by the notch height, that is where the
            // top strip is being lost; if none of them is, the masking happens
            // below anything the application can see.
            __block NSRect winFrame = NSZeroRect, viewB = NSZeroRect, layerF = NSZeroRect;
            __block NSRect scrFrame = NSZeroRect, scrVisible = NSZeroRect;
            __block NSEdgeInsets insets = NSEdgeInsetsMake(0, 0, 0, 0);
            __block double backingScale = NAN;
            if (metalWindow)
                onMainSync(^{
                    winFrame = metalWindow.frame;
                    backingScale = metalWindow.backingScaleFactor;
                    NSView *v = metalWindow.contentView;
                    if (v)
                        viewB = v.bounds;
                    if (layer)
                        layerF = layer.frame;
                    NSScreen *sc = metalWindow.screen ? metalWindow.screen
                                                      : NSScreen.mainScreen;
                    if (sc) {
                        scrFrame = sc.frame;
                        scrVisible = sc.visibleFrame;
                        if (@available(macOS 12.0, *))
                            insets = sc.safeAreaInsets;
                    }
                });
            CGRect cgb = selectedDisplayID ? CGDisplayBounds(selectedDisplayID) : CGRectZero;
            mxSetField(plhs[1], 0, "windowFrame", rect4(winFrame.origin.x, winFrame.origin.y,
                                                        winFrame.size.width, winFrame.size.height));
            mxSetField(plhs[1], 0, "viewBounds", rect4(viewB.origin.x, viewB.origin.y,
                                                       viewB.size.width, viewB.size.height));
            mxSetField(plhs[1], 0, "layerFrame", rect4(layerF.origin.x, layerF.origin.y,
                                                       layerF.size.width, layerF.size.height));
            mxSetField(plhs[1], 0, "screenFrame", rect4(scrFrame.origin.x, scrFrame.origin.y,
                                                        scrFrame.size.width, scrFrame.size.height));
            mxSetField(plhs[1], 0, "screenVisibleFrame",
                       rect4(scrVisible.origin.x, scrVisible.origin.y,
                             scrVisible.size.width, scrVisible.size.height));
            // top, left, bottom, right
            mxSetField(plhs[1], 0, "screenSafeAreaInsets",
                       rect4(insets.top, insets.left, insets.bottom, insets.right));
            mxSetField(plhs[1], 0, "cgDisplayBounds",
                       rect4(cgb.origin.x, cgb.origin.y, cgb.size.width, cgb.size.height));
            mxSetField(plhs[1], 0, "backingScaleFactor", mxCreateDoubleScalar(backingScale));
            mxSetField(plhs[1], 0, "inFlight", mxCreateDoubleScalar(snapshotInFlight));
            mxSetField(plhs[1], 0, "requestedDrawableCount",
                       mxCreateDoubleScalar(snapshotRequestedDrawables));
            mxSetField(plhs[1], 0, "drawableCountReadback",
                       mxCreateDoubleScalar(snapshotDrawableReadback));
            mxSetField(plhs[1], 0, "hostBundleIdentifier", mxCreateString(hostIdentifier.UTF8String));
            mxSetField(plhs[1], 0, "activationPolicyBefore",
                       mxCreateDoubleScalar(activationPolicyBefore));
            mxSetField(plhs[1], 0, "activationPolicyAfter",
                       mxCreateDoubleScalar(activationPolicyAfter));
            mxSetField(plhs[1], 0, "activationPolicyPromotionAttempted",
                       mxCreateLogicalScalar(activationPolicyPromotionAttempted));
            mxSetField(plhs[1], 0, "activationPolicyPromotionSucceeded",
                       mxCreateLogicalScalar(activationPolicyPromotionSucceeded));
            mxSetField(plhs[1], 0, "macOSVersion",
                       mxCreateString(processInfo.operatingSystemVersionString.UTF8String));
            mxSetField(plhs[1], 0, "processName",
                       mxCreateString(processInfo.processName.UTF8String));
            mxSetField(plhs[1], 0, "machTimebaseHz", mxCreateDoubleScalar(machHz));
            mxSetField(plhs[1], 0, "machTickNanoseconds", mxCreateDoubleScalar(machTickNs));
            mxSetField(plhs[1], 0, "waitForConfirm", mxCreateLogicalScalar(directWaitForConfirm));
            mxSetField(plhs[1], 0, "displaySyncEnabled", mxCreateLogicalScalar(displaySync));
            mxSetField(plhs[1], 0, "pipelineEstimateMs",
                       mxCreateDoubleScalar(pipelineEstimate > 0 ? pipelineEstimate * 1000.0 : NAN));
            mxSetField(plhs[1], 0, "gpuEstimateMs",
                       mxCreateDoubleScalar(gpuEstimate > 0 ? gpuEstimate * 1000.0 : NAN));
            mxSetField(plhs[1], 0, "leadEstimateMs",
                       mxCreateDoubleScalar(leadEstimate > 0 ? leadEstimate * 1000.0 : NAN));
            mxSetField(plhs[1], 0, "measuredRefreshHz",
                       mxCreateDoubleScalar(measuredIFI > 0 ? 1.0 / measuredIFI : NAN));
            mxSetField(plhs[1], 0, "gridSamples", mxCreateDoubleScalar((double)gridSamples));
            mxSetField(plhs[1], 0, "directNoDrawable",
                       mxCreateDoubleScalar((double)directNoDrawableCount));
            mxSetField(plhs[1], 0, "directConfirmTimeouts",
                       mxCreateDoubleScalar((double)directTimeoutCount));
            return;
        }
        if (cmd(prhs[0], "Close")) {
            if (nrhs != 1 || nlhs != 0)
                fail("Close takes no arguments or outputs.");
            closeCore();
            return;
        }
        fail("Unknown command.");
    }
}
