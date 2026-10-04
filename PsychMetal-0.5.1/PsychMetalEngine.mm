// PsychMetalEngine 0.5.1 — direct Metal presentation. No OpenGL.
// SPDX-License-Identifier: MIT
//
// The host-neutral engine behind PsychMetalEngine.h: presentation, timing,
// textures and input. Errors throw pm::Error, warnings and module pinning go
// through pm::HostHooks, images are read through strided views, and the pm::
// functions at the end of this file are the boundary. Front ends:
// PsychMetalMex.cpp (MATLAB, Octave) and PsychMetalPython.cpp (Python).
#include "PsychMetalEngine.h"
#include "PsychMetalInternal.h"
#include "PsychMetalShaders.h"
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
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
#include <memory>
#include <mutex>
#include <algorithm>
#include <float.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdexcept>

#define NREC 16384
#define LAGWIN 64
typedef struct {
    uint64_t token;
    int status, done, gpuDone, scheduled, commandStatus, inFlight;
    double projected, scheduledAt, presented, callback;
    double committedAt;
    double drawableAcquireMs, encodeMs, prefetchMs;
    double requestedTime, gpuStart, gpuEnd, presentRequest, presentCallMs;
    int pipelineNoted;
} Record;
static std::vector<Record> startupRecords;
static bool startupReady=false;
static NSWindow *metalWindow;
static CAMetalLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
#define PM_MAX_SHAPES 8192
#define PM_SHAPE_RING 4
enum { PM_FILL_RECT = 0, PM_FRAME_RECT = 1, PM_FILL_OVAL = 2,
       PM_FRAME_OVAL = 3, PM_DOT = 4, PM_LINE = 5, PM_GABOR = 6,
       PM_NOISE = 7 };

typedef struct {
    float rect[4];
    float color[4];
    uint32_t kind;
    float param;
    float pad[2];
    float extra[4];
} PMShape;
static_assert(sizeof(PMShape)==64, "Metal shape layout mismatch");
static float clearRGBA[4] = {0.0f, 0.0f, 0.0f, 1.0f};
static double lastConfirmedPresented = NAN;   // newest confirmed presentedTime
static double lastConfirmedProjected = NAN;   // what was predicted for it
static double pendingSlipRefreshes;           // reported with the NEXT flip
static int prefetchDrawable;
static id<CAMetalDrawable> heldDrawable;
static id<MTLRenderPipelineState> shapePipeline;
static id<MTLBuffer> shapeBuffers[PM_SHAPE_RING];
static int shapeBufferIndex;
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
struct PMTextureResource {
    id<MTLTexture> texture;
    size_t width, height, channels;
};
using PMTextureRef = std::shared_ptr<PMTextureResource>;
static PMTextureRef userTextures[PM_MAX_TEXTURES];
static std::vector<PMTextureRef> texturePools[PM_MAX_TEXTURES];
static PMTextureRef drawTextureRefs[PM_MAX_SHAPES];
static uint64_t textureHandles[PM_MAX_TEXTURES], nextTextureHandle=1;
static constexpr uint64_t PM_MAX_ID=pm::kMaxId;
static uint64_t firstSessionToken=1;
static uint64_t sessionEpoch=0, lastSlipToken=0, lastConfirmedToken=0;
static bool graphicsLocked=false;
static bool shapeBufferBusy[PM_SHAPE_RING]={};
static double cpuUploadMs=0;
static uint64_t textureAllocations=0,textureUpdates=0;

static id<MTLRenderPipelineState> texturePipeline;
static id<MTLSamplerState> linearSampler, nearestSampler;
static uint64_t texturesCreated, texturesDrawn;

static uint64_t shapesAppended, shapesEncoded, shapeEncodeCalls;
static PMShape lastShape;
static bool haveLastShape;
static double ifi, lastTargetErrorMs, lastConfirmDelayMs;
static NSUInteger renderWidth, renderHeight;
static uint64_t nextToken=1, confirmedCount, missingPresentedCount;
static NSInteger selectedScreenIndex = -1;
static CGDirectDisplayID selectedDisplayID = 0;
static Record rec[NREC];
static bool closing = true;
static std::mutex secureInputStateLock;
static double keyScanMaxMs=0,secureQueryMaxMs=0,keyScanTotalMs=0,secureQueryTotalMs=0;
static uint64_t keyReadCount=0;
static int inFlightCount;
static bool asynchronousGpuFailure=false; // guarded by lock; cleared on Open
static NSUInteger requestedDrawableCount, drawableCountReadback;
static NSInteger activationPolicyBefore = -1, activationPolicyAfter = -1;
static bool activationPolicyPromotionAttempted, activationPolicyPromotionSucceeded;
static bool appPrepared;
static bool displayCaptured;
static bool directWaitForConfirm = true;
static bool displaySync = true;
static id<CAMetalDrawable> preparedDrawable;
static uint64_t preparedToken;
// Readback sessions only: every frame's drawable is copied here before it is
// presented. captureToken is the frame the copy belongs to.
static id<MTLTexture> captureTexture;
static uint64_t captureToken;
static std::vector<uint8_t> captureScratch;
static double gridFirstPresented, gridLastPresented, measuredIFI;
static double lastProjected;
static int64_t gridFirstFrame, gridLastFrame;
static uint64_t gridSamples, directNoDrawableCount, directTimeoutCount;
static double percentileOf(const double *src, int n, double frac);
// The 90th percentile of the newest LAGWIN samples; 0 until there are eight.
struct PMEstimate {
    double samples[LAGWIN];
    int count, index;
    double value;
    void add(double sample) {
        samples[index] = sample;
        index = (index + 1) % LAGWIN;
        if (count < LAGWIN)
            count++;
        if (count >= 8)
            value = percentileOf(samples, count, 0.90);
    }
};
static PMEstimate leadEstimate, pipelineEstimate, gpuEstimate;   // guarded by lock
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static void readKeyboardState(bool *kv,const bool *filter) {
    memset(kv,0,256*sizeof(bool));
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

    for (int vk = 0; vk < 128; vk++) {
        unsigned char usage = vkToUsage[vk];
        if (usage == 0 || (filter && !filter[usage-1])) continue;
        if (CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,
                                  (CGKeyCode)vk)) {
            kv[usage - 1] = 1;
        }
    }
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
        if(filter && !filter[modFamily[m].leftUsage-1] && !filter[modFamily[m].rightUsage-1]) continue;
        bool L = (mf & modFamily[m].leftBit) != 0;
        bool R = (mf & modFamily[m].rightBit) != 0;
        if (!L && !R) {
            L = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,
                    (CGKeyCode)modFamily[m].leftVK) != 0;
            R = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState,
                    (CGKeyCode)modFamily[m].rightVK) != 0;
        }
        kv[modFamily[m].leftUsage - 1] = L ? 1 : 0;
        kv[modFamily[m].rightUsage - 1] = R ? 1 : 0;
    }

    if(filter) for(int k=0;k<256;k++) if(!filter[k]) kv[k]=false;
}
static double keyboardClock() { return CACurrentMediaTime(); }
static pm::HostHooks hooks;
static void hookPin() { if (hooks.pinModule) hooks.pinModule(); }
static void hookUnpin() { if (hooks.unpinModule) hooks.unpinModule(); }
static void hookWarn(const char *id, const char *fmt, ...) {
    char text[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(text, sizeof(text), fmt, args);
    va_end(args);
    if (hooks.warn) hooks.warn(id, text);
}
#include "PsychMetalKeyboardQueue.h"
static PMKeyboardQueue keyboardQueue(readKeyboardState,keyboardClock);
static bool keyboardQueueLocked=false;
static void releaseKeyboardQueue() {
    keyboardQueue.release();
    if(keyboardQueueLocked) { keyboardQueueLocked=false; hookUnpin(); }
}
[[noreturn]] static void fail(const char *s);
static int waitRelative(double endTime);
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

// Draw order is preserved. Buffer slots and texture versions remain owned until GPU completion.
// The draw list is read in place: only the caller thread writes it, and this is
// the caller thread.
static void encodeShapes(id<MTLRenderCommandEncoder> re, id<MTLCommandBuffer> cb) {
    pthread_mutex_lock(&lock);
    NSUInteger n = drawCount;
    const PMDrawItem *items = drawList;
    drawCount = 0;
    haveLastShape = false;
    shapeEncodeCalls++;
    shapesEncoded += n;
    pthread_mutex_unlock(&lock);

    if (n == 0 || !re)
        return;

    float size[2] = {(float)renderWidth, (float)renderHeight};

    auto resources=std::make_shared<std::vector<PMTextureRef>>();
    resources->reserve(n);
    for(NSUInteger i=0;i<n;i++) {
        if(drawTextureRefs[i]) resources->push_back(drawTextureRefs[i]);
    }
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) { (void)resources; }];
    pthread_mutex_lock(&lock);
    int slot=shapeBufferIndex;
    double deadline=CACurrentMediaTime()+2;
    while(shapeBufferBusy[slot]) {
        if(waitRelative(deadline)==ETIMEDOUT) {
            pthread_mutex_unlock(&lock);
            fail("Timed out waiting for a free shape buffer.");
        }
    }
    shapeBufferBusy[slot]=true;
    shapeBufferIndex=(slot+1)%PM_SHAPE_RING;
    uint64_t epoch=sessionEpoch;
    pthread_mutex_unlock(&lock);
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        pthread_mutex_lock(&lock);
        if(epoch==sessionEpoch) shapeBufferBusy[slot]=false;
        pthread_cond_broadcast(&cond); pthread_mutex_unlock(&lock);
    }];
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
        const PMDrawItem *it = &items[i];
        if (it->texIndex < 0 || it->texIndex >= PM_MAX_TEXTURES ||
            !drawTextureRefs[i] || !texturePipeline)
            continue;
        struct {
            float dst[4], src[4], tint[4], size[2], angle, mono;
        } u;
        static_assert(sizeof(u)==64,"Texture uniform layout mismatch");
        memcpy(u.dst, it->dst, sizeof(u.dst));
        memcpy(u.src, it->src, sizeof(u.src));
        memcpy(u.tint, it->tint, sizeof(u.tint));
        u.size[0] = size[0];
        u.size[1] = size[1];
        u.angle = it->angle;
        u.mono = drawTextureRefs[i]->channels==1 ? 1.0f : 0.0f;
        [re setRenderPipelineState:texturePipeline];
        [re setVertexBytes:&u length:sizeof(u) atIndex:0];
        [re setFragmentTexture:drawTextureRefs[i]->texture atIndex:0];
        [re setFragmentSamplerState:(it->filterMode ? linearSampler : nearestSampler)
                            atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        texturesDrawn++;
    }
    for(NSUInteger i=0;i<n;i++) drawTextureRefs[i].reset();
}

