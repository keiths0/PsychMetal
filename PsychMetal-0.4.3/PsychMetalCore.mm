// PsychMetalCore 0.4.3 — direct Metal presentation. No OpenGL.
// SPDX-License-Identifier: MIT
#include "mex.h"
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
#include <stdexcept>

#define NREC 16384
#define LAGWIN 64
typedef struct {
    uint64_t token;
    int status, done, gpuDone, scheduled, commandStatus, inFlight;
    double projected, scheduledAt, presented, callback;
    double committedAt;
    double drawableAcquireMs, encodeMs, prefetchMs, pacingMs;
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

static inline uint32_t pmHash(uint32_t v) {
    uint32_t s = v * 747796405u + 2891336453u;
    uint32_t w = ((s >> ((s >> 28) + 4)) ^ s) * 277803737u;
    return (w >> 22) ^ w;
}
static inline float pmUnit(uint32_t k) {
    return (float)k * 2.3283064365386963e-10f;   // [0, 1)
}
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
static PMTextureRef drawTextures[PM_MAX_SHAPES];
static uint64_t textureHandles[PM_MAX_TEXTURES], nextTextureHandle=1;
static constexpr uint64_t PM_MAX_ID=9007199254740991ULL;
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
static int timingPolicy=0; // experimental: 0 baseline, 1 bounded submissions, 2 bounded + settled startup
static int inFlightCount;
static bool asynchronousGpuFailure=false; // guarded by lock; cleared on Open
static NSUInteger requestedDrawableCount, drawableCountReadback;
static NSInteger activationPolicyBefore = -1, activationPolicyAfter = -1;
static bool activationPolicyPromotionAttempted, activationPolicyPromotionSucceeded;
static bool appPrepared;
static bool displayCaptured;
static bool captureRequested = true;
static bool directWaitForConfirm = true;
static bool displaySync = true;
static id<CAMetalDrawable> preparedDrawable;
static uint64_t preparedToken;
static double gridFirstPresented, gridLastPresented, measuredIFI;
static double lastProjected;
static int64_t gridFirstFrame, gridLastFrame;
static uint64_t gridSamples, directNoDrawableCount, directTimeoutCount;
static double leadSamples[LAGWIN], leadEstimate;
static int leadCount, leadIndex;
static double pipelineSamples[LAGWIN], pipelineEstimate;
static int pipelineCount, pipelineIndex;
static double gpuSamples[LAGWIN], gpuEstimate;
static int gpuCount, gpuIndex;
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
#include "PsychMetalKeyboardQueue.h"
static PMKeyboardQueue keyboardQueue(readKeyboardState,keyboardClock);
static bool keyboardQueueLocked=false,keyboardQueueExitRegistered=false;
static void releaseKeyboardQueue() {
    keyboardQueue.release();
    if(keyboardQueueLocked) { keyboardQueueLocked=false; mexUnlock(); }
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
static mxArray *rect4(double a, double b, double c, double d) {
    mxArray *m = mxCreateDoubleMatrix(1, 4, mxREAL);
    double *p = mxGetPr(m);
    p[0] = a; p[1] = b; p[2] = c; p[3] = d;
    return m;
}

// Draw order is preserved. Buffer slots and texture versions remain owned until GPU completion.
static void encodeShapes(id<MTLRenderCommandEncoder> re, id<MTLCommandBuffer> cb) {
    pthread_mutex_lock(&lock);
    NSUInteger n = drawCount;
    static PMDrawItem items[PM_MAX_SHAPES];
    if (n > 0)
        memcpy(items, drawList, n * sizeof(PMDrawItem));
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
        if(drawTextures[i]) resources->push_back(drawTextures[i]);
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
        PMDrawItem *it = &items[i];
        if (it->texIndex < 0 || it->texIndex >= PM_MAX_TEXTURES ||
            !drawTextures[i] || !texturePipeline)
            continue;
        struct {
            float dst[4], src[4], tint[4], size[2], angle, pad;
        } u;
        static_assert(sizeof(u)==64,"Texture uniform layout mismatch");
        memcpy(u.dst, it->dst, sizeof(u.dst));
        memcpy(u.src, it->src, sizeof(u.src));
        memcpy(u.tint, it->tint, sizeof(u.tint));
        u.size[0] = size[0];
        u.size[1] = size[1];
        u.angle = it->angle;
        u.pad = drawTextures[i]->channels==1 ? 1.0f : 0.0f;
        [re setRenderPipelineState:texturePipeline];
        [re setVertexBytes:&u length:sizeof(u) atIndex:0];
        [re setFragmentTexture:drawTextures[i]->texture atIndex:0];
        [re setFragmentSamplerState:(it->filterMode ? linearSampler : nearestSampler)
                            atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        texturesDrawn++;
    }
    for(NSUInteger i=0;i<n;i++) drawTextures[i].reset();
}

static bool encodeFrame(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d) {
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
                if (onTarget && lead > 0 && lead < 10.0 * ifi) {
                    leadSamples[leadIndex] = lead;
                    leadIndex = (leadIndex + 1) % LAGWIN;
                    if (leadCount < LAGWIN)
                        leadCount++;
                    if (leadCount >= 8)
                        leadEstimate = percentileOf(leadSamples, leadCount, 0.90);
                }
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


static char activeCommand[64];
static bool cmd(const mxArray *, const char *s) { return strcasecmp(activeCommand,s)==0; }
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
    if (!mxIsNumeric(a) || mxIsComplex(a) || mxIsSparse(a) || mxGetNumberOfElements(a) != 1) {
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
static int textureSlot(const mxArray *a) {
    uint64_t handle=unsignedScalar(a,"texture handle",PM_MAX_ID);
    for(int i=0;i<PM_MAX_TEXTURES;i++)
        if(textureHandles[i]==handle && userTextures[i]) return i;
    fail("Invalid or expired texture handle.");
}
static std::vector<__fp16> uploadScratch;
template<class T> [[clang::noinline]] static void packImageLinear(const T *src,size_t h,size_t w,size_t channels,double scale) {
    const size_t outChannels=channels==1?1:4;
    uploadScratch.resize(h*w*outChannels);
    for(size_t y=0;y<h;y++) for(size_t x=0;x<w;x++) {
        size_t dest=(y*w+x)*outChannels;
        for(size_t c=0;c<outChannels;c++) {
            double v=c<channels ? (double)src[y+x*h+c*w*h]*scale : 1;
            if(!isfinite(v)) fail("Texture pixels must be finite.");
            uploadScratch[dest+c]=(__fp16)std::max(0.0,std::min(1.0,v));
        }
    }
}
template<class T> static void packImage(const T *src,size_t h,size_t w,size_t channels,double scale) {
    const size_t outChannels=channels==1?1:4;
    uploadScratch.resize(h*w*outChannels);
    if(h*w < 2048*1024) { packImageLinear(src,h,w,channels,scale); return; }
    // Bound source/destination working sets while transposing column-major pixels.
    constexpr size_t tile=32;
    for(size_t by=0;by<h;by+=tile) for(size_t bx=0;bx<w;bx+=tile) {
        size_t endY=std::min(h,by+tile),endX=std::min(w,bx+tile);
        for(size_t y=by;y<endY;y++) for(size_t x=bx;x<endX;x++) {
            size_t dest=(y*w+x)*outChannels;
            for(size_t c=0;c<outChannels;c++) {
                double v=c<channels ? (double)src[y+x*h+c*w*h]*scale : 1;
                if(!isfinite(v)) fail("Texture pixels must be finite.");
                uploadScratch[dest+c]=(__fp16)std::max(0.0,std::min(1.0,v));
            }
        }
    }
}
static void uploadTexture(int slot,const mxArray *image) {
    double began=CACurrentMediaTime();
    if(mxIsSparse(image) || mxIsComplex(image) || mxGetNumberOfDimensions(image)>3 ||
       !(mxIsDouble(image)||mxIsSingle(image)||mxIsUint8(image)||mxIsLogical(image)))
        fail("Image must be dense real uint8, single, double, or logical HxWxC.");
    const mwSize *dims=mxGetDimensions(image);
    size_t h=dims[0],w=dims[1],c=mxGetNumberOfDimensions(image)==3?dims[2]:1;
    if(!h || !w || h>16384 || w>16384 || !(c==1 || c==3 || c==4))
        fail("Image dimensions must be 1..16384 and have 1, 3, or 4 channels.");
    if(mxIsDouble(image)) packImage((const double*)mxGetData(image),h,w,c,1);
    else if(mxIsSingle(image)) packImage((const float*)mxGetData(image),h,w,c,1);
    else if(mxIsUint8(image)) packImage((const uint8_t*)mxGetData(image),h,w,c,1.0/255);
    else packImage((const mxLogical*)mxGetData(image),h,w,c,1);
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
    for(auto &r:drawTextures) r.reset();
    pthread_mutex_lock(&lock);
    closing = true;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    pthread_mutex_lock(&lock);
    double gpuDeadline = CACurrentMediaTime() + 2.0;
    while (inFlightCount > 0)
        if (waitRelative(gpuDeadline) == ETIMEDOUT)
            break;
    bool drained=inFlightCount==0;
    ++sessionEpoch; // any late callback is obsolete before resources are reset
    pthread_mutex_unlock(&lock);
    if(!drained) mexWarnMsgIdAndTxt("PsychMetal:DrainTimeout", "Close timed out waiting for callbacks; old callbacks have been isolated.");
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
    std::vector<__fp16>().swap(uploadScratch);
    texturePipeline = nil;
    linearSampler = nil;
    nearestSampler = nil;
    for (int i = 0; i < PM_MAX_TEXTURES; i++)
        { userTextures[i].reset(); texturePools[i].clear(); textureHandles[i]=0; }
    drawCount = 0;
    texturesCreated = texturesDrawn = 0;
    heldDrawable = nil;
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
static void openCore(NSUInteger w, NSUInteger h, double period,
                     NSInteger screenIndex, double globalLeft, double globalTop, double globalRight,
                     double globalBottom, NSUInteger drawableCount,
                     bool waitConfirm, bool vsync, bool doCapture) {
    captureRequested = doCapture;
    if (!appPrepared)
        fail("PrepareApp must be called before Open.");
    if (metalWindow || device)
        fail("PsychMetal native resources are already open.");
    if(!graphicsLocked) { mexLock(); graphicsLocked=true; }
    pthread_mutex_lock(&lock); ++sessionEpoch; pthread_mutex_unlock(&lock);
    keyScanMaxMs=secureQueryMaxMs=keyScanTotalMs=secureQueryTotalMs=0;keyReadCount=0;
    startupRecords.clear();startupReady=false;
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
                @"Could not match CoreGraphics display rectangle exactly; using AppKit display index %ld.",
                (long)screenIndex];
        }
        if (!screen) {
            screen = NSScreen.mainScreen;
            selectedScreenIndex = 0;
            mappingWarning = @"Could not identify the requested display; using the main display.";
        }
        selectedDisplayID = (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        displayCaptured = captureRequested &&
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
    settleAppKit(1.0);
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
    // Let the host run loop publish the final layer geometry before the first submission.
    if(timingPolicy==2) settleAppKit(2.0*period);
    __block CGSize actualDrawableSize = CGSizeZero;
    onMainSync(^{ actualDrawableSize = layer.drawableSize; });
    if (llround(actualDrawableSize.width) != (long long)w ||
        llround(actualDrawableSize.height) != (long long)h)
        failOpen("PsychMetal:DrawableSize",
                 [NSString stringWithFormat:
                    @"Metal drawable is %.0fx%.0f but the render rectangle is %lux%lu. "
                     "Refusing to scale the stimulus.", actualDrawableSize.width,
                    actualDrawableSize.height, (unsigned long)w, (unsigned long)h]);
    ifi = period;
    renderWidth = w;
    renderHeight = h;
    NSString *source = [NSString stringWithUTF8String:PMMetalSource];
    NSError *shaderError = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&shaderError];
    if (!lib)
        failOpen("PsychMetal:Shader", [NSString stringWithFormat:@"Metal shader failed: %@",
                                       shaderError.localizedDescription]);
    MTLRenderPipelineDescriptor *sp = [MTLRenderPipelineDescriptor new];
    sp.vertexFunction = [lib newFunctionWithName:@"svmain"];
    sp.fragmentFunction = [lib newFunctionWithName:@"sfmain"];
    sp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    sp.colorAttachments[0].blendingEnabled = YES;
    sp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    sp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    sp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    sp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
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
    drawCount = 0;

    MTLRenderPipelineDescriptor *tp = [MTLRenderPipelineDescriptor new];
    tp.vertexFunction = [lib newFunctionWithName:@"tvmain"];
    tp.fragmentFunction = [lib newFunctionWithName:@"tfmain"];
    tp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    tp.colorAttachments[0].blendingEnabled = YES;
    tp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    tp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    tp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    tp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    tp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    tp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    texturePipeline = [device newRenderPipelineStateWithDescriptor:tp error:&shaderError];
    if (!texturePipeline)
        failOpen("PsychMetal:Pipeline",
                 [NSString stringWithFormat:@"Metal texture pipeline failed: %@",
                  shaderError.localizedDescription]);

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
    double pacingBegan=CACurrentMediaTime();
    if(timingPolicy>0 && displaySync) {
        // Before the first confirmation, submit one frame at a time; thereafter allow two.
        double deadline=pacingBegan+2.0;
        while(inFlightCount >= (gridSamples==0 ? 1 : 2)) {
            if(waitRelative(deadline)==ETIMEDOUT || closing || asynchronousGpuFailure) {
                pthread_mutex_unlock(&lock);
                fail("Presentation pacing failed or timed out; Close and reopen.");
            }
        }
    }
    double pacingMs=(CACurrentMediaTime()-pacingBegan)*1000;
    uint64_t t = nextToken++;
    Record *r = &rec[t % NREC];
    memset(r, 0, sizeof(*r));
    r->token = t;
    r->status = 2;
    r->pacingMs=pacingMs;
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
    if (!encodeFrame(cb, d)) {
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

static void presentNow(double *outTime, double *outCallMs) {
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
    if (outTime) *outTime = t0;
    if (outCallMs) *outCallMs = (t1 - t0) * 1000.0;
}
static uint64_t enqueue(double when, bool haveWhen) {
    if(!device || closing) fail("PsychMetal is not open.");
    if(preparedToken) fail("Present or cancel the prepared frame before Flip.");
    pthread_mutex_lock(&lock);
    return enqueueDirect(when, haveWhen);
}
// Initialization frames are confirmed separately, not returned as stimulus frames.
static mxArray *startupHistoryMatrix() {
    size_t n=startupRecords.size();
    mxArray *out=mxCreateDoubleMatrix(n,6,mxREAL);double *v=mxGetPr(out);
    for(size_t i=0;i<n;i++) {
        const Record &r=startupRecords[i];
        v[i]=r.token;v[i+n]=r.status;v[i+2*n]=r.presented;
        v[i+3*n]=r.callback;v[i+4*n]=r.gpuDone;v[i+5*n]=r.committedAt;
    }
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
    uint64_t start = std::max(firstSessionToken, (end > NREC) ? end - NREC : 1);
    mwSize count = (mwSize)(end - start);
    pthread_mutex_unlock(&lock);
    snapshot.reserve(count);
    pthread_mutex_lock(&lock);
    for (uint64_t t = start; t < end; t++) {
        Record *r = recordFor(t);
        snapshot.push_back(r ? *r : Record{});
    }
    pthread_mutex_unlock(&lock);
    mxArray *out = mxCreateDoubleMatrix(count, 17, mxREAL);
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
        v[row+count*13]=r->drawableAcquireMs;
        v[row+count*14]=r->encodeMs;
        v[row+count*15]=r->prefetchMs;
        v[row + count * 16] = r->pacingMs;
    }
    return out;
}

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    @autoreleasepool {
      try {
        if(nrhs<1 || !mxIsChar(prhs[0]) || mxGetNumberOfElements(prhs[0])>=sizeof(activeCommand) || mxGetString(prhs[0],activeCommand,sizeof(activeCommand))) fail("A short command string is required.");
        if (cmd(prhs[0],"Version")) {
            if(nrhs!=1 || nlhs!=1) fail("Version returns one string.");
            plhs[0]=mxCreateString("0.4.3"); return;
        }
        if (cmd(prhs[0], "PrepareApp")) {
            if (nrhs != 1 || nlhs != 0)
                fail("PrepareApp takes no arguments or outputs.");
            prepareApp();
            return;
        }
        if (cmd(prhs[0], "StartupHistory")) {
            if(nrhs!=1 || nlhs!=1) fail("StartupHistory returns one matrix.");
            plhs[0]=startupHistoryMatrix();return;
        }
        if (cmd(prhs[0], "ConfirmStartup")) {
            if(nrhs!=1 || nlhs!=1) fail("ConfirmStartup returns the initialization history.");
            confirmStartup();plhs[0]=startupHistoryMatrix();return;
        }
        if (cmd(prhs[0], "SettleWindow")) {
            if(nrhs!=2 || nlhs!=0 || !device || closing) fail("SettleWindow requires an open window and duration.");
            double seconds=scalar(prhs[1],"settle duration");
            if(seconds<0 || seconds>1) fail("Settle duration must be 0..1 seconds.");
            settleAppKit(seconds); return;
        }
        if (cmd(prhs[0], "TimingPolicy")) {
            if(nlhs!=1 || (nrhs!=1 && nrhs!=2)) fail("TimingPolicy returns one value and accepts optional 0, 1 or 2.");
            if(nrhs==2) {
                if(device || metalWindow) fail("Set TimingPolicy before Open.");
                timingPolicy=(int)unsignedScalar(prhs[1],"timing policy",2);
            }
            plhs[0]=mxCreateDoubleScalar(timingPolicy); return;
        }
        if (cmd(prhs[0], "Open")) {
            if ((nrhs < 3 || nrhs > 7) || nlhs != 6)
                fail("Open needs screenIndex,drawableCount[,waitForConfirm"
                     "[,displaySync[,captureDisplay]]] "
                     "and returns width,height,ifi,pointWidth,pointHeight,sessionToken.");
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

            uint32_t count = 0;
            CGDirectDisplayID ids[16];
            if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || count == 0)
                fail("No active displays.");
            if (screenIndex < 0)
                screenIndex = (double)count - 1;
            if (screenIndex >= count)
                mexErrMsgIdAndTxt("PsychMetal:Screen",
                    "Screen index %d is out of range; %u display(s) are active.",
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
            if (!(hz > 0.0) && nrhs<7) {
                mexWarnMsgIdAndTxt("PsychMetal:UnknownRefreshRate", "Display does not report a fixed refresh rate. Using provisional 60 Hz; set a fixed display mode and supply OpenWindow refreshHz for timing work.");
                hz = 60.0;
            }
            if(nrhs==7) { double overrideHz=scalar(prhs[6],"refreshHz");
                if(overrideHz<20 || overrideHz>1000) fail("refreshHz must be 20..1000.");
                hz=overrideHz; }
            double period = 1.0 / hz;
            if (!pxW || !pxH)
                fail("Could not determine the display's pixel size.");

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
            plhs[3] = mxCreateDoubleScalar(b.size.width);
            plhs[4] = mxCreateDoubleScalar(b.size.height);
            plhs[5] = mxCreateDoubleScalar((double)sessionEpoch);
            return;
        }
        if (cmd(prhs[0],"Flip")) {
            if((nrhs!=1 && nrhs!=2) || nlhs!=1) fail("Flip accepts an optional target and returns one record.");
            double began=CACurrentMediaTime();
            double target=nrhs==2?scalar(prhs[1],"target"):0;
            if(target<0) fail("Target must be nonnegative.");
            uint64_t token=enqueue(target,target>0);
            double queued=CACurrentMediaTime();
            Record r=waitScheduled(token,std::max(queued,target)+2);
            bool confirmed=r.status==0 && r.presented>0;
            plhs[0]=mxCreateDoubleMatrix(1,11,mxREAL); double *v=mxGetPr(plhs[0]);
            v[0]=confirmed?r.presented:r.projected; v[1]=0; v[2]=v[3]=0; v[4]=confirmed;
            pthread_mutex_lock(&lock); v[5]=pendingSlipRefreshes; v[6]=gridPeriod(); pthread_mutex_unlock(&lock);
            v[7]=(queued-began)*1000; v[9]=CACurrentMediaTime(); v[8]=(v[9]-began)*1000; v[10]=token;
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
            Record r = waitScheduled(unsignedScalar(prhs[1], "frame token", PM_MAX_ID), timeoutAt);
            bool confirmed = (r.status == 0 && r.presented > 0);
            plhs[0] = mxCreateDoubleMatrix(1, 7, mxREAL);
            double *v = mxGetPr(plhs[0]);
            v[0] = confirmed ? r.presented : r.projected;
            v[1] = r.scheduled ? 0 : 2;
            v[2] = 0;
            v[3] = 0;
            v[4] = confirmed ? 1 : 0;
            v[5] = pendingSlipRefreshes;
            pthread_mutex_lock(&lock); v[6]=gridPeriod(); pthread_mutex_unlock(&lock);
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
            if(!device || closing) fail("PsychMetal is not open.");
            double target = scalar(prhs[1], "target presentation time");
            double budget = scalar(prhs[2], "drawing budget");
            if (budget < 0)
                fail("Drawing budget must be nonnegative.");
            pthread_mutex_lock(&lock);
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
            prefetchDrawable=(int)unsignedScalar(prhs[1],"prefetch flag",1);
            if (!prefetchDrawable)
                heldDrawable = nil;
            return;
        }
        if (cmd(prhs[0], "NoiseValues")) {
            if (nrhs != 8 || nlhs != 1)
                fail("NoiseValues needs width,height,seed,normal,colour,mean,spread.");
            double dw = scalar(prhs[1], "width"), dh = scalar(prhs[2], "height");
            if (dw < 1 || dh < 1 || dw>16384 || dh>16384 || dw != floor(dw) || dh != floor(dh))
                fail("Noise width and height must be positive integers.");
            double dseed = scalar(prhs[3], "seed");
            if (dseed < 0 || dseed > 16777215.0 || dseed != floor(dseed))
                fail("Seed must be an integer from 0 to 16777215.");
            bool normal = scalar(prhs[4], "normal flag") != 0.0;
            bool colour = scalar(prhs[5], "colour flag") != 0.0;
            if (!mxIsDouble(prhs[6]) || mxIsComplex(prhs[6]) || mxIsSparse(prhs[6]) || mxGetNumberOfElements(prhs[6]) != 3)
                fail("Noise mean must be a 3-element RGB vector.");
            const double *mean = mxGetPr(prhs[6]);
            double spread = scalar(prhs[7], "spread");
            if(spread<0 || !isfinite(mean[0]) || !isfinite(mean[1]) || !isfinite(mean[2])) fail("Invalid noise mean/spread.");
            size_t W = (size_t)dw, H = (size_t)dh;
            uint32_t seed = (uint32_t)dseed;
            mwSize dims[3] = {(mwSize)H, (mwSize)W, 3};
            plhs[0] = mxCreateNumericArray(colour ? 3 : 2, dims, mxDOUBLE_CLASS, mxREAL);
            double *out = mxGetPr(plhs[0]);
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
            if (nrhs != 2 || nlhs != 1)
                fail("Modes needs a screen index and returns one matrix.");
            uint32_t count = 0;
            CGDirectDisplayID ids[16];
            if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || count == 0)
                fail("No active displays.");
            double si = scalar(prhs[1], "screen index");
            if (si < 0) si = (double)count - 1;
            if (si != floor(si) || si >= count)
                fail("Screen index is out of range.");
            CGDirectDisplayID did = ids[(uint32_t)si];

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
            if (si != floor(si) || si >= count)
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
            if (nrhs != 1 || nlhs != 3)
                fail("Mouse takes no arguments and returns x, y and buttons.");
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
            plhs[0] = mxCreateDoubleScalar((p.x - b.origin.x) * sx);
            plhs[1] = mxCreateDoubleScalar((p.y - b.origin.y) * sy);
            mxArray *btn = mxCreateLogicalMatrix(1, 3);
            mxLogical *bv = mxGetLogicals(btn);
            const CGMouseButton buttonIDs[3] = {
                kCGMouseButtonLeft, kCGMouseButtonRight, kCGMouseButtonCenter
            };
            for (int i = 0; i < 3; i++)
                bv[i] = CGEventSourceButtonState(
                    kCGEventSourceStateCombinedSessionState, buttonIDs[i]);
            plhs[2] = btn;
            return;
        }
        if (cmd(prhs[0],"KbQueueStatus")) {
            if(nrhs!=1 || nlhs!=1) fail("KbQueueStatus returns one structure.");
            auto state=keyboardQueue.stats();
            const char *fields[]={"created","running","pollInterval","lastScanInterval","maxScanInterval","scans","dropped","secureInputPID"};
            plhs[0]=mxCreateStructMatrix(1,1,8,fields);
            double pid=0; CFDictionaryRef sess=CGSessionCopyCurrentDictionary();
            if(sess) { CFTypeRef value=CFDictionaryGetValue(sess,CFSTR("kCGSSessionSecureInputPID"));
                if(value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value,kCFNumberDoubleType,&pid);
                CFRelease(sess); }
            double values[]={double(state.created),double(state.running),state.interval,state.lastScanInterval,state.maxScanInterval,double(state.scans),double(state.dropped),pid};
            for(int i=0;i<8;i++) mxSetField(plhs[0],0,fields[i],mxCreateDoubleScalar(values[i]));
            return;
        }
        if (cmd(prhs[0], "KbQueueCreate")) {
            if(nrhs!=3 || nlhs!=0 || !mxIsDouble(prhs[1]) || mxIsComplex(prhs[1]) || mxIsSparse(prhs[1]) || mxGetNumberOfElements(prhs[1])!=256)
                fail("KbQueueCreate requires a 256-element mask and poll interval, no outputs.");
            const double *m=mxGetPr(prhs[1]); bool filter[256];
            for(int k=0;k<256;k++) { if(!isfinite(m[k])) fail("Key mask must be finite."); filter[k]=(m[k]!=0); }
            double interval=scalar(prhs[2],"poll interval");
            if(interval<.001 || interval>.1) fail("Poll interval must be between .001 and .1 seconds.");
            keyboardQueue.create(filter,interval);
            if(!keyboardQueueExitRegistered) { mexAtExit(releaseKeyboardQueue); keyboardQueueExitRegistered=true; }
            if(!keyboardQueueLocked) { mexLock(); keyboardQueueLocked=true; }
            return;
        }
        if (cmd(prhs[0], "KbQueueRelease")) {
            if(nrhs!=1 || nlhs!=0) fail("KbQueueRelease takes no arguments or outputs.");
            releaseKeyboardQueue(); return;
        }
        if (cmd(prhs[0], "KbQueueStart") || cmd(prhs[0], "KbQueueStop") || cmd(prhs[0], "KbQueueFlush")) {
            if(nrhs!=1 || nlhs!=0) fail("Queue Start/Stop/Flush take no arguments or outputs.");
            if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
            if (cmd(prhs[0], "KbQueueStart")) {
                uint32_t displayCount=0;
                if(CGGetActiveDisplayList(0,nullptr,&displayCount)!=kCGErrorSuccess || !displayCount)
                    fail("No active desktop session for keyboard polling.");
                if(!keyboardQueue.start()) fail("Cannot start keyboard queue worker.");
            } else if (cmd(prhs[0], "KbQueueStop")) keyboardQueue.stop();
            else keyboardQueue.flush();
            return;
        }
        if (cmd(prhs[0], "KbQueueGetEvents")) {
            if(nrhs!=1 || nlhs!=2) fail("KbQueueGetEvents returns events and dropped count.");
            if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
            unsigned long long dropped=0; auto events=keyboardQueue.events(dropped);
            plhs[0]=mxCreateDoubleMatrix(events.size(),3,mxREAL); double *out=mxGetPr(plhs[0]);
            for(size_t i=0;i<events.size();i++) {
                out[i]=events[i].time; out[i+events.size()]=events[i].key;
                out[i+2*events.size()]=events[i].pressed?1:0;
            }
            plhs[1]=mxCreateDoubleScalar((double)dropped); return;
        }
        if (cmd(prhs[0], "KbQueueCheck")) {
            if(nrhs!=1 || nlhs!=5) fail("KbQueueCheck returns pressed and four timestamp vectors.");
            if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
            double summary[4][256]; keyboardQueue.check(summary); bool pressed=false;
            for(int k=0;k<256;k++) if(summary[0][k]!=0) pressed=true;
            plhs[0]=mxCreateLogicalScalar(pressed);
            for(int j=0;j<4;j++) { plhs[j+1]=mxCreateDoubleMatrix(1,256,mxREAL); memcpy(mxGetPr(plhs[j+1]),summary[j],sizeof(summary[j])); }
            return;
        }
        if (cmd(prhs[0], "Keys")) {
            if (nrhs != 1 || nlhs != 4)
                fail("Keys takes no arguments and returns four values.");

            mxArray *kc = mxCreateLogicalMatrix(1, 256);
            mxLogical *kv = mxGetLogicals(kc);
            double scanStart=CACurrentMediaTime();
            bool state[256]; readKeyboardState(state,nullptr);
            double scanMs=(CACurrentMediaTime()-scanStart)*1000;
            for(int k=0;k<256;k++) kv[k]=state[k];
            bool anyDown = false;
            for (int u = 0; u < 256; u++)
                if (kv[u]) { anyDown = true; break; }

            double secs = CACurrentMediaTime();

            double secureBegan=CACurrentMediaTime();
            // The owner dictionary is diagnostic-only: it can take an entire refresh.
            // Serialize this non-thread-safe API; never call it from the keyboard worker.
            // Do not dispatch to the GUI thread: CLI hosts may not pump its run loop.
            bool secureActive=false;
            { std::lock_guard<std::mutex> guard(secureInputStateLock);
              secureActive=IsSecureEventInputEnabled()!=0; }
            double securePid=secureActive ? -1.0 : 0.0; // -1 means active, owner not queried

            double secureMs=(CACurrentMediaTime()-secureBegan)*1000;
            keyScanMaxMs=std::max(keyScanMaxMs,scanMs);secureQueryMaxMs=std::max(secureQueryMaxMs,secureMs);
            keyScanTotalMs+=scanMs;secureQueryTotalMs+=secureMs;++keyReadCount;
            plhs[0] = mxCreateLogicalScalar(anyDown);
            plhs[1] = mxCreateDoubleScalar(secs);
            plhs[2] = kc;
            plhs[3] = mxCreateDoubleScalar(securePid);
            return;
        }
        if (cmd(prhs[0], "SetBackgroundColor")) {
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
            if (nrhs != 6 || nlhs != 0)
                fail("AddShapes needs kind, param, rect, color and extra arrays.");
            if (!device)
                fail("PsychMetal is not open.");
            for (int a = 1; a <= 5; a++)
                if (!mxIsDouble(prhs[a]) || mxIsComplex(prhs[a]) || mxIsSparse(prhs[a]))
                    fail("AddShapes arguments must be real double arrays.");
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
            if(n>PM_MAX_SHAPES-drawCount) fail("Frame draw capacity exceeded; split the work across frames.");
            for(size_t k=0;k<n;k++) {
                if(!isfinite(kind[k]) || kind[k]!=floor(kind[k]) || kind[k]<0 || kind[k]>7) fail("Invalid shape kind.");
                if(!isfinite(param[k]) || fabs(param[k])>FLT_MAX || param[k]<0) fail("Invalid shape parameter.");
                for(int c=0;c<4;c++) {
                    if(!isfinite(rect[4*k+c]) || fabs(rect[4*k+c])>FLT_MAX ||
                       !isfinite(color[4*k+c]) || color[4*k+c]<0 || color[4*k+c]>1 ||
                       !isfinite(extra[4*k+c]) || fabs(extra[4*k+c])>FLT_MAX)
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
            if(nrhs!=2 || nlhs!=1) fail("MakeTexture takes a dense image and returns a handle.");
            if(!device || closing) fail("PsychMetal is not open.");
            int slot=-1;
            for(int i=0;i<PM_MAX_TEXTURES;i++) if(!userTextures[i]) { slot=i; break; }
            if(slot<0) fail("No free texture slots.");
            if(nextTextureHandle>=PM_MAX_ID) fail("Texture handle space exhausted.");
            uploadTexture(slot,prhs[1]);
            textureHandles[slot]=nextTextureHandle++;
            texturesCreated++;
            plhs[0]=mxCreateDoubleScalar((double)textureHandles[slot]); return;
        }
        if (cmd(prhs[0], "UpdateTexture")) {
            if(nrhs!=3 || nlhs!=0) fail("UpdateTexture takes a texture handle and image.");
            if(!device || closing) fail("PsychMetal is not open.");
            int slot=textureSlot(prhs[1]); uploadTexture(slot,prhs[2]); textureUpdates++; return;
        }
        if (cmd(prhs[0], "DrawTexture")) {
            if (nrhs != 7 || nlhs != 0)
                fail("DrawTexture needs handle, srcRect, dstRect, angle, tint and filterMode.");
            if (!device)
                fail("PsychMetal is not open.");
            int slot = textureSlot(prhs[1]);
            if (slot < 0 || slot >= PM_MAX_TEXTURES || !userTextures[slot])
                fail("Invalid texture handle.");
            for (int a = 2; a <= 5; a++)
                if (!mxIsDouble(prhs[a]) || mxIsComplex(prhs[a]) || mxIsSparse(prhs[a]))
                    fail("DrawTexture rectangles and tint must be real doubles.");
            if (mxGetNumberOfElements(prhs[2]) != 4 ||
                mxGetNumberOfElements(prhs[3]) != 4 ||
                mxGetNumberOfElements(prhs[5]) != 4)
                fail("srcRect, dstRect and tint must each have four elements.");
            const double *sr = mxGetPr(prhs[2]);
            const double *dr = mxGetPr(prhs[3]);
            const double *ti = mxGetPr(prhs[5]);
            double angle=scalar(prhs[4],"rotation angle");
            int filter=(int)unsignedScalar(prhs[6],"filter mode",1);
            for(int c=0;c<4;c++) if(!isfinite(sr[c]) || !isfinite(dr[c]) || !isfinite(ti[c]) ||
                fabs(sr[c])>FLT_MAX || fabs(dr[c])>FLT_MAX || ti[c]<0 || ti[c]>1) fail("Invalid texture rectangle or tint.");
            if(fabs(angle)>FLT_MAX) fail("Rotation angle out of range.");
            if(drawCount>=PM_MAX_SHAPES) fail("Frame draw capacity exceeded.");
            drawTextures[drawCount]=userTextures[slot];
            pthread_mutex_lock(&lock);
            PMDrawItem *item = &drawList[drawCount++];
            memset(item, 0, sizeof(*item));
            item->type = PM_ITEM_TEXTURE;
            item->texIndex = slot;
            for (int c = 0; c < 4; c++) {
                item->src[c] = (float)sr[c];
                item->dst[c] = (float)dr[c];
                item->tint[c] = (float)ti[c];
            }
            item->angle = (float)angle;
            item->filterMode = filter;
            pthread_mutex_unlock(&lock);
            return;
        }
        if (cmd(prhs[0], "CloseTexture")) {
            if (nrhs != 2 || nlhs != 0)
                fail("CloseTexture needs a texture handle.");
            int slot = textureSlot(prhs[1]);
            userTextures[slot].reset(); texturePools[slot].clear(); textureHandles[slot]=0;
            return;
        }
        if (cmd(prhs[0], "Wait")) {
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
                "modePointWidth",          "modePixelWidth",         "largestModePixelWidth",
                "shapesAppended",          "shapesEncoded",          "shapeEncodeCalls",
                "texturesCreated",         "texturesDrawn", "textureAllocations", "textureUpdates", "lastTextureUploadMs",
                "lastShapeRect",           "lastShapeColor",         "lastShapeKind",
                "windowFrame",             "viewBounds",             "layerFrame",
                "screenFrame",             "screenVisibleFrame",     "screenSafeAreaInsets",
                "cgDisplayBounds",         "backingScaleFactor", "timingPolicy", "keyScanMaxMs", "secureQueryMaxMs", "keyScanMeanMs", "secureQueryMeanMs", "keyReadCount"};
            plhs[1] = mxCreateStructMatrix(1, 1,
                                           (int)(sizeof(n) / sizeof(n[0])), n);
            mxSetField(plhs[1],0,"timingPolicy",mxCreateDoubleScalar(timingPolicy));
            mxSetField(plhs[1],0,"keyScanMaxMs",mxCreateDoubleScalar(keyScanMaxMs));
            mxSetField(plhs[1],0,"secureQueryMaxMs",mxCreateDoubleScalar(secureQueryMaxMs));
            mxSetField(plhs[1],0,"keyScanMeanMs",mxCreateDoubleScalar(keyReadCount?keyScanTotalMs/keyReadCount:0));
            mxSetField(plhs[1],0,"secureQueryMeanMs",mxCreateDoubleScalar(keyReadCount?secureQueryTotalMs/keyReadCount:0));
            mxSetField(plhs[1],0,"keyReadCount",mxCreateDoubleScalar(keyReadCount));
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
            mxSetField(plhs[1], 0, "largestModePixelWidth", mxCreateDoubleScalar(nativePixelWidth));
            mxSetField(plhs[1], 0, "shapesAppended", mxCreateDoubleScalar((double)shapesAppended));
            mxSetField(plhs[1], 0, "shapesEncoded", mxCreateDoubleScalar((double)shapesEncoded));
            mxSetField(plhs[1], 0, "shapeEncodeCalls",
                       mxCreateDoubleScalar((double)shapeEncodeCalls));
            mxSetField(plhs[1],0,"textureAllocations",mxCreateDoubleScalar(textureAllocations));
            mxSetField(plhs[1],0,"textureUpdates",mxCreateDoubleScalar(textureUpdates));
            mxSetField(plhs[1],0,"lastTextureUploadMs",mxCreateDoubleScalar(cpuUploadMs));
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
      } catch(const std::exception &e) { mexErrMsgIdAndTxt("PsychMetal:NativeException","%s",e.what()); }
    }
}