// A readback session copies the finished drawable, in the same command buffer and
// before the present, so the copy holds the pixels that go to the display.
static bool encodeFrame(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d, uint64_t token) {
    if (!cb || !d)
        return false;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = d.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(clearRGBA[0], clearRGBA[1], clearRGBA[2], clearRGBA[3]);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    if (!re)
        return false;
    encodeShapes(re, cb);
    [re endEncoding];
    if (captureTexture) {
        // The frame is presented whether or not it could be copied. Without a
        // copy captureToken stays behind, and GetImage refuses to answer.
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (blit) {
            [blit copyFromTexture:d.texture sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(renderWidth, renderHeight, 1)
                        toTexture:captureTexture destinationSlice:0 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            captureToken = token;
        }
    }
    return true;
}

static void attachHandlers(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d, uint64_t token) {
    const uint64_t epoch=sessionEpoch;
    [d addPresentedHandler:^(id<MTLDrawable> x) {
        double pt = x.presentedTime, ct = CACurrentMediaTime();
        pthread_mutex_lock(&lock);
        Record *q = epoch==sessionEpoch ? recordFor(token) : nullptr;
        if (q) {
            q->presented = pt;
            q->callback = ct;
            if(q->status!=3) q->status = (pt > 0) ? 0 : 1;
            q->done = 1;
            if (pt > 0) {
                confirmedCount++;
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
                            int64_t span = gridLastFrame - gridFirstFrame;
                            if (gridSamples >= 16 && span >= 16)
                                measuredIFI = (gridLastPresented - gridFirstPresented) /
                                              (double)span;
                        }
                    }
                }
                bool onTarget = !isfinite(q->requestedTime) ||
                                fabs(pt - q->requestedTime) < 0.5 * ifi;
                double lead = pt - q->scheduledAt;
                if (onTarget && lead > 0 && lead < 10.0 * ifi)
                    leadEstimate.add(lead);
                lastTargetErrorMs = (pt - q->projected) * 1000.0;
                if (!isfinite(lastConfirmedPresented) || pt > lastConfirmedPresented) {
                    lastConfirmedPresented = pt;
                    lastConfirmedProjected = q->projected;
                    lastConfirmedToken = token;
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
        Record *q = epoch==sessionEpoch ? recordFor(token) : nullptr;
        if (q) {
            q->commandStatus = (int)x.status;
            q->gpuStart = x.GPUStartTime;
            q->gpuEnd = x.GPUEndTime;
            q->gpuDone = 1;
            if (x.status == MTLCommandBufferStatusError) {
                asynchronousGpuFailure=true;
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

static void notePipelineSample(Record *q) {
    if (!q || q->pipelineNoted || q->presented <= 0 || q->gpuEnd <= 0 ||
        isfinite(q->requestedTime))
        return;
    q->pipelineNoted = 1;
    double post = q->presented - q->gpuEnd;
    if (post > 0 && post < 10.0 * ifi)
        pipelineEstimate.add(post);
    double gpu = q->gpuEnd - q->gpuStart;
    if (gpu > 0 && gpu < ifi)
        gpuEstimate.add(gpu);
}


[[noreturn]] static void fail(const char *s) {
    throw pm::Error(pm::kErrGeneral, s);
}
[[noreturn]] static void failWith(const char *id, const char *fmt, ...) {
    char text[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(text, sizeof(text), fmt, args);
    va_end(args);
    throw pm::Error(id, text);
}
[[noreturn]] static void failOpen(const char *id, NSString *message) {
    char text[1024];
    const char *utf8 = message.UTF8String;
    snprintf(text, sizeof(text), "%s", utf8 ? utf8 : "PsychMetal Open failed.");
    closeCore();
    throw pm::Error(id, text);
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
// Caller holds lock. Wait up to two seconds for in-flight frames; true if none remain.
static bool drainLocked(void) {
    double deadline = CACurrentMediaTime() + 2.0;
    while (inFlightCount > 0)
        if (waitRelative(deadline) == ETIMEDOUT)
            break;
    return inFlightCount == 0;
}
static int textureSlot(uint64_t handle) {
    for(int i=0;i<PM_MAX_TEXTURES;i++)
        if(textureHandles[i]==handle && userTextures[i]) return i;
    fail("Invalid or expired texture handle.");
}
static std::vector<__fp16> uploadScratch;
// Validation and half-float packing live in PsychMetalShared.cpp, so they are
// shared by every front end and testable without a GPU.
static void uploadTexture(int slot,const pm::ArrayView &image) {
    double began=CACurrentMediaTime();
    pm::internal::ImageShape shape=pm::internal::packImage(image,uploadScratch);
    size_t h=shape.height,w=shape.width,c=shape.channels;
    auto &pool=texturePools[slot];
    PMTextureRef resource;
    for(auto &candidate:pool) {
        long owners=candidate.use_count();
        long idleOwners=userTextures[slot]==candidate ? 2 : 1;
        if(owners==idleOwners && candidate->width==w && candidate->height==h && candidate->channels==c) {
            resource=candidate; break;
        }
    }
    if(!resource) {
        pool.erase(std::remove_if(pool.begin(),pool.end(),[&](const PMTextureRef &r) {
            return r!=userTextures[slot] && r.use_count()==1;
        }),pool.end());
        if(pool.size()>=4) fail("Texture update pool is busy; Flip before updating this texture again.");
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            (c==1?MTLPixelFormatR16Float:MTLPixelFormatRGBA16Float) width:w height:h mipmapped:NO];
        td.usage=MTLTextureUsageShaderRead; td.storageMode=MTLStorageModeShared;
        id<MTLTexture> texture=[device newTextureWithDescriptor:td];
        if(!texture) fail("Could not allocate Metal texture.");
        resource=std::make_shared<PMTextureResource>();
        resource->texture=texture; resource->width=w; resource->height=h; resource->channels=c;
        pool.push_back(resource); textureAllocations++;
    }
    [resource->texture replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0
        withBytes:uploadScratch.data() bytesPerRow:w*(c==1?1:4)*sizeof(__fp16)];
    userTextures[slot]=resource; cpuUploadMs=(CACurrentMediaTime()-began)*1000;
}
// Invalidate the session before new records may be allocated. The graphics MEX stays pinned.
static void closeCore(void) {
    releaseKeyboardQueue();
    pthread_mutex_lock(&lock);
    if(preparedToken) {
        Record *r=recordFor(preparedToken);
        if(r) { r->done=1; r->status=5; if(r->inFlight && r->gpuDone) {r->inFlight=0; --inFlightCount;} }
    }
    pthread_mutex_unlock(&lock);
    preparedDrawable=nil; preparedToken=0; heldDrawable=nil;
    for(auto &r:drawTextureRefs) r.reset();
    pthread_mutex_lock(&lock);
    closing = true;
    pthread_cond_broadcast(&cond);
    bool drained=drainLocked();
    ++sessionEpoch; // any late callback is obsolete before resources are reset
    pthread_mutex_unlock(&lock);
    if(!drained) hookWarn(pm::kWarnDrainTimeout, "Close timed out waiting for callbacks; old callbacks have been isolated.");
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
    captureTexture = nil;
    captureToken = 0;
    std::vector<uint8_t>().swap(captureScratch);
    shapePipeline = nil;
    std::vector<__fp16>().swap(uploadScratch);
    texturePipeline = nil;
    linearSampler = nil;
    nearestSampler = nil;
    for (int i = 0; i < PM_MAX_TEXTURES; i++)
        { userTextures[i].reset(); texturePools[i].clear(); textureHandles[i]=0; }
    drawCount = 0;
    texturesCreated = texturesDrawn = 0;
    prefetchDrawable = 0;
    for (int i = 0; i < PM_SHAPE_RING; i++)
        shapeBuffers[i] = nil;
    shapesAppended = shapesEncoded = shapeEncodeCalls = 0;
    haveLastShape = false;
    memset(&lastShape, 0, sizeof(lastShape));
    queue = nil;
    device = nil;
    layer = nil;
}
static void prepareApp(void) {
    closeCore();
    onMainSync(^{
        NSApplication *app = [NSApplication sharedApplication];
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
// Both pipelines draw into the BGRA8 drawable with source-alpha blending.
static id<MTLRenderPipelineState> makePipeline(id<MTLLibrary> lib, NSString *vertex, NSString *fragment,
                                               NSError **error) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:vertex];
    pd.fragmentFunction = [lib newFunctionWithName:fragment];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    return [device newRenderPipelineStateWithDescriptor:pd error:error];
}
static id<MTLSamplerState> makeSampler(MTLSamplerMinMagFilter filter) {
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = filter;
    sd.magFilter = filter;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    return [device newSamplerStateWithDescriptor:sd];
}
static void openCore(NSUInteger w, NSUInteger h, double period,
                     NSInteger screenIndex, double globalLeft, double globalTop, double globalRight,
                     double globalBottom, NSUInteger drawableCount,
                     bool waitConfirm, bool vsync, bool doCapture, bool readable) {
    if (!appPrepared)
        fail("PrepareApp must be called before Open.");
    if (metalWindow || device)
        fail("PsychMetal native resources are already open.");
    if(!graphicsLocked) { hookPin(); graphicsLocked=true; }
    pthread_mutex_lock(&lock); ++sessionEpoch; pthread_mutex_unlock(&lock);
    keyScanMaxMs=secureQueryMaxMs=keyScanTotalMs=secureQueryTotalMs=0;keyReadCount=0;
    startupRecords.clear();startupReady=false;
    requestedDrawableCount = drawableCount;
    directWaitForConfirm = waitConfirm;
    displaySync = vsync;
    device = MTLCreateSystemDefaultDevice();
    if (!device)
        failOpen(pm::kErrMetal, @"No Metal device.");
    queue = [device newCommandQueue];
    if (!queue)
        failOpen(pm::kErrMetal, @"Could not create a Metal command queue.");
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
                @"Could not match CoreGraphics display rectangle exactly; using AppKit display index %ld.",
                (long)screenIndex];
        }
        if (!screen) {
            screen = NSScreen.mainScreen;
            selectedScreenIndex = 0;
            mappingWarning = @"Could not identify the requested display; using the main display.";
        }
        selectedDisplayID = (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        displayCaptured = doCapture &&
                          CGDisplayCapture(selectedDisplayID) == kCGErrorSuccess;
        metalWindow = [[NSWindow alloc] initWithContentRect:screen.frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO
                                                     screen:screen];
        metalWindow.releasedWhenClosed = NO;
        metalWindow.animationBehavior = NSWindowAnimationBehaviorNone;
        metalWindow.title = @"PsychMetal";
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
        layer.framebufferOnly = readable ? NO : YES;
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
        hookWarn(pm::kWarnDisplayMapping, "%s", mappingWarning.UTF8String);
    if (doCapture && !displayCaptured)
        hookWarn(pm::kWarnDisplayCapture,
                           "Could not capture the display; the window is above the shielding "
                           "level but the compositor may still be in the path.");
    settleAppKit(1.0);
    __block double originError = 0;
    onMainSync(^{
        NSScreen *sc = metalWindow.screen ? metalWindow.screen : NSScreen.mainScreen;
        if (sc)
            originError = fabs(metalWindow.frame.origin.y - sc.frame.origin.y) +
                          fabs(metalWindow.frame.origin.x - sc.frame.origin.x);
    });
    if (originError > 0.5)
        failOpen(pm::kErrWindowOrigin,
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
        failOpen(pm::kErrDrawableSize,
                 [NSString stringWithFormat:
                    @"Metal drawable is %.0fx%.0f but the render rectangle is %lux%lu. "
                     "Refusing to scale the stimulus.", actualDrawableSize.width,
                    actualDrawableSize.height, (unsigned long)w, (unsigned long)h]);
    ifi = period;
    renderWidth = w;
    renderHeight = h;
    captureToken = 0;
    if (readable) {
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        cd.usage = MTLTextureUsageShaderRead;
        cd.storageMode = MTLStorageModeShared;
        captureTexture = [device newTextureWithDescriptor:cd];
        if (!captureTexture)
            failOpen(pm::kErrMetal, @"Could not allocate the readback texture.");
    }
    NSString *source = [NSString stringWithUTF8String:PMMetalSource];
    NSError *shaderError = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&shaderError];
    if (!lib)
        failOpen(pm::kErrShader, [NSString stringWithFormat:@"Metal shader failed: %@",
                                       shaderError.localizedDescription]);
    shapePipeline = makePipeline(lib, @"svmain", @"sfmain", &shaderError);
    if (!shapePipeline)
        failOpen(pm::kErrPipeline, [NSString stringWithFormat:@"Metal shape pipeline failed: %@",
                                         shaderError.localizedDescription]);
    for (int i = 0; i < PM_SHAPE_RING; i++) {
        shapeBuffers[i] = [device newBufferWithLength:PM_MAX_SHAPES * sizeof(PMShape)
                                              options:MTLResourceStorageModeShared];
        if (!shapeBuffers[i])
            failOpen(pm::kErrMetal, @"Could not allocate the shape instance buffer.");
    }
    shapeBufferIndex = 0;
    drawCount = 0;

    texturePipeline = makePipeline(lib, @"tvmain", @"tfmain", &shaderError);
    if (!texturePipeline)
        failOpen(pm::kErrPipeline,
                 [NSString stringWithFormat:@"Metal texture pipeline failed: %@",
                  shaderError.localizedDescription]);
    linearSampler = makeSampler(MTLSamplerMinMagFilterLinear);
    if (!linearSampler)
        failOpen(pm::kErrMetal, @"Could not create the texture sampler.");
    nearestSampler = makeSampler(MTLSamplerMinMagFilterNearest);
    if (!nearestSampler)
        failOpen(pm::kErrMetal, @"Could not create the nearest-neighbour sampler.");

    pthread_mutex_lock(&lock);
    memset(rec, 0, sizeof(rec));
    pthread_mutex_unlock(&lock);
    firstSessionToken=nextToken;
    preparedToken=0;
    lastSlipToken=lastConfirmedToken=0;
    for(bool &busy:shapeBufferBusy) busy=false;
    confirmedCount = 0;
    missingPresentedCount = 0;
    lastTargetErrorMs = NAN;
    lastConfirmDelayMs = NAN;
    inFlightCount = 0;
    asynchronousGpuFailure=false;
    lastConfirmedPresented = NAN;
    lastConfirmedProjected = NAN;
    pendingSlipRefreshes = 0.0;
    prefetchDrawable = 0;
    heldDrawable = nil;
    gridFirstPresented = gridLastPresented = 0;
    lastProjected = NAN;
    gridFirstFrame = gridLastFrame = 0;
    gridSamples = 0;
    measuredIFI = 0;
    directNoDrawableCount = 0;
    directTimeoutCount = 0;
    leadEstimate = pipelineEstimate = gpuEstimate = PMEstimate{};
    pthread_mutex_lock(&lock);
    closing = false;
    pthread_mutex_unlock(&lock);
}
static double gridPeriod(void) { return (measuredIFI > 0) ? measuredIFI : ifi; }

static double gridPointAtOrAfter(double t) {
    if (gridSamples == 0)
        return NAN;
    double period = gridPeriod();
    double k = ceil((t - gridLastPresented) / period - 1e-9);
    return gridLastPresented + k * period;
}

static bool sleepUntil(double deadline) {
    while (CACurrentMediaTime() < deadline) {
        if (closing)
            return false;
        waitRelative(deadline);
    }
    return !closing;
}

// A first scheduled frame has no measured grid yet: preserve its absolute deadline.
struct PMPresentationTarget { double target, request; };
static PMPresentationTarget presentationTarget(double now,double when,bool scheduled,double aligned,double period) {
    if(!scheduled) return {NAN,NAN};
    if(isfinite(aligned)) return {aligned,aligned-0.5*period};
    double absolute=std::max(now,when);
    return {absolute,absolute};
}

// Caller holds lock on entry. All return paths release it; onset values are predictions until confirmed.
static uint64_t enqueueDirect(double when, bool haveWhen) {
    if(asynchronousGpuFailure || nextToken>=PM_MAX_ID) {
        pthread_mutex_unlock(&lock);
        fail("Presentation session failed; Close and reopen the window.");
    }
    uint64_t t = nextToken++;
    Record *r = &rec[t % NREC];
    memset(r, 0, sizeof(*r));
    r->token = t;
    r->status = 2;
    r->requestedTime = haveWhen ? when : NAN;
    r->presentRequest = NAN;
    r->projected = NAN;

    double targetNow=CACurrentMediaTime();
    PMPresentationTarget presentation=presentationTarget(targetNow,when,haveWhen,
        haveWhen?gridPointAtOrAfter(fmax(when,targetNow)):NAN,gridPeriod());
    double target=presentation.target;
    if (isfinite(target)) {
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
            if (waitRelative(poolDeadline) == ETIMEDOUT) {
                pthread_mutex_unlock(&lock);
                fail("Timed out waiting for outstanding presentations; Close and reopen.");
            }
    }
    double now = CACurrentMediaTime();
    double slip = 0.0;
    if (lastConfirmedToken!=lastSlipToken && isfinite(lastConfirmedPresented) && isfinite(lastConfirmedProjected)) {
        lastSlipToken=lastConfirmedToken;
        double err = (lastConfirmedPresented - lastConfirmedProjected) / gridPeriod();
        slip = (fabs(err) >= 0.5) ? (double)llround(err) : 0.0;
    }
    pendingSlipRefreshes = slip;

    double predicted = isfinite(target) ? target : gridPointAtOrAfter(now);
    if (!isfinite(predicted))
        predicted = now + ifi;
    if (isfinite(lastProjected) && predicted <= lastProjected + 0.5 * gridPeriod())
        predicted = lastProjected + gridPeriod();
    r->projected = predicted;
    r->presentRequest = presentation.request;
    r->scheduledAt = now;
    r->scheduled = 1;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);

    double acquireBegan=CACurrentMediaTime();
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
        lastProjected = predicted;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        return t;
    }
    double acquiredAt=CACurrentMediaTime();
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!encodeFrame(cb, d, t)) {
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
    pthread_mutex_lock(&lock);
    Record *q = recordFor(t);
    if (q) {
        q->inFlight = 1;
        q->committedAt = CACurrentMediaTime();
        q->drawableAcquireMs=(acquiredAt-acquireBegan)*1000;
        q->encodeMs=(q->committedAt-acquiredAt)*1000;
        inFlightCount++;
    }
    pthread_mutex_unlock(&lock);
    if (isfinite(target))
        [cb presentDrawable:d atTime:presentation.request];
    else
        [cb presentDrawable:d];
    [cb commit];

    pthread_mutex_lock(&lock);
    Record *pr = recordFor(t);
    if (pr && pr->committedAt > 0.0) {
        double earliest = gridPointAtOrAfter(pr->committedAt) + gridPeriod();
        double pred;
        if (isfinite(earliest))
            pred = isfinite(target) ? fmax(target, earliest) : earliest;
        else
            pred = isfinite(target) ? target : predicted;
        if (!isfinite(pred))
            pred = predicted;
        if (isfinite(lastProjected) && pred <= lastProjected + 0.5 * gridPeriod())
            pred = lastProjected + gridPeriod();
        if (isfinite(pred)) {
            lastProjected = pred;
            pr->projected = pred;
        }
    }
    pthread_mutex_unlock(&lock);

    double prefetchBegan=CACurrentMediaTime();
    if (prefetchDrawable && !heldDrawable) heldDrawable=layer.nextDrawable;
    pthread_mutex_lock(&lock);
    if(Record *q=recordFor(t)) q->prefetchMs=(CACurrentMediaTime()-prefetchBegan)*1000;
    pthread_mutex_unlock(&lock);
    return t;
}
static uint64_t prepareFlip(void) {
    if(!device || closing) fail("PsychMetal is not open.");
    if (preparedToken)
        fail("A frame is already prepared; call PresentNow before preparing another.");

    pthread_mutex_lock(&lock);
    if(asynchronousGpuFailure || nextToken>=PM_MAX_ID) {
        pthread_mutex_unlock(&lock);
        fail("Presentation session failed; Close and reopen the window.");
    }
    uint64_t t = nextToken++;
    Record *r = &rec[t % NREC];
    memset(r, 0, sizeof(*r));
    r->token = t;
    r->status = 2;
    r->requestedTime = NAN;
    r->presentRequest = NAN;
    r->projected = NAN;
    pthread_mutex_unlock(&lock);

    id<CAMetalDrawable> d = heldDrawable; heldDrawable=nil;
    if(!d) d=layer.nextDrawable;
    if (!d) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(t);
        if (q) { q->status = 4; q->done = 1; q->gpuDone = 1; q->scheduled = 1; }
        directNoDrawableCount++;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        fail("Could not prepare frame: no drawable or encoding failed.");
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!encodeFrame(cb, d, t)) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(t);
        if (q) { q->status = 3; q->done = 1; q->gpuDone = 1; q->scheduled = 1; }
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        fail("Could not prepare frame: no drawable or encoding failed.");
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

static pm::PresentResult presentNow(void) {
    pthread_mutex_lock(&lock);
    bool failed=asynchronousGpuFailure;
    pthread_mutex_unlock(&lock);
    if(failed) fail("GPU failure in prepared frame; Close and reopen.");
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
    return {t0, (t1 - t0) * 1000.0};
}
static uint64_t enqueue(double when, bool haveWhen) {
    if(!device || closing) fail("PsychMetal is not open.");
    if(preparedToken) fail("Present or cancel the prepared frame before Flip.");
    pthread_mutex_lock(&lock);
    return enqueueDirect(when, haveWhen);
}
// Initialization frames are confirmed separately, not returned as stimulus frames.
static std::vector<pm::StartupRecord> startupHistoryRecords() {
    std::vector<pm::StartupRecord> out;
    out.reserve(startupRecords.size());
    for(const Record &r:startupRecords)
        out.push_back({r.token,r.status,r.presented,r.callback,r.gpuDone,r.committedAt});
    return out;
}
static void confirmStartup() {
    if(!device || closing) fail("PsychMetal is not open.");
    if(startupReady) return;
    if(drawCount || preparedToken) fail("Confirm startup before queuing stimulus drawing.");
    // Open has not enabled prefetch yet. Never hold a second drawable while waiting.
    if(prefetchDrawable || heldDrawable) fail("Confirm startup before enabling drawable prefetch.");
    startupRecords.reserve(12);
    int consecutive=0;
    double deadline=CACurrentMediaTime()+2.0;
    while(startupRecords.size()<12 && CACurrentMediaTime()<deadline) {
        uint64_t token=enqueue(0,false);
        pthread_mutex_lock(&lock);
        Record *r=recordFor(token);
        while(r && (!r->done || !r->gpuDone)) {
            if(waitRelative(deadline)==ETIMEDOUT) break;
            r=recordFor(token);
        }
        Record snapshot=r?*r:Record{};
        bool found=r!=nullptr, gpuFailed=asynchronousGpuFailure;
        pthread_mutex_unlock(&lock);
        startupRecords.push_back(snapshot);
        if(!found || !snapshot.done || !snapshot.gpuDone)
            fail("OpenWindow startup timed out; background presentation was not confirmed. StartupHistory retains the attempts.");
        if(snapshot.status==3 || snapshot.status==4 || gpuFailed)
            fail("OpenWindow startup rendering failed. StartupHistory retains the attempts.");
        consecutive=(snapshot.status==0 && snapshot.presented>0)?consecutive+1:0;
        if(consecutive>=2) {
            pthread_mutex_lock(&lock);
            // Keep the calibrated grid, but start user-frame history/counters after initialization.
            firstSessionToken=nextToken;confirmedCount=0;missingPresentedCount=0;
            lastSlipToken=lastConfirmedToken;pendingSlipRefreshes=0;
            startupReady=true;
            pthread_mutex_unlock(&lock);
            return;
        }
    }
    fail("OpenWindow startup failed to obtain two consecutive confirmations within 12 attempts / two seconds. StartupHistory retains the attempts.");
}
static Record waitScheduled(uint64_t t, double timeoutAt) {
    pthread_mutex_lock(&lock);
    Record *r = recordFor(t);
    if (!r || t<firstSessionToken || t>=nextToken) {
        pthread_mutex_unlock(&lock);
        fail("Unknown or expired frame token.");
    }
    if (directWaitForConfirm)
        while (!r->done)
            if (waitRelative(timeoutAt) == ETIMEDOUT) {
                directTimeoutCount++;
                break;
            }
    Record out = *r;
    pthread_mutex_unlock(&lock);
    if(out.status==3) fail("GPU command or frame encoding failed.");
    if(out.status==4) fail("No Metal drawable was available.");
    if(out.status==1) fail("Presentation callback returned no timestamp.");
    if(directWaitForConfirm && !out.done) fail("Timed out waiting for presentation confirmation.");
    return out;
}
static void drainRecords(void) {
    pthread_mutex_lock(&lock);
    drainLocked();
    pthread_mutex_unlock(&lock);
}
static std::vector<pm::FrameRecord> historyRecords(void) {
    std::vector<Record> snapshot;
    pthread_mutex_lock(&lock);
    uint64_t end = nextToken;
    uint64_t start = std::max(firstSessionToken, (end > NREC) ? end - NREC : 1);
    size_t count = (size_t)(end - start);
    pthread_mutex_unlock(&lock);
    snapshot.reserve(count);
    pthread_mutex_lock(&lock);
    for (uint64_t t = start; t < end; t++) {
        Record *r = recordFor(t);
        snapshot.push_back(r ? *r : Record{});
    }
    pthread_mutex_unlock(&lock);
    std::vector<pm::FrameRecord> out;
    out.reserve(count);
    for (const Record &r : snapshot)
        out.push_back({r.token, r.projected, r.presented, r.done ? r.status : 2, r.scheduledAt,
                       r.callback, r.commandStatus, r.requestedTime, r.gpuStart, r.gpuEnd,
                       r.presentRequest, r.presentCallMs, r.committedAt, r.drawableAcquireMs,
                       r.encodeMs, r.prefetchMs});
    return out;
}

// ===========================================================================
// pm:: — the engine boundary (PsychMetalEngine.h). Argument unpacking belongs
// to the front ends. Every entry point that touches Objective-C opens an
// @autoreleasepool: without one, autoreleased drawables would pile up on the
// caller thread. Internals whose names collide with pm:: functions are called
// with :: (prepareApp, confirmStartup, prepareFlip, presentNow, waitScheduled).
// ===========================================================================

void pm::installHostHooks(const pm::HostHooks &h) { hooks = h; }

void pm::shutdown() noexcept {
    @autoreleasepool {
        try {
            if (device || metalWindow || appPrepared) closeCore();
            else releaseKeyboardQueue();
        } catch (...) {}
    }
}

bool pm::onMainThread() noexcept { return pthread_main_np() != 0; }

void pm::serviceMainRunLoop(double seconds) {
    if (!pthread_main_np())
        fail("serviceMainRunLoop must be called on the main thread.");
    @autoreleasepool {
        static bool launched = false;
        NSApplication *app = [NSApplication sharedApplication];
        if (!launched) { [app finishLaunching]; launched = true; }
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
        NSEvent *event;
        while ((event = [app nextEventMatchingMask:NSEventMaskAny untilDate:until
                                            inMode:NSDefaultRunLoopMode dequeue:YES])) {
            NSEventType t = event.type;
            if (t != NSEventTypeKeyDown && t != NSEventTypeKeyUp && t != NSEventTypeFlagsChanged)
                [app sendEvent:event];
            until = [NSDate distantPast];   // drain what is queued, then return
        }
    }
}

// --- session lifecycle ------------------------------------------------------

const char *pm::version() noexcept { return pm::kEngineVersion; }

void pm::prepareApp() { @autoreleasepool { ::prepareApp(); } }

pm::OpenResult pm::openSession(const pm::OpenOptions &o) {
    @autoreleasepool {
        double screenIndex = o.screenIndex;
        if (screenIndex != floor(screenIndex) || screenIndex < -1)
            fail("screen index must be a non-negative integer, or -1 for the last display.");
        if (o.drawableCount > 3)
            fail("maximum drawable count must be a nonnegative integer in range.");
        if (o.drawableCount < 2)
            fail("Drawable count must be 2 or 3.");

        uint32_t count = 0;
        CGDirectDisplayID ids[16];
        if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || count == 0)
            fail("No active displays.");
        if (screenIndex < 0)
            screenIndex = (double)count - 1;
        if (screenIndex >= count)
            failWith(pm::kErrScreen, "Screen index %d is out of range; %u display(s) are active.",
                     (int)screenIndex, count);
        CGDirectDisplayID did = ids[(uint32_t)screenIndex];
        CGRect b = CGDisplayBounds(did);
        size_t pxW = CGDisplayPixelsWide(did), pxH = CGDisplayPixelsHigh(did);
        CGDisplayModeRef dm = CGDisplayCopyDisplayMode(did);
        double hz = dm ? CGDisplayModeGetRefreshRate(dm) : 0.0;
        if (dm) {
            size_t mw = CGDisplayModeGetPixelWidth(dm);
            size_t mh = CGDisplayModeGetPixelHeight(dm);
            if (mw && mh) { pxW = mw; pxH = mh; }
            CGDisplayModeRelease(dm);
        }
        if (!(hz > 0.0) && !o.refreshHz) {
            hookWarn(pm::kWarnRefresh, "Display does not report a fixed refresh rate. Using provisional 60 Hz; set a fixed display mode and supply OpenWindow refreshHz for timing work.");
            hz = 60.0;
        }
        if (o.refreshHz) {
            double overrideHz = *o.refreshHz;
            if (overrideHz < 20 || overrideHz > 1000) fail("refreshHz must be 20..1000.");
            hz = overrideHz;
        }
        double period = 1.0 / hz;
        if (!pxW || !pxH)
            fail("Could not determine the display's pixel size.");

        clearRGBA[0] = clearRGBA[1] = clearRGBA[2] = 0.0f;
        clearRGBA[3] = 1.0f;
        openCore((NSUInteger)pxW, (NSUInteger)pxH, period,
                 (NSInteger)screenIndex,
                 b.origin.x, b.origin.y,
                 b.origin.x + b.size.width, b.origin.y + b.size.height,
                 (NSUInteger)o.drawableCount, o.waitForConfirm, o.displaySync, o.captureDisplay,
                 o.readback);
        return {(double)pxW, (double)pxH, period, b.size.width, b.size.height, sessionEpoch};
    }
}

std::vector<pm::StartupRecord> pm::startupHistory() { return startupHistoryRecords(); }

std::vector<pm::StartupRecord> pm::confirmStartup() {
    @autoreleasepool {
        ::confirmStartup();
        return startupHistoryRecords();
    }
}

void pm::closeSession() { @autoreleasepool { closeCore(); } }

// --- presentation -----------------------------------------------------------

pm::FlipResult pm::flip(double target) {
    @autoreleasepool {
        double began = CACurrentMediaTime();
        if (target < 0) fail("Target must be nonnegative.");
        uint64_t token = enqueue(target, target > 0);
        double queued = CACurrentMediaTime();
        Record r = ::waitScheduled(token, std::max(queued, target) + 2);
        bool confirmed = r.status == 0 && r.presented > 0;
        pm::FlipResult out{};
        out.time = confirmed ? r.presented : r.projected;
        out.confirmed = confirmed;
        pthread_mutex_lock(&lock);
        out.slipRefreshes = pendingSlipRefreshes;
        out.gridPeriod = gridPeriod();
        pthread_mutex_unlock(&lock);
        out.queueMs = (queued - began) * 1000;
        out.returnTime = CACurrentMediaTime();
        out.callMs = (out.returnTime - began) * 1000;
        out.token = token;
        return out;
    }
}

uint64_t pm::queueFrame(std::optional<double> when) {
    @autoreleasepool { return enqueue(when ? *when : 0, when.has_value()); }
}

pm::ScheduleResult pm::waitScheduled(uint64_t token, std::optional<double> when) {
    double timeoutAt = CACurrentMediaTime() + 2.0;
    if (when && *when + 2.0 > timeoutAt)
        timeoutAt = *when + 2.0;
    if (token > PM_MAX_ID) fail("frame token must be a nonnegative integer in range.");
    Record r = ::waitScheduled(token, timeoutAt);
    bool confirmed = (r.status == 0 && r.presented > 0);
    pm::ScheduleResult out{};
    out.time = confirmed ? r.presented : r.projected;
    out.scheduled = r.scheduled != 0;
    out.confirmed = confirmed;
    out.slipRefreshes = pendingSlipRefreshes;
    pthread_mutex_lock(&lock); out.gridPeriod = gridPeriod(); pthread_mutex_unlock(&lock);
    return out;
}

uint64_t pm::prepareFlip() { @autoreleasepool { return ::prepareFlip(); } }

pm::PresentResult pm::presentNow() {
    @autoreleasepool { return ::presentNow(); }
}

void pm::setDisplaySync(bool enabled) {
    if (!layer) fail("PsychMetal is not open.");
    @autoreleasepool {
        __block BOOL on = enabled ? YES : NO;
        onMainSync(^{ layer.displaySyncEnabled = on; });
    }
    pthread_mutex_lock(&lock);
    displaySync = enabled;
    pthread_mutex_unlock(&lock);
}

void pm::setPrefetchDrawable(bool enabled) {
    if (!device) fail("PsychMetal is not open.");
    prefetchDrawable = enabled ? 1 : 0;
    if (!prefetchDrawable)
        heldDrawable = nil;
}

// --- refresh grid -----------------------------------------------------------

pm::GridAnchor pm::gridAnchor() {
    pthread_mutex_lock(&lock);
    double anchor = (gridSamples > 0) ? gridLastPresented : NAN;
    double period = gridPeriod();
    double n = (double)gridSamples;
    pthread_mutex_unlock(&lock);
    return {anchor, period, n};
}

double pm::nextPhase(double after, double phase) {
    pthread_mutex_lock(&lock);
    double t = NAN;
    if (gridSamples > 0) {
        double p = gridPeriod();
        double base = gridLastPresented + phase * p;
        double k = ceil((after - base) / p - 1e-9);
        t = base + k * p;
    }
    pthread_mutex_unlock(&lock);
    return t;
}

double pm::nextRefresh(double after) {
    pthread_mutex_lock(&lock);
    double next = gridPointAtOrAfter(after);
    pthread_mutex_unlock(&lock);
    return next;
}

pm::WaitToDrawResult pm::waitToDraw(double target, double budget) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (budget < 0) fail("Drawing budget must be nonnegative.");
    pthread_mutex_lock(&lock);
    double pipeline = (pipelineEstimate.value > 0) ? pipelineEstimate.value : (1.7 * ifi);
    double gpu = (gpuEstimate.value > 0) ? gpuEstimate.value : 0.002;
    double lead = pipeline + gpu + 0.002;
    double deadline = target - lead - budget;
    if (deadline > CACurrentMediaTime())
        sleepUntil(deadline);
    double wokeAt = CACurrentMediaTime();
    pthread_mutex_unlock(&lock);
    return {wokeAt, lead, deadline};
}

// --- drawing ----------------------------------------------------------------

void pm::setBackgroundColor(double r, double g, double b, double a) {
    const double v[4] = {r, g, b, a};
    for (int i = 0; i < 4; i++) {
        if (!(v[i] >= 0.0 && v[i] <= 1.0))
            fail("Background colour components run 0 to 1.");
        clearRGBA[i] = (float)v[i];
    }
}

static inline double viewAt(const pm::ArrayView &v, size_t i, size_t j = 0) {
    return *(const double *)((const unsigned char *)v.data + (ptrdiff_t)i * v.strides[0] +
                             (ptrdiff_t)j * v.strides[1]);
}

void pm::addShapes(const pm::ArrayView &kindV, const pm::ArrayView &paramV,
                   const pm::ArrayView &rectV, const pm::ArrayView &colorV,
                   const pm::ArrayView &extraV) {
    if (!device)
        fail("PsychMetal is not open.");
    const pm::ArrayView *all[5] = {&kindV, &paramV, &rectV, &colorV, &extraV};
    for (const pm::ArrayView *v : all)
        if (v->type != pm::ScalarType::Float64)
            fail("AddShapes arguments must be real double arrays.");
    size_t n = kindV.ndim == 1 ? kindV.shape[0] : 0;
    bool shapesOk = kindV.ndim == 1 && paramV.ndim == 1 && paramV.shape[0] == n;
    for (int i = 2; i < 5; i++)
        shapesOk = shapesOk && all[i]->ndim == 2 && all[i]->shape[0] == n && all[i]->shape[1] == 4;
    if (!shapesOk)
        fail("AddShapes expects kind and param as 1xN and rect, color and extra as 4xN.");
    if (n == 0)
        return;
    if(n>PM_MAX_SHAPES-drawCount) fail("Frame draw capacity exceeded; split the work across frames.");
    for(size_t k=0;k<n;k++) {
        double kind=viewAt(kindV,k), param=viewAt(paramV,k);
        if(!isfinite(kind) || kind!=floor(kind) || kind<0 || kind>7) fail("Invalid shape kind.");
        if(!isfinite(param) || fabs(param)>FLT_MAX || param<0) fail("Invalid shape parameter.");
        for(int c=0;c<4;c++) {
            double rect=viewAt(rectV,k,c), color=viewAt(colorV,k,c), extra=viewAt(extraV,k,c);
            if(!isfinite(rect) || fabs(rect)>FLT_MAX ||
               !isfinite(color) || color<0 || color>1 ||
               !isfinite(extra) || fabs(extra)>FLT_MAX)
                fail("Shape arrays contain invalid values.");
        }
    }
    pthread_mutex_lock(&lock);
    for (size_t k = 0; k < n; k++) {
        PMDrawItem *item = &drawList[drawCount++];
        memset(item, 0, sizeof(*item));
        item->type = PM_ITEM_SHAPE;
        item->texIndex = -1;
        PMShape *sh = &item->shape;
        sh->kind = (uint32_t)viewAt(kindV, k);
        sh->param = (float)viewAt(paramV, k);
        for (int c = 0; c < 4; c++) {
            sh->rect[c] = (float)viewAt(rectV, k, c);
            sh->color[c] = (float)viewAt(colorV, k, c);
            sh->extra[c] = (float)viewAt(extraV, k, c);
        }
        sh->pad[0] = sh->pad[1] = 0.0f;
        if (!haveLastShape) {
            lastShape = *sh;
            haveLastShape = true;
        }
        shapesAppended++;
    }
    pthread_mutex_unlock(&lock);
}

uint64_t pm::makeTexture(const pm::ArrayView &image) {
    if(!device || closing) fail("PsychMetal is not open.");
    int slot=-1;
    for(int i=0;i<PM_MAX_TEXTURES;i++) if(!userTextures[i]) { slot=i; break; }
    if(slot<0) fail("No free texture slots.");
    if(nextTextureHandle>=PM_MAX_ID) fail("Texture handle space exhausted.");
    @autoreleasepool { uploadTexture(slot,image); }
    textureHandles[slot]=nextTextureHandle++;
    texturesCreated++;
    return textureHandles[slot];
}

void pm::updateTexture(uint64_t handle, const pm::ArrayView &image) {
    if(!device || closing) fail("PsychMetal is not open.");
    int slot=textureSlot(handle);
    @autoreleasepool { uploadTexture(slot,image); }
    textureUpdates++;
}

void pm::drawTextures(const pm::ArrayView &handleV, const pm::ArrayView &srcV,
                      const pm::ArrayView &dstV, const pm::ArrayView &angleV,
                      const pm::ArrayView &tintV, const pm::ArrayView &filterV) {
    if (!device)
        fail("PsychMetal is not open.");
    const pm::ArrayView *all[6] = {&handleV, &srcV, &dstV, &angleV, &tintV, &filterV};
    for (const pm::ArrayView *v : all)
        if (v->type != pm::ScalarType::Float64)
            fail("DrawTextures arguments must be real double arrays.");
    size_t n = handleV.ndim == 1 ? handleV.shape[0] : 0;
    bool shapesOk = handleV.ndim == 1 && angleV.ndim == 1 && angleV.shape[0] == n &&
                    filterV.ndim == 1 && filterV.shape[0] == n;
    for (const pm::ArrayView *v : {&srcV, &dstV, &tintV})
        shapesOk = shapesOk && v->ndim == 2 && v->shape[0] == n && v->shape[1] == 4;
    if (!shapesOk)
        fail("DrawTextures expects handles, angles and filter modes as 1xN and "
             "srcRects, dstRects and tints as 4xN.");
    if (n == 0)
        return;
    if(n>PM_MAX_SHAPES-drawCount) fail("Frame draw capacity exceeded; split the work across frames.");
    // Check every entry before queuing any. Caller-thread scratch, like the
    // draw list (one-caller rule).
    static int slots[PM_MAX_SHAPES];
    for (size_t k = 0; k < n; k++) {
        slots[k] = textureSlot(pm::checkUnsigned(viewAt(handleV, k), "texture handle", pm::kMaxId));
        pm::checkUnsigned(viewAt(filterV, k), "filter mode", 1);
        for (int c = 0; c < 4; c++) {
            double s = viewAt(srcV, k, c), d = viewAt(dstV, k, c), t = viewAt(tintV, k, c);
            if (!isfinite(s) || !isfinite(d) || !isfinite(t) || fabs(s) > FLT_MAX ||
                fabs(d) > FLT_MAX || t < 0 || t > 1)
                fail("Invalid texture rectangle or tint.");
        }
        double angle = viewAt(angleV, k);
        if (!isfinite(angle) || fabs(angle) > FLT_MAX) fail("Rotation angle out of range.");
    }
    for (size_t k = 0; k < n; k++)
        drawTextureRefs[drawCount + k] = userTextures[slots[k]];
    pthread_mutex_lock(&lock);
    for (size_t k = 0; k < n; k++) {
        PMDrawItem *item = &drawList[drawCount++];
        memset(item, 0, sizeof(*item));
        item->type = PM_ITEM_TEXTURE;
        item->texIndex = slots[k];
        for (int c = 0; c < 4; c++) {
            item->src[c] = (float)viewAt(srcV, k, c);
            item->dst[c] = (float)viewAt(dstV, k, c);
            item->tint[c] = (float)viewAt(tintV, k, c);
        }
        item->angle = (float)viewAt(angleV, k);
        item->filterMode = (int32_t)viewAt(filterV, k);
    }
    pthread_mutex_unlock(&lock);
}

void pm::closeTexture(uint64_t handle) {
    int slot = textureSlot(handle);
    userTextures[slot].reset(); texturePools[slot].clear(); textureHandles[slot]=0;
}

pm::ImageRegion pm::checkImageRect(const std::optional<pm::Rect4> &rect) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (!captureTexture) fail("GetImage requires a window opened with readback.");
    if (!rect) return {0, 0, (size_t)renderWidth, (size_t)renderHeight};
    const pm::Rect4 &r = *rect;
    for (double v : r)
        if (!isfinite(v) || v != floor(v))
            fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    if (r[0] < 0 || r[1] < 0 || r[2] <= r[0] || r[3] <= r[1] ||
        r[2] > (double)renderWidth || r[3] > (double)renderHeight)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    return {(size_t)r[0], (size_t)r[1], (size_t)(r[2] - r[0]), (size_t)(r[3] - r[1])};
}

void pm::getImage(const pm::ImageRegion &g, const pm::MutableByteView &out) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (!captureTexture) fail("GetImage requires a window opened with readback.");
    if (!g.width || !g.height || g.x + g.width > (size_t)renderWidth || g.y + g.height > (size_t)renderHeight)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    if (!out.data || out.ndim != 3 || out.shape[0] != g.height || out.shape[1] != g.width || out.shape[2] != 3)
        fail("Image output buffer does not match the request.");
    pthread_mutex_lock(&lock);
    uint64_t token = captureToken;
    // Tokens are issued in order by Flip, Queue and PrepareFlip, so the newest
    // one is nextToken - 1. A frame with no drawable or a failed encoding was
    // never copied, and an older copy must not be passed off as that frame.
    if (!token || token != nextToken - 1) {
        pthread_mutex_unlock(&lock);
        fail(token ? "The last frame was not copied; there is nothing to read."
                   : "GetImage needs a frame; Flip first.");
    }
    double deadline = CACurrentMediaTime() + 2.0;
    Record *r = recordFor(token);
    while (r && !r->gpuDone) {
        if (waitRelative(deadline) == ETIMEDOUT) break;
        r = recordFor(token);
    }
    bool rendered = r && r->gpuDone, failed = r && r->status == 3;
    pthread_mutex_unlock(&lock);
    if (!rendered) fail("Timed out waiting for the frame to render.");
    if (failed) fail("GPU command or frame encoding failed.");
    @autoreleasepool {
        captureScratch.resize(g.width * g.height * 4);
        [captureTexture getBytes:captureScratch.data() bytesPerRow:g.width * 4
                      fromRegion:MTLRegionMake2D(g.x, g.y, g.width, g.height) mipmapLevel:0];
    }
    // The drawable is BGRA; the result is RGB in the caller's layout.
    const uint8_t *src = captureScratch.data();
    for (size_t y = 0; y < g.height; y++) {
        uint8_t *row = out.data + (ptrdiff_t)y * out.strides[0];
        for (size_t x = 0; x < g.width; x++, src += 4) {
            uint8_t *px = row + (ptrdiff_t)x * out.strides[1];
            px[0] = src[2];
            px[out.strides[2]] = src[1];
            px[2 * out.strides[2]] = src[0];
        }
    }
}

// --- display modes and cursor ----------------------------------------------

static CGDirectDisplayID displayForIndex(double si) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || count == 0)
        fail("No active displays.");
    if (si < 0) si = (double)count - 1;
    if (si != floor(si) || si >= count)
        fail("Screen index is out of range.");
    return ids[(uint32_t)si];
}

// Every mode of a display, the low-resolution duplicates included. The caller releases it.
static CFArrayRef copyAllModes(CGDirectDisplayID did) {
    const void *keys[] = { kCGDisplayShowDuplicateLowResolutionModes };
    const void *vals[] = { kCFBooleanTrue };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef all = CGDisplayCopyAllDisplayModes(did, opts);
    if (opts) CFRelease(opts);
    if (!all)
        fail("Could not list display modes.");
    return all;
}

std::vector<pm::DisplayMode> pm::modes(double screenIndex) {
    CGDirectDisplayID did = displayForIndex(screenIndex);
    CFArrayRef all = copyAllModes(did);
    CFIndex n = CFArrayGetCount(all);
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(did);
    std::vector<pm::DisplayMode> out;
    out.reserve((size_t)n);
    for (CFIndex pass = 0; pass < 2; pass++) {
        for (CFIndex i = 0; i < n; i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
            bool isCur = cur && CFEqual(m, cur);
            if ((pass == 0) != isCur)
                continue;
            double hz = CGDisplayModeGetRefreshRate(m);
            if (!(hz > 0.0)) hz = 60.0;
            out.push_back({(double)CGDisplayModeGetWidth(m), (double)CGDisplayModeGetHeight(m),
                           (double)CGDisplayModeGetPixelWidth(m), (double)CGDisplayModeGetPixelHeight(m), hz});
        }
    }
    if (cur) CGDisplayModeRelease(cur);
    CFRelease(all);
    return out;
}

void pm::setMode(double screenIndex, double wantW, double wantH) {
    if (device)
        fail("Close the PsychMetal window before changing the display mode.");
    CGDirectDisplayID did = displayForIndex(screenIndex);
    CFArrayRef all = copyAllModes(did);
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
        failWith(pm::kErrMode, "No display mode is %g x %g points on that display.", wantW, wantH);
    }
    CGError e = CGDisplaySetDisplayMode(did, best, NULL);
    CFRelease(all);
    if (e != kCGErrorSuccess)
        failWith(pm::kErrMode, "CGDisplaySetDisplayMode failed with error %d.", (int)e);
}

void pm::setCursorVisible(bool show) {
    CGDirectDisplayID d = selectedDisplayID ? selectedDisplayID : CGMainDisplayID();
    if (show)
        CGDisplayShowCursor(d);
    else
        CGDisplayHideCursor(d);
}

// --- input ------------------------------------------------------------------

pm::MouseState pm::mouse() {
    if (!metalWindow || !selectedDisplayID || !renderWidth || !renderHeight)
        fail("Mouse requires an open PsychMetal window.");
    CGRect b = CGDisplayBounds(selectedDisplayID);
    if (!(b.size.width > 0) || !(b.size.height > 0))
        fail("Could not read the presentation display bounds.");
    CGEventRef event = CGEventCreate(NULL);
    if (!event)
        fail("Could not read the current mouse position.");
    CGPoint p = CGEventGetLocation(event);
    CFRelease(event);
    const double sx = (double)renderWidth / b.size.width;
    const double sy = (double)renderHeight / b.size.height;
    pm::MouseState out{};
    out.x = (p.x - b.origin.x) * sx;
    out.y = (p.y - b.origin.y) * sy;
    const CGMouseButton buttonIDs[3] = {
        kCGMouseButtonLeft, kCGMouseButtonRight, kCGMouseButtonCenter
    };
    for (int i = 0; i < 3; i++)
        out.buttons[(size_t)i] = CGEventSourceButtonState(
            kCGEventSourceStateCombinedSessionState, buttonIDs[i]);
    return out;
}

pm::KbQueueStatus pm::kbQueueStatus() {
    auto state=keyboardQueue.stats();
    double pid=0; CFDictionaryRef sess=CGSessionCopyCurrentDictionary();
    if(sess) { CFTypeRef value=CFDictionaryGetValue(sess,CFSTR("kCGSSessionSecureInputPID"));
        if(value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value,kCFNumberDoubleType,&pid);
        CFRelease(sess); }
    return {state.created, state.running, state.interval, state.lastScanInterval,
            state.maxScanInterval, (uint64_t)state.scans, (uint64_t)state.dropped, pid};
}

void pm::kbQueueCreate(const std::array<double, 256> &m, double interval) {
    bool filter[256];
    for(int k=0;k<256;k++) { if(!isfinite(m[(size_t)k])) fail("Key mask must be finite."); filter[k]=(m[(size_t)k]!=0); }
    if(interval<.001 || interval>.1) fail("Poll interval must be between .001 and .1 seconds.");
    keyboardQueue.create(filter,interval);
    if(!keyboardQueueLocked) { hookPin(); keyboardQueueLocked=true; }
}

void pm::kbQueueRelease() { releaseKeyboardQueue(); }

void pm::kbQueueStart() {
    if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
    uint32_t displayCount=0;
    if(CGGetActiveDisplayList(0,nullptr,&displayCount)!=kCGErrorSuccess || !displayCount)
        fail("No active desktop session for keyboard polling.");
    if(!keyboardQueue.start()) fail("Cannot start keyboard queue worker.");
}

void pm::kbQueueStop() {
    if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
    keyboardQueue.stop();
}

void pm::kbQueueFlush() {
    if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
    keyboardQueue.flush();
}

pm::KbEvents pm::kbQueueGetEvents() {
    if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
    unsigned long long dropped=0; auto events=keyboardQueue.events(dropped);
    pm::KbEvents out{};
    out.events.reserve(events.size());
    for(const auto &e:events) out.events.push_back({e.time, e.key, e.pressed});
    out.dropped=(uint64_t)dropped;
    return out;
}

pm::KbCheck pm::kbQueueCheck() {
    if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
    double summary[4][256]; keyboardQueue.check(summary);
    pm::KbCheck out{};
    out.pressed=false;
    for(int k=0;k<256;k++) if(summary[0][k]!=0) out.pressed=true;
    std::array<double,256> *dest[4]={&out.firstPress,&out.firstRelease,&out.lastPress,&out.lastRelease};
    for(int j=0;j<4;j++) memcpy(dest[j]->data(),summary[j],sizeof(summary[j]));
    return out;
}

pm::KeyState pm::keys() {
    pm::KeyState out{};
    double scanStart=CACurrentMediaTime();
    bool state[256]; readKeyboardState(state,nullptr);
    double scanMs=(CACurrentMediaTime()-scanStart)*1000;
    for(int k=0;k<256;k++) out.down[(size_t)k]=state[k];
    out.anyDown = false;
    for (int u = 0; u < 256; u++)
        if (out.down[(size_t)u]) { out.anyDown = true; break; }

    out.secs = CACurrentMediaTime();

    double secureBegan=CACurrentMediaTime();
    // The owner dictionary is diagnostic-only: it can take an entire refresh.
    // Serialize this non-thread-safe API; never call it from the keyboard worker.
    // Do not dispatch to the GUI thread: CLI hosts may not pump its run loop.
    bool secureActive=false;
    { std::lock_guard<std::mutex> guard(secureInputStateLock);
      secureActive=IsSecureEventInputEnabled()!=0; }
    out.securePid=secureActive ? -1.0 : 0.0; // -1 means active, owner not queried

    double secureMs=(CACurrentMediaTime()-secureBegan)*1000;
    keyScanMaxMs=std::max(keyScanMaxMs,scanMs);secureQueryMaxMs=std::max(secureQueryMaxMs,secureMs);
    keyScanTotalMs+=scanMs;secureQueryTotalMs+=secureMs;++keyReadCount;
    return out;
}

// --- time ---------------------------------------------------------------------

double pm::now() noexcept { return CACurrentMediaTime(); }

double pm::waitUntil(double untilTime) {
    static double spinMargin = 0.004;
    double sleepUntilT = untilTime - spinMargin;
    double afterSleep = CACurrentMediaTime();
    if (afterSleep < sleepUntilT) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        if (tb.numer && tb.denom) {
            long double ticks = (long double)sleepUntilT * 1.0e9L *
                                (long double)tb.denom / (long double)tb.numer;
            if(ticks>(long double)UINT64_MAX) fail("Wait deadline exceeds clock range.");
            if (ticks > 0)
                mach_wait_until((uint64_t)ticks);
        }
        afterSleep = CACurrentMediaTime();
        double overrun = afterSleep - sleepUntilT;
        if (overrun > spinMargin * 0.5 && spinMargin < 0.020)
            spinMargin = fmin(0.020, overrun * 2.0);
    }
    while (CACurrentMediaTime() < untilTime) { }
    return CACurrentMediaTime();
}

// --- diagnostics ----------------------------------------------------------------

pm::DiagnosticReport pm::diagnostic() {
    @autoreleasepool {
        pm::DiagnosticReport report{};
        drainRecords();
        report.history = historyRecords();
        __block CGSize drawableSize = CGSizeZero;
        if (metalWindow)
            onMainSync(^{ drawableSize = layer.drawableSize; });
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

        pm::DiagnosticSummary &d = report.summary;
        d.keyScanMaxMs = keyScanMaxMs;
        d.secureQueryMaxMs = secureQueryMaxMs;
        d.keyScanMeanMs = keyReadCount ? keyScanTotalMs / keyReadCount : 0;
        d.secureQueryMeanMs = keyReadCount ? secureQueryTotalMs / keyReadCount : 0;
        d.keyReadCount = (double)keyReadCount;
        d.confirmedPresentations = (double)snapshotConfirmed;
        d.missingPresentedTimes = (double)snapshotMissing;
        d.lastTargetErrorMs = snapshotTargetError;
        d.lastConfirmDelayMs = snapshotConfirmDelay;
        d.appKitScreenIndex = (double)selectedScreenIndex;
        d.cgDisplayID = (double)selectedDisplayID;
        d.renderWidth = (double)renderWidth;
        d.renderHeight = (double)renderHeight;
        d.drawableWidth = drawableSize.width;
        d.drawableHeight = drawableSize.height;
        d.displayCaptured = displayCaptured;
        d.readbackEnabled = captureTexture != nil;
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
        d.modePointWidth = modePointWidth;
        d.modePixelWidth = modePixelWidth;
        d.largestModePixelWidth = nativePixelWidth;
        d.shapesAppended = (double)shapesAppended;
        d.shapesEncoded = (double)shapesEncoded;
        d.shapeEncodeCalls = (double)shapeEncodeCalls;
        d.textureAllocations = (double)textureAllocations;
        d.textureUpdates = (double)textureUpdates;
        d.lastTextureUploadMs = cpuUploadMs;
        d.texturesCreated = (double)texturesCreated;
        d.texturesDrawn = (double)texturesDrawn;
        d.lastShapeRect = {lastShape.rect[0], lastShape.rect[1], lastShape.rect[2], lastShape.rect[3]};
        d.lastShapeColor = {lastShape.color[0], lastShape.color[1], lastShape.color[2], lastShape.color[3]};
        d.lastShapeKind = (double)lastShape.kind;
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
        auto r4 = [](CGRect r) -> pm::Rect4 { return {r.origin.x, r.origin.y, r.size.width, r.size.height}; };
        d.windowFrame = r4(winFrame);
        d.viewBounds = r4(viewB);
        d.layerFrame = r4(layerF);
        d.screenFrame = r4(scrFrame);
        d.screenVisibleFrame = r4(scrVisible);
        d.screenSafeAreaInsets = {insets.top, insets.left, insets.bottom, insets.right};
        d.cgDisplayBounds = r4(cgb);
        d.backingScaleFactor = backingScale;
        d.inFlight = (double)snapshotInFlight;
        d.requestedDrawableCount = (double)snapshotRequestedDrawables;
        d.drawableCountReadback = (double)snapshotDrawableReadback;
        d.hostBundleIdentifier = hostIdentifier.UTF8String ? hostIdentifier.UTF8String : "";
        d.activationPolicyBefore = (double)activationPolicyBefore;
        d.activationPolicyAfter = (double)activationPolicyAfter;
        d.activationPolicyPromotionAttempted = activationPolicyPromotionAttempted;
        d.activationPolicyPromotionSucceeded = activationPolicyPromotionSucceeded;
        const char *osv = processInfo.operatingSystemVersionString.UTF8String;
        const char *pname = processInfo.processName.UTF8String;
        d.macOSVersion = osv ? osv : "";
        d.processName = pname ? pname : "";
        d.machTimebaseHz = machHz;
        d.machTickNanoseconds = machTickNs;
        d.waitForConfirm = directWaitForConfirm;
        d.displaySyncEnabled = displaySync;
        d.pipelineEstimateMs = pipelineEstimate.value > 0 ? pipelineEstimate.value * 1000.0 : NAN;
        d.gpuEstimateMs = gpuEstimate.value > 0 ? gpuEstimate.value * 1000.0 : NAN;
        d.leadEstimateMs = leadEstimate.value > 0 ? leadEstimate.value * 1000.0 : NAN;
        d.measuredRefreshHz = measuredIFI > 0 ? 1.0 / measuredIFI : NAN;
        d.gridSamples = (double)gridSamples;
        d.directNoDrawable = (double)directNoDrawableCount;
        d.directConfirmTimeouts = (double)directTimeoutCount;
        return report;
    }
}
