// PsychMetalEngine 0.8.0 — direct Metal presentation. No OpenGL.
// SPDX-License-Identifier: MIT
//
// The host-neutral engine behind PsychMetalEngine.h: presentation, timing,
// textures and input. Errors throw pm::Error, warnings and module pinning go
// through pm::HostHooks, images are read through strided views, and the pm::
// functions at the end of this file are the boundary. Front ends:
// PsychMetalMex.cpp (MATLAB, Octave) and PsychMetalPython.cpp (Python).
//
// One engine for the Mac and for the iPhone and iPad. Drawing, textures,
// presentation and timing are the same code on both. What differs is the window,
// the display and input: the Mac's are in this file, between #if !PM_IOS and
// #endif, and the iPhone's are in PsychMetalIOS.h, which is a part of this file,
// included once near its end.
#include "PsychMetalEngine.h"
#include "PsychMetalInternal.h"
#include "PsychMetalReadback.h"
#include "PsychMetalTimeline.h"
#include "PsychMetalLiveTimeline.h"
#include "PsychMetalKeyframes.h"
#include "PsychMetalShaders.h"
#include "PsychMetalCustomShader.h"
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#define PM_IOS 1
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#else
#define PM_IOS 0
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <IOKit/IOKitLib.h>
#endif
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <CoreText/CoreText.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <unistd.h>
#include <vector>
#include <memory>
#include <mutex>
#include <algorithm>
#include <float.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdexcept>
#include <atomic>
#include <deque>
#include <map>
#include <string>

#include "PsychMetalDisplayLink.h"

#define NREC 16384
#define LAGWIN 64
typedef struct {
    uint64_t token;
    int status, done, gpuDone, commandStatus, inFlight;
    double projected, scheduledAt, presented, callback;
    double committedAt;
    double drawableAcquireMs, encodeMs, prefetchMs;
    double requestedTime, gpuStart, gpuEnd, presentRequest, presentCallMs;
    int pipelineNoted;
    int renderDone;     // a queued frame: its store has been rendered
    int queued;         // made by QueueFlip: its pixels are ready at renderDone
} Record;
static std::vector<Record> startupRecords;
static bool startupReady=false;
#if PM_IOS
static UIWindow *metalWindow;
#else
static NSWindow *metalWindow;
#endif
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
// Pipelines by what they draw into and how they blend. PM_TARGET_FLOAT is the
// linearization target and PM_TARGET_OFFSCREEN an offscreen window: both are
// RGBA16Float, but an offscreen window holds colour multiplied by its alpha
// (pm::internal::blendFor). Texture pipelines are also by what they draw: [0] an
// image or a mask, [1] an offscreen window.
enum { PM_TARGET_DRAWABLE = 0, PM_TARGET_FLOAT = 1, PM_TARGET_OFFSCREEN = 2, PM_TARGET_COUNT = 3 };
enum { PM_BLEND_ALPHA = 0, PM_BLEND_ADD = 1, PM_BLEND_COPY = 2, PM_BLEND_COUNT = 3 };
static id<MTLRenderPipelineState> shapePipelines[PM_TARGET_COUNT][PM_BLEND_COUNT];
static id<MTLRenderPipelineState> texturePipelines[PM_TARGET_COUNT][PM_BLEND_COUNT][2];
static id<MTLLibrary> shaderLibrary;
static MTLPixelFormat drawableFormat = MTLPixelFormatBGRA8Unorm;
static int outputBits = 8;               // bits per channel of the drawable
static uint32_t blendMode;               // of draws queued from now on
static int32_t clipRect[4];              // [left top right bottom] of draws queued from now on; all zero: none
// Linearization: draws go to linearTarget, and encodePipeline writes the drawable.
enum { PM_ENCODE_NONE = 0, PM_ENCODE_POWER = 1, PM_ENCODE_TABLE = 2 };
static int encodeMode;
static float encodeExponent[3] = {1, 1, 1};
static id<MTLRenderPipelineState> encodePipeline;
static id<MTLTexture> linearTarget, encodeTable;
static NSUInteger encodeTableSize;
static id<MTLBuffer> shapeBuffers[PM_SHAPE_RING];
static int shapeBufferIndex;
#define PM_MAX_TEXTURES 256
enum { PM_ITEM_SHAPE = 0, PM_ITEM_TEXTURE = 1, PM_ITEM_STIMULUS = 2, PM_ITEM_MASKED_TEXTURE = 3, PM_ITEM_CUSTOM = 4 };
struct PMStimulusUniform { float dst[4], mean[4], wave[4], noise[4], aperture[4], viewport[4], maskA[4], maskB[4]; };
static_assert(sizeof(PMStimulusUniform)==128,"Stimulus uniform layout mismatch");
static id<MTLRenderPipelineState> stimulusPipelines[PM_TARGET_COUNT][PM_BLEND_COUNT];
static id<MTLRenderPipelineState> maskedTexturePipelines[PM_TARGET_COUNT][PM_BLEND_COUNT][2];
static id<MTLTexture> stimulusWhite;
typedef struct {
    uint32_t type;
    PMStimulusUniform stimulus; // PM_ITEM_STIMULUS, snapshotted per draw
    PMShape shape;          // PM_ITEM_SHAPE
    int32_t texIndex;       // PM_ITEM_TEXTURE
    float src[4];           // normalised source rect
    float dst[4];           // destination rect in pixels
    float tint[4];          // multiplied into the sampled colour
    float angle;            // radians, about the destination centre
    int32_t filterMode;     // 0 nearest, 1 bilinear, as Screen('DrawTexture')
    uint32_t blend;         // PM_BLEND_*, as set when the item was queued
    int32_t mask;           // PM_ITEM_TEXTURE: the texture is an alpha mask for the tint (text, polygons)
    int32_t clip[4];        // clipRect when the item was queued
} PMDrawItem;
static PMDrawItem drawList[PM_MAX_SHAPES];
static NSUInteger drawCount;
struct PMTextureResource {
    id<MTLTexture> texture;
    size_t width, height, channels;
    bool bytes;             // 8-bit normalised storage (uint8, logical images); else half float
    bool offscreen = false; // an offscreen window: a render target, never uploaded to, holding colour x alpha
};
using PMTextureRef = std::shared_ptr<PMTextureResource>;
static PMTextureRef userTextures[PM_MAX_TEXTURES];
static std::vector<PMTextureRef> texturePools[PM_MAX_TEXTURES];
static PMTextureRef drawTextureRefs[PM_MAX_SHAPES];
static PMTextureRef drawCoverageRefs[PM_MAX_SHAPES];
struct PMShaderResource {id<MTLLibrary> library;id<MTLRenderPipelineState> pipelines[PM_TARGET_COUNT][PM_BLEND_COUNT];};
using PMShaderRef=std::shared_ptr<PMShaderResource>;
static std::map<uint64_t,PMShaderRef> userShaders;
static std::map<std::string,std::weak_ptr<PMShaderResource>> shaderCache;
static PMShaderRef drawShaderRefs[PM_MAX_SHAPES];
static uint64_t nextShaderHandle=1;
// Coverage masks rendered on the CPU and kept: lines of text by font, size and
// string, and polygons by their points. ascent is for text.
struct PMMask { PMTextureRef mask; double width, height, ascent; uint64_t used; };
static std::map<std::string, PMMask> maskCache;
static size_t maskCacheBytes;
static uint64_t maskUses;          // counts uses: a mask's `used` is when it was last wanted
static PMMask unkeptMask;          // a mask too large to keep, alive until the next one
// The offscreen window that drawing goes into, or none: the window. Only the
// current target has draws waiting: they are the draw-list items from targetBase
// on, and they are rendered into it when the target changes or a frame is made.
static PMTextureRef targetTexture;
static uint64_t targetHandle;
static NSUInteger targetBase;
static uint64_t textureHandles[PM_MAX_TEXTURES], nextTextureHandle=1;
static constexpr uint64_t PM_MAX_ID=pm::kMaxId;
static uint64_t firstSessionToken=1;
static uint64_t sessionEpoch=0, lastSlipToken=0, lastConfirmedToken=0;
static bool graphicsLocked=false;
static bool shapeBufferBusy[PM_SHAPE_RING]={};
static double cpuUploadMs=0;
static uint64_t textureAllocations=0,textureUpdates=0;

static id<MTLSamplerState> linearSampler, nearestSampler;
static uint64_t texturesCreated, texturesDrawn;

static uint64_t shapesAppended, shapesEncoded, shapeEncodeCalls;
static PMShape lastShape;
static bool haveLastShape;
static double ifi, lastTargetErrorMs, lastConfirmDelayMs;
static NSUInteger renderWidth, renderHeight;
static uint64_t nextToken=1, confirmedCount, missingPresentedCount;
static uint64_t lastFlipToken;     // the last frame of Flip; the caller's thread only
static NSInteger selectedScreenIndex = -1;
#if !PM_IOS
static CGDirectDisplayID selectedDisplayID = 0;
#endif
static Record rec[NREC];
static bool closing = true;
static std::atomic<bool> timelineCancellation{false};
static pm::timeline::LiveState liveTimeline;
#if !PM_IOS
static std::mutex secureInputStateLock;
#endif
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
static id<MTLBuffer> captureBuffer;
static size_t capturePitch;
static uint64_t captureToken;

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
// Frames queued ahead. Each is rendered when it is queued, into a store with the
// drawable's format, and the presenter thread hands it to the display near its
// time. Everything here is guarded by lock.
struct PMQueuedFrame { uint64_t token; double when; id<MTLTexture> store; };
static std::deque<PMQueuedFrame> frameQueue;        // waiting for the presenter, in order of time
static std::vector<id<MTLTexture>> frameStores;     // idle stores
static NSUInteger frameStoreCount, frameStoreLimit; // stores made this session; the most there may be
static std::vector<uint64_t> queuedTokens;          // frames not yet reported by QueueResults
static pthread_t presenterThread;
static bool presenterRunning, presenterStop, presenterBusy;
static uint64_t lastHandedToken;                    // the newest frame the presenter has handed to the display
#define PM_QUEUE_LEAD 3.0                           // refreshes before its time that a frame is submitted
#define PM_QUEUE_LOST 10.0                          // seconds after its time that a frame's report is given up on
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
#if PM_IOS
// The iPhone's side of the engine, defined in PsychMetalIOS.h.
static void readKeyboardState(bool *kv, const bool *filter);
static void startKeyTap(void);
static void stopKeyTap(void);
static void stopMouseTap(void);
static void iosOpenWindow(NSUInteger w, NSUInteger h, double hz, NSUInteger drawableCount, bool readable, bool linked);
static void iosCloseWindow(void);
static void iosRequireFront(void);
#else
// Virtual key code to HID usage; 0 where there is none.
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
static void readKeyboardState(bool *kv,const bool *filter) {
    memset(kv,0,256*sizeof(bool));

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
#endif
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

// Fingers' contacts, kept until TouchEvents takes them: the touch screen's on an
// iPhone, the trackpad's on a Mac. Whoever fills it guards it.
#define PM_TOUCH_EVENTS 8192
#define PM_FINGERS 16
struct PMTouchRing {
    pm::TouchEvent events[PM_TOUCH_EVENTS];
    unsigned head = 0, count = 0;
    uint64_t dropped = 0;
    void push(const pm::TouchEvent &e) {
        if (count == PM_TOUCH_EVENTS) { head = (head + 1) % PM_TOUCH_EVENTS; count--; dropped++; }
        events[(head + count++) % PM_TOUCH_EVENTS] = e;
    }
    pm::TouchEvents take() {
        pm::TouchEvents out{};
        out.events.reserve(count);
        for (unsigned i = 0; i < count; i++) out.events.push_back(events[(head + i) % PM_TOUCH_EVENTS]);
        out.dropped = dropped;
        clear();
        return out;
    }
    void clear() { head = count = 0; dropped = 0; }
};
static PMTouchRing touchRing;
#if !PM_IOS
// --- input events ---------------------------------------------------------------
//
// Listen-only event taps on a thread of their own, so key and mouse-button events
// arrive with the time the system stamped them when they entered it, however busy
// the caller is. The key tap feeds the keyboard queue; the mouse tap fills a
// buffer of its own. A tap for key events needs the host application to be allowed
// Input Monitoring; without it the keyboard queue polls, as it always has.
static std::mutex tapLock;                  // the taps, the thread and the mouse buffer
static pthread_t tapThread;
static bool tapThreadRunning;
static std::atomic<bool> tapThreadStop;
static CFRunLoopRef tapRunLoop;
static CFMachPortRef keyTap, mouseTap;
static CFRunLoopSourceRef keyTapSource, mouseTapSource;
static bool inputMonitoringWarned, inputMonitoringRequested;
#define PM_MOUSE_EVENTS 4096
static pm::MouseEvent mouseEventBuffer[PM_MOUSE_EVENTS];
static unsigned mouseEventHead, mouseEventCount;
static uint64_t mouseEventsDropped;
static double mouseOriginX, mouseOriginY, mouseScaleX, mouseScaleY;   // display points to window pixels

// An event's own time on the engine clock, or NaN. The timestamp is documented as
// nanoseconds since startup. Systems have differed in its unit (nanoseconds or
// clock ticks) and may differ in its clock (the one that stops while the machine
// sleeps, which is the engine's, or the one that does not). The readings differ
// by the timebase and by the time spent asleep, so whichever lies within the five
// seconds before `now` is the one in use.
static double eventTime(CGEventRef event, double now) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    const double tick = (double)timebase.numer / (double)timebase.denom * 1e-9;
    double raw = (double)CGEventGetTimestamp(event);
    double asleep = ((double)mach_continuous_time() - (double)mach_absolute_time()) * tick;
    const double candidates[4] = {raw * 1e-9, raw * tick, raw * 1e-9 - asleep, raw * tick - asleep};
    for (double t : candidates)
        if (now - t > -0.005 && now - t < 5.0) return t;
    return NAN;
}

static CGEventRef keyTapCallback(CGEventTapProxy, CGEventType type, CGEventRef event, void *) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        std::lock_guard<std::mutex> guard(tapLock);
        if (keyTap) CGEventTapEnable(keyTap, true);
        return event;
    }
    double now = CACurrentMediaTime();
    double stamp = eventTime(event, now);
    if (!isfinite(stamp)) stamp = now;
    int64_t vk = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    int usage = (vk >= 0 && vk < 128) ? vkToUsage[vk] : 0;
    bool pressed = false;
    if (type == kCGEventKeyDown) {
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0) return event;
        pressed = true;
    } else if (type == kCGEventKeyUp) {
        pressed = false;
    } else if (type == kCGEventFlagsChanged) {
        // A modifier: which way it went is in the device-dependent flag bits.
        // Caps Lock and anything else are left to polling.
        static const struct { int usage; uint64_t bit; } modifiers[8] = {
            {225, 0x00000002}, {229, 0x00000004}, {224, 0x00000001}, {228, 0x00002000},
            {226, 0x00000020}, {230, 0x00000040}, {227, 0x00000008}, {231, 0x00000010}};
        uint64_t flags = (uint64_t)CGEventGetFlags(event);
        bool known = false;
        for (const auto &m : modifiers)
            if (m.usage == usage) { pressed = (flags & m.bit) != 0; known = true; }
        if (!known) return event;
    } else {
        return event;
    }
    if (usage) keyboardQueue.post(stamp, usage, pressed, now - stamp);
    return event;
}

static CGEventRef mouseTapCallback(CGEventTapProxy, CGEventType type, CGEventRef event, void *) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        std::lock_guard<std::mutex> guard(tapLock);
        if (mouseTap) CGEventTapEnable(mouseTap, true);
        return event;
    }
    int button;
    bool pressed;
    switch (type) {
        case kCGEventLeftMouseDown:  button = 1; pressed = true;  break;
        case kCGEventLeftMouseUp:    button = 1; pressed = false; break;
        case kCGEventRightMouseDown: button = 2; pressed = true;  break;
        case kCGEventRightMouseUp:   button = 2; pressed = false; break;
        case kCGEventOtherMouseDown: button = 3; pressed = true;  break;
        case kCGEventOtherMouseUp:   button = 3; pressed = false; break;
        default: return event;
    }
    // Other buttons: only the centre one, as GetMouse reports.
    if (button == 3 && CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) != 2) return event;
    double now = CACurrentMediaTime();
    double stamp = eventTime(event, now);
    if (!isfinite(stamp)) stamp = now;
    CGPoint p = CGEventGetLocation(event);
    std::lock_guard<std::mutex> guard(tapLock);
    if (mouseEventCount == PM_MOUSE_EVENTS) {
        mouseEventHead = (mouseEventHead + 1) % PM_MOUSE_EVENTS;
        mouseEventCount--;
        mouseEventsDropped++;
    }
    mouseEventBuffer[(mouseEventHead + mouseEventCount++) % PM_MOUSE_EVENTS] =
        {stamp, button, pressed, (p.x - mouseOriginX) * mouseScaleX, (p.y - mouseOriginY) * mouseScaleY};
    return event;
}

// The thread only runs its run loop; a timer that never fires keeps the loop
// alive while no tap is attached.
static void tapIdle(CFRunLoopTimerRef, void *) {}
static void *tapThreadMain(void *) {
    pthread_setname_np("PsychMetal input");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    CFRunLoopTimerRef idle = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, tapIdle, NULL);
    if (idle) CFRunLoopAddTimer(CFRunLoopGetCurrent(), idle, kCFRunLoopCommonModes);
    {
        std::lock_guard<std::mutex> guard(tapLock);
        tapRunLoop = CFRunLoopGetCurrent();
    }
    while (!tapThreadStop.load()) {
        @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false); }
    }
    if (idle) { CFRunLoopTimerInvalidate(idle); CFRelease(idle); }
    return NULL;
}

// Create a tap and attach it to the tap thread, starting the thread if need be.
// NULL if the system refuses the tap.
static CFMachPortRef startTap(CGEventMask mask, CGEventTapCallBack callback, CFRunLoopSourceRef *source) {
    CFMachPortRef port = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                          mask, callback, NULL);
    if (!port) return NULL;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, port, 0);
    if (!src) { CFMachPortInvalidate(port); CFRelease(port); return NULL; }
    bool started = true;
    {
        std::lock_guard<std::mutex> guard(tapLock);
        if (!tapThreadRunning) {
            tapThreadStop.store(false);
            tapRunLoop = NULL;
            started = pthread_create(&tapThread, NULL, tapThreadMain, NULL) == 0;
            tapThreadRunning = started;
        }
    }
    // The thread publishes its run loop as it starts.
    CFRunLoopRef loop = NULL;
    for (int i = 0; started && i < 2000 && !loop; i++) {
        { std::lock_guard<std::mutex> guard(tapLock); loop = tapRunLoop; }
        if (!loop) usleep(500);
    }
    if (!loop) { CFRelease(src); CFMachPortInvalidate(port); CFRelease(port); return NULL; }
    CFRunLoopAddSource(loop, src, kCFRunLoopCommonModes);
    CGEventTapEnable(port, true);
    CFRunLoopWakeUp(loop);
    *source = src;
    return port;
}

// Detach and release one tap; with none left, stop the thread.
static void stopTap(CFMachPortRef *port, CFRunLoopSourceRef *source) {
    CFMachPortRef p = NULL;
    CFRunLoopSourceRef src = NULL;
    CFRunLoopRef loop = NULL;
    bool last = false;
    {
        std::lock_guard<std::mutex> guard(tapLock);
        p = *port; src = *source; *port = NULL; *source = NULL;
        loop = tapRunLoop;
        last = tapThreadRunning && !keyTap && !mouseTap;
    }
    if (p) {
        CGEventTapEnable(p, false);
        if (loop && src) CFRunLoopRemoveSource(loop, src, kCFRunLoopCommonModes);
        CFMachPortInvalidate(p);
        if (src) CFRelease(src);
        CFRelease(p);
    }
    if (last) {
        tapThreadStop.store(true);
        if (loop) CFRunLoopStop(loop);
        pthread_join(tapThread, NULL);
        std::lock_guard<std::mutex> guard(tapLock);
        tapThreadRunning = false;
        tapRunLoop = NULL;
    }
}

// Key events for the keyboard queue, if the system allows them; polling otherwise.
static void startKeyTap(void) {
    if (keyTap) { keyboardQueue.setExternal(true); return; }
    if (!CGPreflightListenEventAccess()) {
        // Ask once, and only with no window open: the system's dialog would be
        // behind a full-screen window.
        if (!device && !inputMonitoringRequested) {
            inputMonitoringRequested = true;
            CGRequestListenEventAccess();
        }
        if (!inputMonitoringWarned) {
            inputMonitoringWarned = true;
            hookWarn(pm::kWarnInputMonitoring,
                     "This application is not allowed Input Monitoring, so key times are those of the "
                     "polling scan that found them (the poll interval, 2 ms by default). For the "
                     "times of the key events themselves, allow it in System Settings, Privacy & "
                     "Security, Input Monitoring, then restart the application. Warned once.");
        }
        return;
    }
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                       CGEventMaskBit(kCGEventFlagsChanged);
    CFRunLoopSourceRef source = NULL;
    CFMachPortRef port = startTap(mask, keyTapCallback, &source);
    if (!port) return;
    {
        std::lock_guard<std::mutex> guard(tapLock);
        keyTap = port; keyTapSource = source;
    }
    keyboardQueue.setExternal(true);
}
static void stopKeyTap(void) {
    keyboardQueue.setExternal(false);
    stopTap(&keyTap, &keyTapSource);
}
static void stopMouseTap(void) {
    stopTap(&mouseTap, &mouseTapSource);
    std::lock_guard<std::mutex> guard(tapLock);
    mouseEventHead = mouseEventCount = 0;
    mouseEventsDropped = 0;
}
#endif

static void releaseKeyboardQueue() {
    stopKeyTap();
    keyboardQueue.release();
    if(keyboardQueueLocked) { keyboardQueueLocked=false; hookUnpin(); }
}
[[noreturn]] static void fail(const char *s);
static int waitRelative(double endTime);
static void closeCore(void);
static void stopPresenter(void);
static void notePipelineSample(Record *q);
static void prepareApp(void);
#if !PM_IOS
static void settleAppKit(double seconds);
#endif
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

// Encode draw-list items [first, first + n) into a pass on a target width x height
// pixels. Draw order is preserved. Buffer slots and texture versions remain owned
// until GPU completion. The draw list is read in place: only the caller thread
// writes it, and this is the caller thread. `target` selects the pipelines.
static void encodeItems(id<MTLRenderCommandEncoder> re, id<MTLCommandBuffer> cb, int target,
                        NSUInteger first, NSUInteger n, NSUInteger width, NSUInteger height) {
    if (n == 0 || !re)
        return;
    const PMDrawItem *items = drawList + first;
    PMTextureRef *refs = drawTextureRefs + first;
    PMTextureRef *coverageRefs = drawCoverageRefs + first;
    PMShaderRef *shaderRefs=drawShaderRefs+first;

    float size[2] = {(float)width, (float)height};

    size_t textureCount=0;
    bool hasShapes=false;
    for (NSUInteger i=0;i<n;i++) {
        textureCount += (refs[i] ? 1 : 0) + (coverageRefs[i] ? 1 : 0);
        hasShapes |= items[i].type==PM_ITEM_SHAPE;
    }
    // Procedural-only frames have no texture versions to retain. Avoid a heap
    // allocation and completion callback in that common high-refresh path.
    if (textureCount) {
        auto resources=std::make_shared<std::vector<PMTextureRef>>();
        resources->reserve(textureCount);
        for (NSUInteger i=0;i<n;i++) {
            if(refs[i]) resources->push_back(refs[i]);
            if(coverageRefs[i]) resources->push_back(coverageRefs[i]);
        }
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            resources->clear();
            pthread_mutex_lock(&lock);
            pthread_cond_broadcast(&cond); pthread_mutex_unlock(&lock);
        }];
    }
    bool hasCustom=false;
    for(NSUInteger i=0;i<n;i++) hasCustom|=bool(shaderRefs[i]);
    if(hasCustom) {
        auto retained=std::make_shared<std::vector<PMShaderRef>>();retained->reserve(n);
        for(NSUInteger i=0;i<n;i++)if(shaderRefs[i])retained->push_back(shaderRefs[i]);
        [cb addCompletedHandler:^(id<MTLCommandBuffer>){retained->clear();}];
    }
    int slot=-1;
    if (hasShapes) {
        pthread_mutex_lock(&lock);
        slot=shapeBufferIndex;
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
    }
    PMShape *base = hasShapes ? (PMShape *)shapeBuffers[slot].contents : nullptr;
    NSUInteger written = 0;      // total shapes placed in this pass's buffer
    NSUInteger batched = 0;      // shapes in the run waiting to be drawn
    uint32_t batchBlend = PM_BLEND_ALPHA;
    // Consecutive shapes with one blend mode and one clip are one instanced draw.
    auto drawBatch = [&]() {
        if (batched == 0)
            return;
        [re setRenderPipelineState:shapePipelines[target][batchBlend]];
        // Constant-buffer bindings require 256-byte alignment on the simulator.
        // Bind the start and select the batch through instance_id instead of
        // rebasing the buffer by a potentially unaligned 64-byte shape stride.
        [re setVertexBuffer:shapeBuffers[slot] offset:0 atIndex:0];
        [re setVertexBytes:size length:sizeof(size) atIndex:1];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip
               vertexStart:0
               vertexCount:4
             instanceCount:batched
              baseInstance:written - batched];
        batched = 0;
    };
    // The scissor in force, as [left top right bottom] inside the target.
    const int32_t whole[4] = {0, 0, (int32_t)width, (int32_t)height};
    int32_t scissor[4] = {whole[0], whole[1], whole[2], whole[3]};

    for (NSUInteger i = 0; i < n; i++) {
        const PMDrawItem *it = &items[i];
        uint32_t blend = it->blend < PM_BLEND_COUNT ? it->blend : (uint32_t)PM_BLEND_ALPHA;
        // An item's clip, cut to the target; an item with no clip has all of it.
        int32_t want[4] = {whole[0], whole[1], whole[2], whole[3]};
        if (it->clip[2] > it->clip[0] && it->clip[3] > it->clip[1]) {
            want[0] = std::max(it->clip[0], whole[0]); want[1] = std::max(it->clip[1], whole[1]);
            want[2] = std::min(it->clip[2], whole[2]); want[3] = std::min(it->clip[3], whole[3]);
        }
        if (want[2] <= want[0] || want[3] <= want[1])
            continue;                       // clipped away entirely
        if (memcmp(want, scissor, sizeof(scissor)) != 0) {
            drawBatch();
            memcpy(scissor, want, sizeof(scissor));
            MTLScissorRect area = {(NSUInteger)scissor[0], (NSUInteger)scissor[1],
                                   (NSUInteger)(scissor[2] - scissor[0]), (NSUInteger)(scissor[3] - scissor[1])};
            [re setScissorRect:area];
        }
        if (it->type == PM_ITEM_SHAPE) {
            if (blend != batchBlend)
                drawBatch();
            batchBlend = blend;
            base[written++] = it->shape;
            batched++;
            continue;
        }
        drawBatch();
        if(it->type==PM_ITEM_CUSTOM && shaderRefs[i]) {
            PMStimulusUniform u=it->stimulus;u.viewport[0]=size[0];u.viewport[1]=size[1];
            [re setRenderPipelineState:shaderRefs[i]->pipelines[target][blend]];
            [re setVertexBytes:&u length:sizeof(u) atIndex:0];[re setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [re setFragmentTexture:(refs[i] ? refs[i]->texture : stimulusWhite) atIndex:0];
            [re setFragmentSamplerState:linearSampler atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];continue;
        }
        if (it->type == PM_ITEM_STIMULUS) {
            PMStimulusUniform u=it->stimulus;
            u.viewport[0]=size[0]; u.viewport[1]=size[1];
            [re setRenderPipelineState:stimulusPipelines[target][blend]];
            [re setVertexBytes:&u length:sizeof(u) atIndex:0];
            [re setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [re setFragmentTexture:(refs[i] ? refs[i]->texture : stimulusWhite) atIndex:0];
            [re setFragmentSamplerState:linearSampler atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            continue;
        }
        if (it->type == PM_ITEM_MASKED_TEXTURE && refs[i]) {
            struct {float dst[4],src[4],tint[4],size[2],angle,mono,maskA[4],maskB[4];} u{};
            static_assert(sizeof(u)==96,"Masked texture uniform layout mismatch");
            memcpy(u.dst,it->dst,sizeof(u.dst));memcpy(u.src,it->src,sizeof(u.src));
            memcpy(u.tint,it->tint,sizeof(u.tint));memcpy(u.maskA,it->stimulus.maskA,sizeof(u.maskA));
            memcpy(u.maskB,it->stimulus.maskB,sizeof(u.maskB));
            u.size[0]=size[0];u.size[1]=size[1];u.angle=it->angle;
            bool premultiplied=refs[i]->offscreen;
            u.mono=premultiplied ? 3 : refs[i]->channels==1 ? 1 : 0;
            [re setRenderPipelineState:maskedTexturePipelines[target][blend][premultiplied]];
            [re setVertexBytes:&u length:sizeof(u) atIndex:0];
            [re setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [re setFragmentTexture:refs[i]->texture atIndex:0];
            [re setFragmentTexture:(coverageRefs[i] ? coverageRefs[i]->texture : stimulusWhite) atIndex:1];
            [re setFragmentSamplerState:(it->filterMode ? linearSampler : nearestSampler) atIndex:0];
            [re setFragmentSamplerState:linearSampler atIndex:1];
            [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            texturesDrawn++;continue;
        }
        if (!refs[i])
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
        // 0: RGBA as it is. 1: grey, replicated. 2: an alpha mask for the tint.
        // 3: an offscreen window, whose colour is already multiplied by its alpha.
        const bool offscreen = refs[i]->offscreen;
        u.mono = it->mask ? 2.0f : offscreen ? 3.0f : refs[i]->channels==1 ? 1.0f : 0.0f;
        [re setRenderPipelineState:texturePipelines[target][blend][offscreen]];
        [re setVertexBytes:&u length:sizeof(u) atIndex:0];
        [re setFragmentTexture:refs[i]->texture atIndex:0];
        [re setFragmentSamplerState:(it->filterMode ? linearSampler : nearestSampler)
                            atIndex:0];
        [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        texturesDrawn++;
    }
    drawBatch();
    for(NSUInteger i=0;i<n;i++) {refs[i].reset();coverageRefs[i].reset();shaderRefs[i].reset();}
}

// The window's draws: everything queued. The caller has rendered an offscreen
// target's draws already (flushTarget), so none of those remain.
static void encodeShapes(id<MTLRenderCommandEncoder> re, id<MTLCommandBuffer> cb, int target) {
    pthread_mutex_lock(&lock);
    NSUInteger n = drawCount;
    drawCount = 0;
    targetBase = 0;
    haveLastShape = false;
    shapeEncodeCalls++;
    shapesEncoded += n;
    pthread_mutex_unlock(&lock);
    encodeItems(re, cb, target, 0, n, renderWidth, renderHeight);
}

// A command buffer that renders without presenting has finished: a queued frame's
// store (its token), or an offscreen window's draws or first contents (token 0).
// A GPU error there fails the session, as one in a presented frame does, and
// fails the frame: the presenter does not show a store that was not rendered,
// and status 3 is kept through whatever the display reports of it later or a
// cancellation.
static void renderFinished(uint64_t epoch, uint64_t token, bool failed) {
    pthread_mutex_lock(&lock);
    if (epoch == sessionEpoch) {
        Record *q = token ? recordFor(token) : nullptr;
        if (failed) {
            asynchronousGpuFailure = true;
            if (q) q->status = 3;
        }
        if (q) q->renderDone = 1;
    }
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
}
static void watchRender(id<MTLCommandBuffer> cb, uint64_t token) {
    const uint64_t epoch = sessionEpoch;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> x) {
        renderFinished(epoch, token, x.status == MTLCommandBufferStatusError);
    }];
}

// Render the draws waiting for the offscreen target into it, and forget them.
// The command buffer is committed, not presented: the GPU runs buffers in the
// order they were committed, so a later frame that samples the target sees this.
static void flushTarget(void) {
    if (!targetTexture || drawCount <= targetBase)
        return;
    NSUInteger first = targetBase, n = drawCount - targetBase;
    pthread_mutex_lock(&lock);
    drawCount = first;
    shapesEncoded += n;
    pthread_mutex_unlock(&lock);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = targetTexture->texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = cb ? [cb renderCommandEncoderWithDescriptor:pass] : nil;
    if (!re) {
        for (NSUInteger i = 0; i < n; i++) {drawTextureRefs[first + i].reset();drawCoverageRefs[first + i].reset();drawShaderRefs[first + i].reset();}
        fail("Could not render into the offscreen window.");
    }
    // Encoding can throw (no shape buffer came free); an encoder must be ended even then.
    try {
        encodeItems(re, cb, PM_TARGET_OFFSCREEN, first, n, targetTexture->width, targetTexture->height);
    } catch (...) {
        [re endEncoding];
        for (NSUInteger i = 0; i < n; i++) {drawTextureRefs[first + i].reset();drawCoverageRefs[first + i].reset();drawShaderRefs[first + i].reset();}
        throw;
    }
    [re endEncoding];
    watchRender(cb, 0);
    [cb commit];
}

// A frame, rendered into `out`: a drawable's texture, or a queued frame's store,
// which has the drawable's format. One pass; or, with linearization, one into the
// linear target and one that writes the display values. A readback session then
// copies the finished frame, in the same command buffer, so the copy holds the
// pixels that go to the display.
static bool encodeFrame(id<MTLCommandBuffer> cb, id<MTLTexture> out, uint64_t token) {
    if (!cb || !out)
        return false;
    const bool linear = encodeMode != PM_ENCODE_NONE && linearTarget && encodePipeline;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = linear ? linearTarget : out;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(clearRGBA[0], clearRGBA[1], clearRGBA[2], clearRGBA[3]);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
    if (!re)
        return false;
    try {
        encodeShapes(re, cb, linear ? PM_TARGET_FLOAT : PM_TARGET_DRAWABLE);
    } catch (...) {
        [re endEncoding];
        for (auto &r : drawTextureRefs) r.reset();
        for (auto &r : drawCoverageRefs) r.reset();
        for (auto &r : drawShaderRefs) r.reset();
        throw;
    }
    [re endEncoding];
    if (linear) {
        MTLRenderPassDescriptor *written = [MTLRenderPassDescriptor renderPassDescriptor];
        written.colorAttachments[0].texture = out;
        written.colorAttachments[0].loadAction = MTLLoadActionDontCare;   // every pixel is written
        written.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> ee = [cb renderCommandEncoderWithDescriptor:written];
        if (!ee) {
            // The first pass took a shape buffer; committing runs the handlers that
            // free it. Nothing is presented.
            [cb commit];
            return false;
        }
        struct {
            float exponent[4];
            uint32_t mode, n, pad[2];
        } u = {{encodeExponent[0], encodeExponent[1], encodeExponent[2], 1.0f},
               (uint32_t)encodeMode, (uint32_t)encodeTableSize, {0, 0}};
        static_assert(sizeof(u)==32,"Encode uniform layout mismatch");
        [ee setRenderPipelineState:encodePipeline];
        [ee setFragmentTexture:linearTarget atIndex:0];
        // The shader declares the table; without one, bind something it never reads.
        [ee setFragmentTexture:(encodeTable ? encodeTable : linearTarget) atIndex:1];
        [ee setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [ee drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [ee endEncoding];
    }
    if (captureBuffer) {
        // The frame is presented whether or not it could be copied. Without a
        // copy captureToken stays behind, and GetImage refuses to answer.
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (blit) {
            [blit copyFromTexture:out sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(renderWidth, renderHeight, 1)
                        toBuffer:captureBuffer destinationOffset:0
                destinationBytesPerRow:capturePitch destinationBytesPerImage:capturePitch * renderHeight];
            [blit endEncoding];
            captureToken = token;
        }
    }
    return true;
}

static void attachHandlers(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d, uint64_t token) {
    const uint64_t epoch=sessionEpoch;
    void (^presented)(double, double) = ^(double pt, double ct) {
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
                if (!q->queued && onTarget && lead > 0 && lead < 10.0 * ifi)
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
    };
#if TARGET_OS_SIMULATOR
    // The simulator's drawables do not report when they were shown. So that
    // programs run there at all, the time a frame's rendering finished stands
    // in: nothing timed in the simulator says anything about a device.
    (void)d;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> x) {
        (void)x;
        const double now = CACurrentMediaTime();
        presented(now, now);
    }];
#else
    [d addPresentedHandler:^(id<MTLDrawable> x) { presented(x.presentedTime, CACurrentMediaTime()); }];
#endif
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
static std::vector<uint8_t> byteScratch;
// Validation and packing live in PsychMetalShared.cpp, so they are shared by
// every front end and testable without a GPU. uint8 and logical images are
// stored in 8-bit textures as they are; float images as half floats.
static void uploadTexture(int slot,const pm::ArrayView &image) {
    double began=CACurrentMediaTime();
    const bool bytes=pm::internal::isByteImage(image);
    pm::internal::ImageShape shape;
    const void *texels;
    if(bytes) texels=pm::internal::packBytes(image,byteScratch,shape);
    else { shape=pm::internal::packImage(image,uploadScratch); texels=uploadScratch.data(); }
    size_t h=shape.height,w=shape.width,c=shape.channels;
    auto &pool=texturePools[slot];
    PMTextureRef resource;
    for(auto &candidate:pool) {
        long owners=candidate.use_count();
        long idleOwners=userTextures[slot]==candidate ? 2 : 1;
        if(owners==idleOwners && candidate->width==w && candidate->height==h && candidate->channels==c &&
           candidate->bytes==bytes) {
            resource=candidate; break;
        }
    }
    if(!resource) {
        pool.erase(std::remove_if(pool.begin(),pool.end(),[&](const PMTextureRef &r) {
            return r!=userTextures[slot] && r.use_count()==1;
        }),pool.end());
        if(pool.size()>=4) {
            // Frames that drew the older versions may only be queued or rendering: give them two seconds.
            pthread_mutex_lock(&lock);
            double deadline=CACurrentMediaTime()+2.0;
            for(;;) {
                pool.erase(std::remove_if(pool.begin(),pool.end(),[&](const PMTextureRef &r) {
                    return r!=userTextures[slot] && r.use_count()==1;
                }),pool.end());
                if(pool.size()<4 || waitRelative(deadline)==ETIMEDOUT) break;
            }
            pthread_mutex_unlock(&lock);
            if(pool.size()>=4) fail("Texture update pool is busy; Flip before updating this texture again.");
        }
        MTLPixelFormat format=bytes ? (c==1?MTLPixelFormatR8Unorm:MTLPixelFormatRGBA8Unorm)
                                    : (c==1?MTLPixelFormatR16Float:MTLPixelFormatRGBA16Float);
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
            width:w height:h mipmapped:NO];
        td.usage=MTLTextureUsageShaderRead; td.storageMode=MTLStorageModeShared;
        id<MTLTexture> texture=[device newTextureWithDescriptor:td];
        if(!texture) fail("Could not allocate Metal texture.");
        resource=std::make_shared<PMTextureResource>();
        resource->texture=texture; resource->width=w; resource->height=h; resource->channels=c;
        resource->bytes=bytes;
        pool.push_back(resource); textureAllocations++;
    }
    [resource->texture replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0
        withBytes:texels bytesPerRow:w*(c==1?1:4)*(bytes?sizeof(uint8_t):sizeof(__fp16))];
    userTextures[slot]=resource; cpuUploadMs=(CACurrentMediaTime()-began)*1000;
}
// Invalidate the session before new records may be allocated. The graphics MEX stays pinned.
static void closeCore(void) {
    stopDisplayDriver();
    releaseKeyboardQueue();
    stopMouseTap();
    stopPresenter();
    pthread_mutex_lock(&lock);
    if(preparedToken) {
        Record *r=recordFor(preparedToken);
        if(r) { r->done=1; r->status=5; if(r->inFlight && r->gpuDone) {r->inFlight=0; --inFlightCount;} }
    }
    pthread_mutex_unlock(&lock);
    preparedDrawable=nil; preparedToken=0; heldDrawable=nil;
    for(auto &r:drawTextureRefs) r.reset();
    for(auto &r:drawCoverageRefs) r.reset();
    for(auto &r:drawShaderRefs)r.reset();
    userShaders.clear();shaderCache.clear();
    targetTexture.reset(); targetHandle=0; targetBase=0;
    pthread_mutex_lock(&lock);
    closing = true;
    pthread_cond_broadcast(&cond);
    bool drained=drainLocked();
    ++sessionEpoch; // any late callback is obsolete before resources are reset
    frameStores.clear();
    frameStoreCount = 0;
    queuedTokens.clear();
    pthread_mutex_unlock(&lock);
    if(!drained) hookWarn(pm::kWarnDrainTimeout, "Close timed out waiting for callbacks; old callbacks have been isolated.");
#if PM_IOS
    iosCloseWindow();
#else
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
#endif
    activationPolicyPromotionAttempted = false;
    activationPolicyPromotionSucceeded = false;
    appPrepared = false;
    captureBuffer = nil;
    captureToken = 0;
    capturePitch = 0;
    for (int t = 0; t < PM_TARGET_COUNT; t++)
        for (int b = 0; b < PM_BLEND_COUNT; b++) {
            stimulusPipelines[t][b] = nil;
            maskedTexturePipelines[t][b][0] = maskedTexturePipelines[t][b][1] = nil;
            shapePipelines[t][b] = nil;
            texturePipelines[t][b][0] = texturePipelines[t][b][1] = nil;
        }
    encodePipeline = nil;
    linearTarget = nil;
    encodeTable = nil;
    encodeTableSize = 0;
    encodeMode = PM_ENCODE_NONE;
    stimulusWhite = nil;
    shaderLibrary = nil;
    maskCache.clear();
    maskCacheBytes = 0;
    maskUses = 0;
    unkeptMask = PMMask{};
    std::vector<__fp16>().swap(uploadScratch);
    std::vector<uint8_t>().swap(byteScratch);
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
#if !PM_IOS
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
#endif
    appPrepared = true;
}
#if !PM_IOS
// The window's view, which takes the trackpad's contacts: fingers resting or
// moving on it, apart from what the system makes of them as a pointer. A
// contact's place is where it is on the trackpad, as a place in the window: the
// trackpad's corners are the window's. AppKit delivers them, with its events'
// times, to the view under the pointer, on the main thread, once the view asks
// for them, which it does at the first TouchEvents: a program that never asks
// gets the window it always had.
static std::mutex trackpadLock;             // guards touchRing and trackpadFinger
static id trackpadFinger[PM_FINGERS];       // the identity of the contact that is finger k + 1
static bool trackpadListening;              // the view has been told to take contacts
@interface PMTouchView : NSView
@end
@implementation PMTouchView
- (void)note:(NSEvent *)event matching:(NSTouchPhase)matching phase:(int)phase {
    std::lock_guard<std::mutex> guard(trackpadLock);
    for (NSTouch *touch in [event touchesMatchingPhase:matching inView:self]) {
        id identity = touch.identity;
        int finger = 0;
        for (int k = 0; k < PM_FINGERS && !finger; k++)
            if (trackpadFinger[k] && [trackpadFinger[k] isEqual:identity]) finger = k + 1;
        if (!finger && phase == 0)
            for (int k = 0; k < PM_FINGERS && !finger; k++)
                if (!trackpadFinger[k]) { trackpadFinger[k] = identity; finger = k + 1; }
        if (!finger) continue;      // more fingers than are numbered, or one not seen going down
        const NSPoint at = touch.normalizedPosition;        // 0 to 1, from the trackpad's lower left
        touchRing.push({event.timestamp, finger, phase, at.x * (double)renderWidth,
                        (1.0 - at.y) * (double)renderHeight});
        if (phase >= 2) trackpadFinger[finger - 1] = nil;
    }
}
- (void)touchesBeganWithEvent:(NSEvent *)event { [self note:event matching:NSTouchPhaseBegan phase:0]; }
- (void)touchesMovedWithEvent:(NSEvent *)event { [self note:event matching:NSTouchPhaseMoved phase:1]; }
- (void)touchesEndedWithEvent:(NSEvent *)event { [self note:event matching:NSTouchPhaseEnded phase:2]; }
- (void)touchesCancelledWithEvent:(NSEvent *)event { [self note:event matching:NSTouchPhaseCancelled phase:3]; }
@end

// The events waiting for this application, delivered: the main thread's work
// where no loop of the host's does it. Key events are taken and not delivered: a
// window with nothing to do with one beeps. Main thread.
static void deliverAppKitEvents(NSDate *until) {
    static bool launched = false;
    NSApplication *app = [NSApplication sharedApplication];
    if (!launched) { [app finishLaunching]; launched = true; }
    NSEvent *event;
    while ((event = [app nextEventMatchingMask:NSEventMaskAny untilDate:until
                                        inMode:NSDefaultRunLoopMode dequeue:YES])) {
        NSEventType t = event.type;
        if (t != NSEventTypeKeyDown && t != NSEventTypeKeyUp && t != NSEventTypeFlagsChanged)
            [app sendEvent:event];
        until = [NSDate distantPast];   // drain what is queued, then return
    }
}

static void settleAppKit(double seconds) {
    onMainSync(^{
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while (limit.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    });
}
#endif
// A pipeline for one pair of shader functions, one target format and one way of
// blending (pm::internal::blendFor, which says what each mode does).
static_assert(MTLBlendFactorZero == 0 && MTLBlendFactorOne == 1 && MTLBlendFactorSourceAlpha == 4 &&
              MTLBlendFactorOneMinusSourceAlpha == 5, "pm::internal::BlendFactor is numbered as MTLBlendFactor");
static id<MTLRenderPipelineState> makePipeline(NSString *vertex, NSString *fragment, MTLPixelFormat format,
                                               const pm::internal::Blend &blend, NSError **error, id<MTLLibrary> library=nil) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [(library ? library : shaderLibrary) newFunctionWithName:vertex];
    pd.fragmentFunction = [(library ? library : shaderLibrary) newFunctionWithName:fragment];
    pd.colorAttachments[0].pixelFormat = format;
    if (blend.enabled) {
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].sourceRGBBlendFactor = (MTLBlendFactor)blend.sourceRGB;
        pd.colorAttachments[0].sourceAlphaBlendFactor = (MTLBlendFactor)blend.sourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = (MTLBlendFactor)blend.destinationRGB;
        pd.colorAttachments[0].destinationAlphaBlendFactor = (MTLBlendFactor)blend.destinationAlpha;
    }
    return [device newRenderPipelineStateWithDescriptor:pd error:error];
}
// The shape and texture pipelines for one target, in every blend mode. nil on success.
static NSString *makeTargetPipelines(int target, MTLPixelFormat format) {
    using pm::internal::blendFor;
    const bool offscreen = target == PM_TARGET_OFFSCREEN;
    NSError *error = nil;
    for (int blend = 0; blend < PM_BLEND_COUNT; blend++) {
        stimulusPipelines[target][blend] = makePipeline(@"pvmain", @"pfmain", format, blendFor(blend, false, offscreen), &error);
        if (!stimulusPipelines[target][blend])
            return [NSString stringWithFormat:@"Metal stimulus pipeline failed: %@", error.localizedDescription];
        shapePipelines[target][blend] = makePipeline(@"svmain", @"sfmain", format, blendFor(blend, false, offscreen), &error);
        if (!shapePipelines[target][blend])
            return [NSString stringWithFormat:@"Metal shape pipeline failed: %@", error.localizedDescription];
        for (int source = 0; source < 2; source++) {
            maskedTexturePipelines[target][blend][source] =
                makePipeline(@"mvmain", @"mfmain", format, blendFor(blend, source == 1, offscreen), &error);
            if (!maskedTexturePipelines[target][blend][source])
                return [NSString stringWithFormat:@"Metal masked texture pipeline failed: %@", error.localizedDescription];
            texturePipelines[target][blend][source] =
                makePipeline(@"tvmain", @"tfmain", format, blendFor(blend, source == 1, offscreen), &error);
            if (!texturePipelines[target][blend][source])
                return [NSString stringWithFormat:@"Metal texture pipeline failed: %@", error.localizedDescription];
        }
    }
    return nil;
}
// The pipelines that draw into a half-float target (the linearization target, or
// offscreen windows), made the first time one is needed.
static void ensureTargetPipelines(int target) {
    if (shapePipelines[target][0])
        return;
    NSString *problem = makeTargetPipelines(target, MTLPixelFormatRGBA16Float);
    if (problem) {
        for (int b = 0; b < PM_BLEND_COUNT; b++)
            shapePipelines[target][b] = stimulusPipelines[target][b] =
                maskedTexturePipelines[target][b][0] = maskedTexturePipelines[target][b][1] =
                texturePipelines[target][b][0] = texturePipelines[target][b][1] = nil;
        failWith(pm::kErrPipeline, "%s", problem.UTF8String);
    }
}
// What linearization needs, made the first time it is turned on: the linear
// target, the pipelines that draw into it, and the pass that writes the drawable.
static void ensureLinearResources(void) {
    if (linearTarget && encodePipeline)
        return;
    ensureTargetPipelines(PM_TARGET_FLOAT);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
        width:renderWidth height:renderHeight mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    if (!target)
        fail("Could not allocate the linear render target.");
    NSError *error = nil;
    id<MTLRenderPipelineState> encode = makePipeline(@"evmain", @"efmain", drawableFormat,
                                                     pm::internal::blendFor(PM_BLEND_COPY, false, false), &error);
    if (!encode)
        failWith(pm::kErrPipeline, "Metal linearization pipeline failed: %s", error.localizedDescription.UTF8String);
    linearTarget = target;
    encodePipeline = encode;
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
                     bool waitConfirm, bool vsync, bool doCapture, bool readable, int bits, bool linked, uint32_t requestedDisplay) {
    if (!appPrepared)
        fail("PrepareApp must be called before Open.");
    if (metalWindow || device)
        fail("PsychMetal native resources are already open.");
    if(!graphicsLocked) { hookPin(); graphicsLocked=true; }
    pthread_mutex_lock(&lock); ++sessionEpoch; pthread_mutex_unlock(&lock);
    keyScanMaxMs=secureQueryMaxMs=keyScanTotalMs=secureQueryTotalMs=0;keyReadCount=0;
    startupRecords.clear();startupReady=false;
    requestedDrawableCount = drawableCount;
    outputBits = bits;
    drawableFormat = bits == 10 ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm;
    directWaitForConfirm = waitConfirm;
    displaySync = vsync;
    device = MTLCreateSystemDefaultDevice();
    if (!device)
        failOpen(pm::kErrMetal, @"No Metal device.");
    queue = [device newCommandQueue];
    if (!queue)
        failOpen(pm::kErrMetal, @"Could not create a Metal command queue.");
#if PM_IOS
    (void)screenIndex; (void)globalLeft; (void)globalTop; (void)globalRight; (void)globalBottom; (void)doCapture; (void)requestedDisplay;
    displaySync = true;         // presentation here is always synchronized to the display
    iosOpenWindow(w, h, 1.0 / period, drawableCount, readable, linked);
#else
    (void)linked; (void)screenIndex; (void)globalLeft; (void)globalTop;
    (void)globalRight; (void)globalBottom;
    __block NSString *mappingWarning = nil;
    onMainSync(^{
        NSArray<NSScreen *> *screens = NSScreen.screens;
        NSScreen *screen = nil;
        selectedScreenIndex = -1;
        // CoreGraphics and AppKit enumeration order/geometry are not identities.
        // Mirrored displays can have identical rectangles. Match the display ID.
        for (NSUInteger i=0;i<screens.count;i++) {
            uint32_t identifier=[screens[i].deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            if (identifier==requestedDisplay) {
                screen=screens[i]; selectedScreenIndex=(NSInteger)i; break;
            }
        }
        if (!screen) {
            mappingWarning=@"The selected CoreGraphics display has no matching AppKit screen. It may have disconnected; refusing to present on a different screen.";
            return;
        }
        selectedDisplayID=requestedDisplay;
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
        PMTouchView *view = [[PMTouchView alloc] initWithFrame:metalWindow.contentView.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        trackpadListening = false;
        view.wantsLayer = YES;
        layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = drawableFormat;
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
    if (mappingWarning) failOpen(pm::kErrScreen, mappingWarning);
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
#endif
    ifi = period;
    renderWidth = w;
    renderHeight = h;
    // As many queued frames as fit in a gigabyte, between 2 and 64.
    frameStoreLimit = (NSUInteger)std::min<double>(64, std::max<double>(2, floor(1073741824.0 / ((double)w * (double)h * 4))));
    captureToken = 0;
    if (readable) {
        // A shared linear buffer is CPU-readable after GPU completion. The
        // blit writes the final frame straight into it, avoiding getBytes and
        // a second full-image CPU copy. 256-byte rows satisfy Metal alignment.
        capturePitch = ((size_t)w * 4 + 255) & ~(size_t)255;
        captureBuffer = [device newBufferWithLength:capturePitch * (size_t)h
                                           options:MTLResourceStorageModeShared];
        if (!captureBuffer)
            failOpen(pm::kErrMetal, @"Could not allocate the readback buffer.");
    }
    NSString *source = [NSString stringWithUTF8String:PMMetalSource];
    NSError *shaderError = nil;
    shaderLibrary = [device newLibraryWithSource:source options:nil error:&shaderError];
    if (!shaderLibrary)
        failOpen(pm::kErrShader, [NSString stringWithFormat:@"Metal shader failed: %@",
                                       shaderError.localizedDescription]);
    MTLTextureDescriptor *whiteDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];
    whiteDesc.usage=MTLTextureUsageShaderRead; whiteDesc.storageMode=MTLStorageModeShared;
    stimulusWhite=[device newTextureWithDescriptor:whiteDesc];
    if(!stimulusWhite) fail("Could not allocate stimulus mask fallback.");
    uint8_t whitePixel=255;
    [stimulusWhite replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&whitePixel bytesPerRow:1];
    NSString *pipelineProblem = makeTargetPipelines(PM_TARGET_DRAWABLE, drawableFormat);
    if (pipelineProblem)
        failOpen(pm::kErrPipeline, pipelineProblem);
    blendMode = PM_BLEND_ALPHA;
    memset(clipRect, 0, sizeof(clipRect));
    // A texture handle is never the window's handle, so one number names one thing.
    if (nextTextureHandle <= sessionEpoch) nextTextureHandle = sessionEpoch + 1;
    encodeMode = PM_ENCODE_NONE;
    encodeExponent[0] = encodeExponent[1] = encodeExponent[2] = 1;
    for (int i = 0; i < PM_SHAPE_RING; i++) {
        shapeBuffers[i] = [device newBufferWithLength:PM_MAX_SHAPES * sizeof(PMShape)
                                              options:MTLResourceStorageModeShared];
        if (!shapeBuffers[i])
            failOpen(pm::kErrMetal, @"Could not allocate the shape instance buffer.");
    }
    shapeBufferIndex = 0;
    drawCount = 0;

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
    lastFlipToken = 0;
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
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);

    double acquireBegan=CACurrentMediaTime();
    id<CAMetalDrawable> d = nil;
    if (displayLinkPresentation) {
        if (@available(macOS 14.0, iOS 17.0, *)) {
            CAMetalDisplayLinkUpdate *update = [displayDriver nextUpdate:haveWhen ? when : 0];
            d = update.drawable;
            if (d) {
                target = update.targetPresentationTimestamp;
                presentation = {target, target};
                pthread_mutex_lock(&lock);
                if (Record *q=recordFor(t)) {
                    q->projected=target; q->presentRequest=target;
                }
                pthread_mutex_unlock(&lock);
            }
        }
    } else {
        d = heldDrawable;
        heldDrawable = nil;
        if (!d) d = layer.nextDrawable;
    }
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
    if (!encodeFrame(cb, d.texture, t)) {
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
    commitPresentation(cb, d, displayLinkPresentation,
                       isfinite(target) ? presentation.request : NAN);

    pthread_mutex_lock(&lock);
    Record *pr = recordFor(t);
    if (pr && pr->committedAt > 0.0 && !displayLinkPresentation) {
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
    if(displayLinkPresentation) fail("PrepareFlip requires direct presentation; use Flip in display-link mode.");
    if(!device || closing) fail("PsychMetal is not open.");
#if PM_IOS
    iosRequireFront();
#endif
    if (preparedToken)
        fail("A frame is already prepared; call PresentNow before preparing another.");
    pthread_mutex_lock(&lock);
    Record *handed = lastHandedToken ? recordFor(lastHandedToken) : nullptr;
    bool queued = !frameQueue.empty() || presenterBusy || (handed && !handed->done);
    pthread_mutex_unlock(&lock);
    if (queued) fail("Frames are queued; wait for them with QueueResults or QueueCancel them first.");
    flushTarget();

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
        if (q) { q->status = 4; q->done = 1; q->gpuDone = 1; }
        directNoDrawableCount++;
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        fail("Could not prepare frame: no drawable or encoding failed.");
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!encodeFrame(cb, d.texture, t)) {
        pthread_mutex_lock(&lock);
        Record *q = recordFor(t);
        if (q) { q->status = 3; q->done = 1; q->gpuDone = 1; }
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
    }
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    return {t0, (t1 - t0) * 1000.0};
}
// Caller holds lock. Frames that are queued come before anything submitted now:
// wait for the presenter to hand them all over. False on timeout or close.
static bool waitQueueIdleLocked(void) {
    while (!frameQueue.empty() || presenterBusy) {
        if (closing)
            return false;
        double deadline = (frameQueue.empty() ? CACurrentMediaTime() : frameQueue.back().when) + 2.0;
        if (waitRelative(deadline) == ETIMEDOUT && CACurrentMediaTime() >= deadline)
            return false;
    }
    // And until the last of them is shown: a frame presented now, with no time,
    // might otherwise overtake one that is waiting for its time.
    if (lastHandedToken) {
        double deadline = CACurrentMediaTime() + 2.0 + PM_QUEUE_LEAD * gridPeriod();
        for (Record *r; (r = recordFor(lastHandedToken)) && !r->done; )
            if (closing || waitRelative(deadline) == ETIMEDOUT)
                return false;
        lastHandedToken = 0;
    }
    return true;
}
static uint64_t enqueue(double when, bool haveWhen) {
    if(!device || closing) fail("PsychMetal is not open.");
#if PM_IOS
    iosRequireFront();
#endif
    if(preparedToken) fail("Present or cancel the prepared frame before Flip.");
    flushTarget();
    pthread_mutex_lock(&lock);
    if(!waitQueueIdleLocked()) {
        pthread_mutex_unlock(&lock);
        fail("Timed out waiting for queued frames; QueueCancel them before Flip.");
    }
    return enqueueDirect(when, haveWhen);
}

// --- frames queued ahead -----------------------------------------------------------

// Caller holds lock. A frame that will not be shown: its record says so and its
// store is idle again.
static void abandonFrameLocked(const PMQueuedFrame &f, int status) {
    Record *r = recordFor(f.token);
    if (r) {
        if (r->status != 3) r->status = status;     // a GPU failure is not overwritten by a cancellation
        r->done = 1; r->gpuDone = 1;
    }
    if (f.store) frameStores.push_back(f.store);
}

// A queued frame's store, as the presenter must treat it: still being rendered
// (wait: renderFinished says when it is not), failed, or ready to show.
enum { PM_STORE_RENDERING, PM_STORE_FAILED, PM_STORE_READY };
static int storeState(const Record *r) {
    if (!r) return PM_STORE_READY;      // its record has been reused: it was queued 16384 frames ago
    if (r->status == 3) return PM_STORE_FAILED;
    return r->renderDone ? PM_STORE_READY : PM_STORE_RENDERING;
}

// The presenter: one frame at a time, in order. It waits until PM_QUEUE_LEAD
// refreshes before the frame's time, draws the frame's store into a drawable and
// asks for it to be presented at the refresh at or after that time. Metal holds
// it until then, so what matters here is only that the thread wakes within the
// lead. A frame is never skipped: one that is late is shown at the next refresh.
static void *presenterMain(void *) {
    pthread_setname_np("PsychMetal presenter");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_mutex_lock(&lock);
    while (!presenterStop) {
        if (frameQueue.empty()) {
            presenterBusy = false;
            pthread_cond_broadcast(&cond);
            pthread_cond_wait(&cond, &lock);
            continue;
        }
        presenterBusy = true;
        double period = gridPeriod();
        double submitAt = frameQueue.front().when - PM_QUEUE_LEAD * period;
        if (CACurrentMediaTime() < submitAt) {
            waitRelative(submitAt);     // woken early by a cancel, a close or another frame: look again
            continue;
        }
        // A store is shown only once the GPU has rendered it, and not at all if it
        // failed to. The GPU runs command buffers in order, so waiting here costs
        // the frame nothing: its presentation could not have run sooner.
        const int store = storeState(recordFor(frameQueue.front().token));
        if (store == PM_STORE_RENDERING) {
            pthread_cond_wait(&cond, &lock);    // renderFinished, a cancel or a close: look again
            continue;
        }
        PMQueuedFrame f = frameQueue.front();
        frameQueue.pop_front();
        if (store == PM_STORE_FAILED) {
            abandonFrameLocked(f, 3);
            pthread_cond_broadcast(&cond);
            continue;
        }
        Record *r = recordFor(f.token);
        lastHandedToken = f.token;
        double now = CACurrentMediaTime();
        double target = gridPointAtOrAfter(fmax(f.when, now));
        if (!isfinite(target))
            target = fmax(f.when, now);
        if (isfinite(lastProjected) && target <= lastProjected + 0.5 * period)
            target = lastProjected + period;
        lastProjected = target;
        double request = target - 0.5 * period;
        if (r) { r->projected = target; r->presentRequest = request; r->scheduledAt = now; }
        const uint64_t epoch = sessionEpoch;
        pthread_mutex_unlock(&lock);

        int failure = 0;    // 0 submitted, 4 no drawable, 3 could not encode
        @autoreleasepool {
            double acquireBegan = CACurrentMediaTime();
            id<CAMetalDrawable> d = layer.nextDrawable;
            double acquiredAt = CACurrentMediaTime();
            id<MTLCommandBuffer> cb = d ? [queue commandBuffer] : nil;
            id<MTLRenderCommandEncoder> re = nil;
            if (cb) {
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = d.texture;
                pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;   // every pixel is written
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                re = [cb renderCommandEncoderWithDescriptor:pass];
            }
            if (!d) {
                failure = 4;
            } else if (!re) {
                failure = 3;
            } else {
                // The store, texel for texel: nearest sampling, no blending.
                struct {
                    float dst[4], src[4], tint[4], size[2], angle, mono;
                } u = {{0, 0, (float)renderWidth, (float)renderHeight}, {0, 0, 1, 1}, {1, 1, 1, 1},
                       {(float)renderWidth, (float)renderHeight}, 0, 0};
                [re setRenderPipelineState:texturePipelines[PM_TARGET_DRAWABLE][PM_BLEND_COPY][0]];
                [re setVertexBytes:&u length:sizeof(u) atIndex:0];
                [re setFragmentTexture:f.store atIndex:0];
                [re setFragmentSamplerState:nearestSampler atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                [re endEncoding];
                attachHandlers(cb, d, f.token);
                id<MTLTexture> store = f.store;
                // The store is idle once the GPU has read it.
                [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
                    pthread_mutex_lock(&lock);
                    if (epoch == sessionEpoch) frameStores.push_back(store);
                    pthread_cond_broadcast(&cond);
                    pthread_mutex_unlock(&lock);
                }];
                pthread_mutex_lock(&lock);
                Record *q = recordFor(f.token);
                if (q) {
                    q->inFlight = 1;
                    q->committedAt = CACurrentMediaTime();
                    q->drawableAcquireMs = (acquiredAt - acquireBegan) * 1000;
                    q->encodeMs = (q->committedAt - acquiredAt) * 1000;
                    inFlightCount++;
                }
                pthread_mutex_unlock(&lock);
                [cb presentDrawable:d atTime:request];
                [cb commit];
            }
        }
        pthread_mutex_lock(&lock);
        if (failure) {
            if (failure == 4) directNoDrawableCount++;
            abandonFrameLocked(f, failure);
        }
        pthread_cond_broadcast(&cond);
    }
    presenterBusy = false;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    return NULL;
}

// Frames still waiting are cancelled (status 5); the thread is joined. A frame
// already handed to Metal is not recalled.
static void stopPresenter(void) {
    pthread_mutex_lock(&lock);
    for (const PMQueuedFrame &f : frameQueue) abandonFrameLocked(f, 5);
    frameQueue.clear();
    bool running = presenterRunning;
    presenterStop = true;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    if (running) pthread_join(presenterThread, NULL);
    pthread_mutex_lock(&lock);
    presenterRunning = presenterStop = presenterBusy = false;
    lastHandedToken = 0;
    pthread_mutex_unlock(&lock);
}

static pm::QueueResult queueFrame(double when) {
    if(displayLinkPresentation) fail("QueueFlip requires direct presentation; use Flip in display-link mode.");
    if (!device || closing) fail("PsychMetal is not open.");
#if PM_IOS
    iosRequireFront();
#endif
    if (preparedToken) fail("Present the prepared frame before queuing frames.");
    if (!isfinite(when) || !(when > 0)) fail("A queued frame needs a presentation time.");
    flushTarget();
    heldDrawable = nil;     // a prefetched drawable would only be kept from the presenter
    pthread_mutex_lock(&lock);
    if (asynchronousGpuFailure || nextToken >= PM_MAX_ID) {
        pthread_mutex_unlock(&lock);
        fail("Presentation session failed; Close and reopen the window.");
    }
    if (!frameQueue.empty() && when <= frameQueue.back().when) {
        pthread_mutex_unlock(&lock);
        fail("Queued frames must be given in order of time.");
    }
    // A store: an idle one, a new one while there may be more, or the next to come idle.
    id<MTLTexture> store = nil;
    bool make = false;
    for (;;) {
        if (!frameStores.empty()) { store = frameStores.back(); frameStores.pop_back(); break; }
        if (frameStoreCount < frameStoreLimit) { frameStoreCount++; make = true; break; }
        double deadline = (frameQueue.empty() ? CACurrentMediaTime() : frameQueue.back().when) + 2.0;
        int waited = waitRelative(deadline);
        if (closing || (waited == ETIMEDOUT && CACurrentMediaTime() >= deadline)) {
            pthread_mutex_unlock(&lock);
            fail("Timed out waiting for a queued frame to be presented.");
        }
    }
    uint64_t t = nextToken++;
    Record *r = &rec[t % NREC];
    memset(r, 0, sizeof(*r));
    r->token = t;
    r->status = 2;
    r->queued = 1;
    r->requestedTime = when;
    r->presentRequest = NAN;
    r->projected = gridPointAtOrAfter(when);
    if (!isfinite(r->projected)) r->projected = when;
    pthread_mutex_unlock(&lock);

    const char *problem = nullptr;
    if (make) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:drawableFormat
            width:renderWidth height:renderHeight mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        store = [device newTextureWithDescriptor:td];
        if (!store) problem = "Could not allocate a store for the queued frame.";
    }
    if (!problem) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        try {
            if (encodeFrame(cb, store, t)) {
                // GetImage may read the frame once it is rendered, long before it is shown.
                watchRender(cb, t);
                [cb commit];
            } else {
                problem = "Could not render the queued frame.";
            }
        } catch (const pm::Error &) {
            problem = "Timed out waiting for a free shape buffer.";
        }
    }
    pthread_mutex_lock(&lock);
    PMQueuedFrame f = {t, when, store};
    if (problem) {
        if (make && !store) frameStoreCount--;
        abandonFrameLocked(f, 3);
        pthread_cond_broadcast(&cond);
        pthread_mutex_unlock(&lock);
        fail(problem);
    }
    frameQueue.push_back(f);
    if (queuedTokens.size() >= NREC) queuedTokens.erase(queuedTokens.begin());   // never reported: forgotten
    queuedTokens.push_back(t);
    double pending = (double)frameQueue.size();
    if (!presenterRunning) {
        presenterStop = false;
        if (pthread_create(&presenterThread, NULL, presenterMain, NULL) != 0) {
            frameQueue.pop_back();
            queuedTokens.pop_back();
            abandonFrameLocked(f, 5);
            pthread_mutex_unlock(&lock);
            fail("Could not start the presenter thread.");
        }
        presenterRunning = true;
    }
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    return {t, pending, (double)frameStoreLimit};
}

// What became of the frames queued since the last report. With wait, every one
// of them first: until it is shown or dropped, or two seconds past the last. A
// frame is forgotten only once its outcome has been reported: one still pending
// after that wait is reported as pending (status 2) and again by the next call.
// One the display has said nothing of PM_QUEUE_LOST seconds after its time is
// reported as pending one last time, so that it cannot hold up every later wait.
static std::vector<pm::QueuedFrame> queueResults(bool wait) {
    if (!device || closing) fail("PsychMetal is not open.");
    std::vector<pm::QueuedFrame> out;
    pthread_mutex_lock(&lock);
    if (wait) {
        double last = CACurrentMediaTime();
        for (uint64_t t : queuedTokens) {
            Record *r = recordFor(t);
            if (r && isfinite(r->requestedTime)) last = fmax(last, r->requestedTime);
        }
        double deadline = last + 2.0;
        for (;;) {
            bool pending = false;
            for (uint64_t t : queuedTokens) {
                Record *r = recordFor(t);
                if (r && !r->done) { pending = true; break; }
            }
            if (!pending || closing) break;
            if (waitRelative(deadline) == ETIMEDOUT && CACurrentMediaTime() >= deadline) break;
        }
    }
    std::vector<uint64_t> unfinished;
    for (uint64_t t : queuedTokens) {
        Record *r = recordFor(t);
        if (!r) continue;                       // overwritten: more than NREC frames ago
        if (!r->done) {
            const bool lost = CACurrentMediaTime() >= r->requestedTime + PM_QUEUE_LOST;
            if (!lost) unfinished.push_back(t);
            if (!lost && !wait) continue;
        }
        out.push_back({t, r->requestedTime, (r->done && r->status == 0 && r->presented > 0) ? r->presented : NAN,
                       r->done ? r->status : 2});
    }
    queuedTokens.swap(unfinished);
    pthread_mutex_unlock(&lock);
    return out;
}

static uint64_t queueCancel(void) {
    if (!device || closing) fail("PsychMetal is not open.");
    pthread_mutex_lock(&lock);
    uint64_t n = (uint64_t)frameQueue.size();
    for (const PMQueuedFrame &f : frameQueue) abandonFrameLocked(f, 5);
    frameQueue.clear();
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);
    return n;
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
    if(directWaitForConfirm && !out.done) fail("Timed out waiting for presentation confirmation.");
    return out;
}
static void drainRecords(void) {
    pthread_mutex_lock(&lock);
    drainLocked();
    pthread_mutex_unlock(&lock);
}
static std::vector<pm::FrameRecord> historyRecords(size_t limit = NREC) {
    std::vector<Record> snapshot;
    pthread_mutex_lock(&lock);
    uint64_t end = nextToken;
    uint64_t start = std::max(firstSessionToken, (end > NREC) ? end - NREC : 1);
    start = std::max(start, end > limit ? end - limit : uint64_t(1));
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

#if PM_IOS
#include "PsychMetalIOS.h"
#endif

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
#if PM_IOS
    // The app's own loop runs the main thread here; this only lets it turn.
    @autoreleasepool {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    }
#else
    @autoreleasepool {
        deliverAppKitEvents([NSDate dateWithTimeIntervalSinceNow:seconds]);
    }
#endif
}

// --- session lifecycle ------------------------------------------------------

const char *pm::version() noexcept { return pm::kEngineVersion; }
pm::EnvironmentInfo pm::environment() { @autoreleasepool {
    pm::EnvironmentInfo result;
    result.engineVersion=pm::version();
#if PM_IOS
    result.platform="iOS";
#else
    result.platform="macOS";
#endif
    result.osVersion=NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String;
    id<MTLDevice> selected=device ? device : MTLCreateSystemDefaultDevice();
    result.gpuAvailable=selected!=nil;
    result.gpuName=selected ? selected.name.UTF8String : "";
    return result;
} }
bool pm::defaultDisplayLink() noexcept {
#if PM_IOS
    if (@available(iOS 17.0, *)) return true;
#endif
    return false;
}

void pm::prepareApp() { @autoreleasepool { ::prepareApp(); } }

pm::OpenResult pm::openSession(const pm::OpenOptions &o) {
    @autoreleasepool {
        if (o.displayLink && !o.displaySync) fail("Display-link presentation requires displaySync.");
        if (o.displayLink) {
            if (@available(macOS 14.0, iOS 17.0, *)) {} else
                fail("Display-link presentation requires macOS 14 or iOS 17 or later.");
        }
        double screenIndex = o.screenIndex;
        if (screenIndex != floor(screenIndex) || screenIndex < -1)
            fail("screen index must be a non-negative integer, or -1 for the last display.");
        if (o.drawableCount > 3)
            fail("maximum drawable count must be a nonnegative integer in range.");
        if (o.drawableCount < 2)
            fail("Drawable count must be 2 or 3.");
        if (o.bitDepth != 8 && o.bitDepth != 10)
            fail("Bit depth must be 8 or 10.");

#if PM_IOS
        if (pthread_main_np())
            fail("On this device the main thread belongs to the app: run the experiment on a thread of its own.");
        // The device's own screen, as the app holds it now. An external display is
        // not supported yet.
        if (screenIndex < 0)
            screenIndex = 0;
        if (screenIndex >= 1)
            failWith(pm::kErrScreen, "Screen index %d is out of range; %u display(s) are active.",
                     (int)screenIndex, 1u);
        if (o.bitDepth != 8)
            fail("10-bit frames are not available on this device yet.");
        uint32_t requestedDisplay=0;
        const PMScreen screen = iosScreen();
        CGRect b = CGRectMake(0, 0, screen.pointWidth, screen.pointHeight);
        size_t pxW = screen.pixelWidth, pxH = screen.pixelHeight;
        double hz = screen.refreshHz;
#else
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
        uint32_t requestedDisplay=did;
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
#endif
        if (!(hz > 0.0) && !o.refreshHz) {
            hookWarn(pm::kWarnRefresh, "Display does not report a fixed refresh rate. Using provisional 60 Hz; set a fixed display mode and supply OpenWindow refreshHz for timing work.");
            hz = 60.0;
        }
        if (o.refreshHz) {
            double overrideHz = *o.refreshHz;
            if (!std::isfinite(overrideHz) || overrideHz < 20 || overrideHz > 1000) fail("refreshHz must be 20..1000.");
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
                 o.readback, (int)o.bitDepth, o.displayLink, requestedDisplay);
        if (o.displayLink) {
            if (@available(macOS 14.0, iOS 17.0, *)) {
                displayDriver = [[PMDisplayDriver alloc] initWithLayer:layer refresh:hz];
                if (!displayDriver) { closeCore(); fail("Could not start the Metal display-link thread."); }
                displayLinkPresentation = true;
            }
        }
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
        lastFlipToken = token;      // before anything can throw: flipStatus is then about this frame
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

pm::FlipStatus pm::flipStatus() {
    if (!device || closing) fail("PsychMetal is not open.");
    pthread_mutex_lock(&lock);
    const Record *r = lastFlipToken ? recordFor(lastFlipToken) : nullptr;
    pm::FlipStatus out = {r && r->done && r->status == 0 && r->presented > 0,
                          r && r->done && r->status == 1, missingPresentedCount};
    pthread_mutex_unlock(&lock);
    return out;
}

pm::QueueResult pm::queueFlip(double when) { @autoreleasepool { return ::queueFrame(when); } }

std::vector<pm::QueuedFrame> pm::queueResults(bool wait) { return ::queueResults(wait); }

uint64_t pm::queueCancel() { return ::queueCancel(); }

uint64_t pm::prepareFlip() { @autoreleasepool { return ::prepareFlip(); } }

pm::PresentResult pm::presentNow() {
    @autoreleasepool { return ::presentNow(); }
}

void pm::setDisplaySync(bool enabled) {
    if(displayLinkPresentation && !enabled) fail("Display-link presentation requires displaySync.");
    if (!layer) fail("PsychMetal is not open.");
#if PM_IOS
    if (!enabled) fail("Presentation cannot be unsynchronized from the display on this device.");
#else
    @autoreleasepool {
        __block BOOL on = enabled ? YES : NO;
        onMainSync(^{ layer.displaySyncEnabled = on; });
    }
#endif
    pthread_mutex_lock(&lock);
    displaySync = enabled;
    pthread_mutex_unlock(&lock);
}

void pm::setPrefetchDrawable(bool enabled) {
    if(displayLinkPresentation && enabled) fail("Drawable prefetch is owned by the display link in this mode.");
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
    double value;
    memcpy(&value,(const unsigned char *)v.data + (ptrdiff_t)i * v.strides[0] +
           (ptrdiff_t)j * v.strides[1],sizeof(value));
    return value; // buffer views may be strided or unaligned
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
        item->blend = blendMode;
        memcpy(item->clip, clipRect, sizeof(item->clip));
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
    if(userTextures[slot]->offscreen) fail("That is an offscreen window; draw into it instead.");
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
    if (targetTexture)
        for (size_t k = 0; k < n; k++)
            if (userTextures[slots[k]] == targetTexture)
                fail("An offscreen window cannot be drawn into itself.");
    for (size_t k = 0; k < n; k++)
        drawTextureRefs[drawCount + k] = userTextures[slots[k]];
    pthread_mutex_lock(&lock);
    for (size_t k = 0; k < n; k++) {
        PMDrawItem *item = &drawList[drawCount++];
        memset(item, 0, sizeof(*item));
        item->type = PM_ITEM_TEXTURE;
        item->texIndex = slots[k];
        item->blend = blendMode;
        memcpy(item->clip, clipRect, sizeof(item->clip));
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

void pm::updateTextureRegion(uint64_t handle, const pm::ArrayView &image, double x, double y) {
    if(!device || closing) fail("PsychMetal is not open.");
    int slot=textureSlot(handle);
    PMTextureRef texture=userTextures[slot];
    if(texture->offscreen) fail("That is an offscreen window; draw into it instead.");
    const bool bytes=pm::internal::isByteImage(image);
    pm::internal::ImageShape shape;
    const void *texels;
    if(bytes) texels=pm::internal::packBytes(image,byteScratch,shape);
    else { shape=pm::internal::packImage(image,uploadScratch); texels=uploadScratch.data(); }
    if(bytes!=texture->bytes || shape.channels!=texture->channels)
        fail("A partial update must have the texture's type (uint8 or logical, or float) and channel count.");
    if(!(x>=0 && y>=0) || x!=floor(x) || y!=floor(y) ||
       x+(double)shape.width>(double)texture->width || y+(double)shape.height>(double)texture->height)
        fail("A partial update must lie inside the texture, at whole pixels.");
    for(NSUInteger i=0;i<drawCount;i++)
        if(drawTextureRefs[i]==texture || drawCoverageRefs[i]==texture)
            fail("The texture is in a frame that is queued; Flip before a partial update.");
    // In place, so nothing else may still be reading it: wait for the frames that
    // drew it. Idle, it is held by its slot, its pool and the copy here.
    pthread_mutex_lock(&lock);
    double deadline=CACurrentMediaTime()+2.0;
    while(texture.use_count()>3) {
        double step=std::min(deadline,CACurrentMediaTime()+0.0005);
        waitRelative(step);
        if(CACurrentMediaTime()>=deadline) break;
    }
    bool idle=texture.use_count()<=3;
    pthread_mutex_unlock(&lock);
    if(!idle) fail("Timed out waiting for frames that draw this texture; Flip before a partial update.");
    double began=CACurrentMediaTime();
    size_t c=shape.channels;
    @autoreleasepool {
        [texture->texture replaceRegion:MTLRegionMake2D((NSUInteger)x,(NSUInteger)y,shape.width,shape.height)
            mipmapLevel:0 withBytes:texels
            bytesPerRow:shape.width*(c==1?1:4)*(bytes?sizeof(uint8_t):sizeof(__fp16))];
    }
    cpuUploadMs=(CACurrentMediaTime()-began)*1000;
    textureUpdates++;
}

void pm::closeTexture(uint64_t handle) {
    int slot = textureSlot(handle);
    if (handle == targetHandle) {
        // Its waiting draws go with it, and drawing returns to the window.
        for (NSUInteger i = targetBase; i < drawCount; i++) {drawTextureRefs[i].reset();drawCoverageRefs[i].reset();drawShaderRefs[i].reset();}
        pthread_mutex_lock(&lock);
        drawCount = targetBase;
        pthread_mutex_unlock(&lock);
        targetTexture.reset(); targetHandle = 0; targetBase = 0;
    }
    userTextures[slot].reset(); texturePools[slot].clear(); textureHandles[slot]=0;
}

void pm::setBlendMode(uint64_t mode) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (mode >= PM_BLEND_COUNT) fail("Blend mode must be 0 (source-over), 1 (additive) or 2 (copy).");
    blendMode = (uint32_t)mode;
}

void pm::setClip(const std::optional<pm::Rect4> &rect) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (!rect) { memset(clipRect, 0, sizeof(clipRect)); return; }
    const pm::Rect4 &r = *rect;
    for (double v : r)
        if (!isfinite(v) || v != floor(v) || fabs(v) > 1e6)
            fail("The clip rect must be [left top right bottom] in whole pixels.");
    if (!(r[2] > r[0] && r[3] > r[1]))
        fail("The clip rect must be [left top right bottom] in whole pixels.");
    for (int i = 0; i < 4; i++) clipRect[i] = (int32_t)r[(size_t)i];
}

// --- offscreen windows --------------------------------------------------------------

uint64_t pm::openOffscreen(double width, double height, const pm::Rect4 &rgba) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (!(width >= 1 && width <= 16384 && height >= 1 && height <= 16384) ||
        width != floor(width) || height != floor(height))
        fail("An offscreen window is 1 to 16384 whole pixels each way.");
    for (double v : rgba)
        if (!(v >= 0.0 && v <= 1.0)) fail("Offscreen window colour components run 0 to 1.");
    int slot = -1;
    for (int i = 0; i < PM_MAX_TEXTURES; i++) if (!userTextures[i]) { slot = i; break; }
    if (slot < 0) fail("No free texture slots.");
    if (nextTextureHandle >= PM_MAX_ID) fail("Texture handle space exhausted.");
    @autoreleasepool {
        ensureTargetPipelines(PM_TARGET_OFFSCREEN);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
            width:(NSUInteger)width height:(NSUInteger)height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        if (!texture) fail("Could not allocate the offscreen window.");
        // Its first contents: the colour it was opened with, multiplied by its alpha
        // as everything an offscreen window holds is.
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor =
            MTLClearColorMake(rgba[0] * rgba[3], rgba[1] * rgba[3], rgba[2] * rgba[3], rgba[3]);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> re = cb ? [cb renderCommandEncoderWithDescriptor:pass] : nil;
        if (!re) fail("Could not clear the offscreen window.");
        [re endEncoding];
        watchRender(cb, 0);
        [cb commit];
        auto resource = std::make_shared<PMTextureResource>();
        resource->texture = texture;
        resource->width = (size_t)width; resource->height = (size_t)height; resource->channels = 4;
        resource->bytes = false;
        resource->offscreen = true;
        userTextures[slot] = resource;
        textureAllocations++;
    }
    textureHandles[slot] = nextTextureHandle++;
    texturesCreated++;
    return textureHandles[slot];
}

void pm::setTarget(uint64_t handle) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (handle == targetHandle)
        return;
    PMTextureRef next;
    if (handle) {
        next = userTextures[textureSlot(handle)];
        if (!next->offscreen) fail("That texture is not an offscreen window.");
        // The window's waiting draws would show what is drawn into it now, not what it held.
        for (NSUInteger i = 0, end = targetTexture ? targetBase : drawCount; i < end; i++)
            if (drawTextureRefs[i] == next || drawCoverageRefs[i] == next)
                fail("The window has draws of that offscreen window waiting; Flip before drawing into it again.");
    }
    @autoreleasepool { flushTarget(); }
    targetTexture = next;
    targetHandle = handle;
    targetBase = handle ? drawCount : 0;
}

// --- linearization ------------------------------------------------------------

void pm::setGamma(double r, double g, double b) {
    if (!device || closing) fail("PsychMetal is not open.");
    const double v[3] = {r, g, b};
    for (double e : v)
        if (!(e >= 0.05 && e <= 20.0)) fail("Gamma exponents must be 0.05 to 20.");
    if (r == 1 && g == 1 && b == 1) {
        encodeMode = PM_ENCODE_NONE;
        return;
    }
    @autoreleasepool { ensureLinearResources(); }
    for (int i = 0; i < 3; i++) encodeExponent[i] = (float)v[i];
    encodeMode = PM_ENCODE_POWER;
}

void pm::setGammaTable(const pm::ArrayView &table) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (table.type != pm::ScalarType::Float64 || table.ndim != 2 || table.shape[1] != 3 ||
        table.shape[0] < 2 || table.shape[0] > 4096)
        fail("The gamma table must be Nx3 real doubles, N from 2 to 4096.");
    size_t n = table.shape[0];
    // 32-bit floats, read texel by texel and interpolated in the shader, so the
    // table is exact for a 10-bit frame and needs no filterable format.
    std::vector<float> texels(n * 4);
    for (size_t i = 0; i < n; i++) {
        for (size_t c = 0; c < 3; c++) {
            double v = viewAt(table, i, c);
            if (!(v >= 0.0 && v <= 1.0)) fail("Gamma table values run 0 to 1.");
            texels[i * 4 + c] = (float)v;
        }
        texels[i * 4 + 3] = 1.0f;
    }
    @autoreleasepool {
        ensureLinearResources();
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
            width:n height:1 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> lut = [device newTextureWithDescriptor:td];
        if (!lut) fail("Could not allocate the gamma table texture.");
        [lut replaceRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0
                 withBytes:texels.data() bytesPerRow:n * 4 * sizeof(float)];
        // A new texture each time: a frame in flight keeps the table it was encoded with.
        encodeTable = lut;
        encodeTableSize = n;
    }
    encodeMode = PM_ENCODE_TABLE;
}

// --- text -----------------------------------------------------------------------

// A coverage mask as an R8 texture.
static PMTextureRef makeMaskTexture(const std::vector<uint8_t> &coverage, size_t w, size_t h) {
    @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
            width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        if (!texture) fail("Could not allocate a coverage mask texture.");
        [texture replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:coverage.data() bytesPerRow:w];
        auto mask = std::make_shared<PMTextureResource>();
        mask->texture = texture;
        mask->width = w; mask->height = h; mask->channels = 1; mask->bytes = true;
        return mask;
    }
}
// The masks kept: at most 256 of them and 256 MB. When a new one does not fit,
// the ones wanted longest ago go first, so text that is drawn on every frame
// stays while text that changes passes through. Queued draws hold their own
// references. A mask over 64 MB is not kept.
#define PM_MASK_COUNT 256
#define PM_MASK_BYTES ((size_t)256 << 20)
#define PM_MASK_LARGEST ((size_t)64 << 20)
// A kept mask, marked as wanted now; or none.
static PMMask *findMask(const std::string &key) {
    auto found = maskCache.find(key);
    if (found == maskCache.end()) return nullptr;
    found->second.used = ++maskUses;
    return &found->second;
}
// Keep a mask that was just made, for the next time it is wanted.
static const PMMask &keepMask(const std::string &key, const PMMask &made) {
    size_t bytes = made.mask->width * made.mask->height;
    if (bytes > PM_MASK_LARGEST) { unkeptMask = made; return unkeptMask; }
    while (!maskCache.empty() && (maskCache.size() >= PM_MASK_COUNT || maskCacheBytes + bytes > PM_MASK_BYTES)) {
        auto oldest = maskCache.begin();
        for (auto it = maskCache.begin(); it != maskCache.end(); ++it)
            if (it->second.used < oldest->second.used) oldest = it;
        maskCacheBytes -= oldest->second.mask->width * oldest->second.mask->height;
        maskCache.erase(oldest);
    }
    maskCacheBytes += bytes;
    PMMask &kept = maskCache[key];
    kept = made;
    kept.used = ++maskUses;
    return kept;
}
// Queue a mask with its top left at a whole pixel, in a colour.
static void queueMask(const PMMask &made, double left, double top, const pm::Rect4 &rgba) {
    if (drawCount >= PM_MAX_SHAPES) fail("Frame draw capacity exceeded; split the work across frames.");
    drawTextureRefs[drawCount] = made.mask;
    pthread_mutex_lock(&lock);
    PMDrawItem *item = &drawList[drawCount++];
    memset(item, 0, sizeof(*item));
    item->type = PM_ITEM_TEXTURE;
    item->texIndex = -1;
    item->blend = blendMode;
    memcpy(item->clip, clipRect, sizeof(item->clip));
    item->mask = 1;
    item->src[2] = item->src[3] = 1.0f;
    item->dst[0] = (float)left; item->dst[1] = (float)top;
    item->dst[2] = (float)(left + made.width); item->dst[3] = (float)(top + made.height);
    for (int c = 0; c < 4; c++) item->tint[c] = (float)rgba[(size_t)c];
    pthread_mutex_unlock(&lock);
}

// One line of text as CoreText lays it out, and the mask that will hold it: one
// pixel of margin all round, for antialiased edges, and the baseline on a pixel
// boundary, so horizontal strokes stay sharp. The caller releases the line.
struct PMTextLine { CTLineRef line; double wide, high, above, below; };
static std::string textKey(const std::string &utf8, const std::string &fontName, double size) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (!(size >= 4 && size <= 2048)) fail("Text size must be 4 to 2048 pixels.");
    if (utf8.empty()) fail("Text must not be empty.");
    char sizeKey[32];
    snprintf(sizeKey, sizeof(sizeKey), "%.3f", size);
    return "text\n" + fontName + '\n' + sizeKey + '\n' + utf8;
}
static PMTextLine layoutText(const std::string &utf8, const std::string &fontName, double size) {
    CFStringRef string = CFStringCreateWithCString(NULL, utf8.c_str(), kCFStringEncodingUTF8);
    if (!string) fail("Text must be valid UTF-8.");
    CFStringRef name = CFStringCreateWithCString(NULL, fontName.empty() ? "Helvetica" : fontName.c_str(),
                                                 kCFStringEncodingUTF8);
    CTFontRef font = name ? CTFontCreateWithName(name, size, NULL) : NULL;
    if (name) CFRelease(name);
    if (!font) { CFRelease(string); fail("Could not create the text font."); }
    const void *keys[] = { kCTFontAttributeName };
    const void *values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = attributes ? CFAttributedStringCreate(NULL, string, attributes) : NULL;
    CTLineRef line = attributed ? CTLineCreateWithAttributedString(attributed) : NULL;
    if (attributed) CFRelease(attributed);
    if (attributes) CFRelease(attributes);
    CFRelease(font);
    CFRelease(string);
    if (!line) fail("Could not lay out the text.");
    CGFloat ascent = 0, descent = 0, leading = 0;
    double advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    PMTextLine laid = {line, ceil(advance) + 2, 0, ceil(ascent), ceil(descent)};
    laid.high = laid.above + laid.below + 2;
    if (!(laid.wide >= 1 && laid.wide <= 16384 && laid.high >= 1 && laid.high <= 16384)) {
        CFRelease(line);
        fail("The text is too large to draw: 16384 pixels at most.");
    }
    return laid;
}
// One line, rendered by CoreText into an 8-bit coverage mask, kept in an R8 texture.
static const PMMask &textFor(const std::string &utf8, const std::string &fontName, double size) {
    std::string key = textKey(utf8, fontName, size);
    if (const PMMask *kept = findMask(key))
        return *kept;
    PMTextLine laid = layoutText(utf8, fontName, size);
    size_t w = (size_t)laid.wide, h = (size_t)laid.high;
    std::vector<uint8_t> coverage(w * h, 0);
    CGContextRef context = CGBitmapContextCreate(coverage.data(), w, h, 8, w, NULL, kCGImageAlphaOnly);
    if (!context) { CFRelease(laid.line); fail("Could not create the text bitmap."); }
    // The context's origin is its bottom left; its first row in memory is its top.
    CGContextSetTextPosition(context, 1, 1 + laid.below);
    CTLineDraw(laid.line, context);
    CGContextRelease(context);
    CFRelease(laid.line);
    PMMask text{};
    text.mask = makeMaskTexture(coverage, w, h);
    text.width = laid.wide; text.height = laid.high; text.ascent = laid.above + 1;
    return keepMask(key, text);
}

// Measuring makes no mask: a line that has been drawn is known by the mask kept
// for it, and any other is only laid out. Wrapping a paragraph measures every
// word of it, and none of those is ever drawn alone.
pm::TextBounds pm::textBounds(const std::string &utf8, const std::string &font, double size) {
    if (const PMMask *kept = findMask(textKey(utf8, font, size)))
        return {kept->width, kept->height, kept->ascent};
    PMTextLine laid = layoutText(utf8, font, size);
    CFRelease(laid.line);
    return {laid.wide, laid.high, laid.above + 1};
}

pm::TextBounds pm::drawText(const std::string &utf8, const std::string &font, double size, double x, double y,
                            const pm::Rect4 &rgba) {
    if (!isfinite(x) || !isfinite(y) || fabs(x) > FLT_MAX || fabs(y) > FLT_MAX)
        fail("Text position must be finite.");
    for (double v : rgba)
        if (!(v >= 0.0 && v <= 1.0)) fail("Text colour components run 0 to 1.");
    const PMMask &text = textFor(utf8, font, size);
    // Whole pixels, so the mask's texels land on the display's.
    queueMask(text, floor(x + 0.5), floor(y + 0.5), rgba);
    return {text.width, text.height, text.ascent};
}

// --- polygons ---------------------------------------------------------------------

// A polygon is rasterized by CoreGraphics into a coverage mask, as text is, so it
// is antialiased whatever its shape: filled by the even-odd rule, or its outline
// stroked `pen` pixels wide. The mask is kept by the polygon's shape, so one that
// moves by whole pixels is not rasterized again.
void pm::drawPolygon(const pm::ArrayView &points, const pm::Rect4 &rgba, double pen) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (points.type != pm::ScalarType::Float64 || points.ndim != 2 || points.shape[1] != 2 ||
        points.shape[0] < 3 || points.shape[0] > 4096)
        fail("A polygon is 3 to 4096 points, as Nx2 real doubles.");
    if (!(pen >= 0 && pen <= 1024)) fail("The polygon pen width must be 0 (filled) to 1024 pixels.");
    for (double v : rgba)
        if (!(v >= 0.0 && v <= 1.0)) fail("Polygon colour components run 0 to 1.");
    size_t n = points.shape[0];
    double lo[2] = {INFINITY, INFINITY}, hi[2] = {-INFINITY, -INFINITY};
    for (size_t i = 0; i < n; i++)
        for (size_t c = 0; c < 2; c++) {
            double v = viewAt(points, i, c);
            if (!isfinite(v) || fabs(v) > 1e6) fail("Polygon points must be finite, in pixels.");
            lo[c] = fmin(lo[c], v); hi[c] = fmax(hi[c], v);
        }
    // The mask covers the polygon, the half pen outside it and a mitred corner's
    // reach, with a pixel to spare; its top left is a whole pixel.
    double margin = 1 + ceil(pen * 5);
    double left = floor(lo[0]) - margin, top = floor(lo[1]) - margin;
    double wide = ceil(hi[0]) + margin - left, high = ceil(hi[1]) + margin - top;
    if (!(wide <= 16384 && high <= 16384))
        fail("The polygon is too large to draw: 16384 pixels at most.");
    std::vector<double> local(n * 2);
    // On a grid of 1/256 pixel, so the same shape somewhere else is the same key.
    for (size_t i = 0; i < n; i++) {
        local[i * 2] = round((viewAt(points, i, 0) - left) * 256) / 256;
        local[i * 2 + 1] = round((viewAt(points, i, 1) - top) * 256) / 256;
    }
    std::string key = "polygon\n";
    key.append((const char *)&pen, sizeof(pen));
    key.append((const char *)local.data(), local.size() * sizeof(double));
    if (const PMMask *kept = findMask(key)) {
        queueMask(*kept, left, top, rgba);
        return;
    }
    size_t w = (size_t)wide, h = (size_t)high;
    std::vector<uint8_t> coverage(w * h, 0);
    CGContextRef context = CGBitmapContextCreate(coverage.data(), w, h, 8, w, NULL, kCGImageAlphaOnly);
    if (!context) fail("Could not create the polygon bitmap.");
    // The context's origin is its bottom left and its first row in memory is its
    // top, so y is turned over to run downward as window pixels do.
    CGContextTranslateCTM(context, 0, (CGFloat)h);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetShouldAntialias(context, true);
    CGContextSetGrayFillColor(context, 0, 1);
    CGContextSetGrayStrokeColor(context, 0, 1);
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, (CGFloat)local[0], (CGFloat)local[1]);
    for (size_t i = 1; i < n; i++)
        CGContextAddLineToPoint(context, (CGFloat)local[i * 2], (CGFloat)local[i * 2 + 1]);
    CGContextClosePath(context);
    if (pen > 0) {
        CGContextSetLineWidth(context, (CGFloat)pen);
        CGContextSetLineJoin(context, kCGLineJoinMiter);
        CGContextSetMiterLimit(context, 10);
        CGContextStrokePath(context);
    } else {
        CGContextEOFillPath(context);
    }
    CGContextRelease(context);
    PMMask made{};
    made.mask = makeMaskTexture(coverage, w, h);
    made.width = wide; made.height = high; made.ascent = 0;
    queueMask(keepMask(key, made), left, top, rgba);
}

pm::ImageRegion pm::checkImageRect(const std::optional<pm::Rect4> &rect) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (!captureBuffer) fail("GetImage requires a window opened with readback.");
    if (!rect) return {0, 0, (size_t)renderWidth, (size_t)renderHeight, outputBits};
    const pm::Rect4 &r = *rect;
    for (double v : r)
        if (!isfinite(v) || v != floor(v))
            fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    if (r[0] < 0 || r[1] < 0 || r[2] <= r[0] || r[3] <= r[1] ||
        r[2] > (double)renderWidth || r[3] > (double)renderHeight)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    return {(size_t)r[0], (size_t)r[1], (size_t)(r[2] - r[0]), (size_t)(r[3] - r[1]), outputBits};
}

// Wait for the GPU to finish writing the newest frame. Never return stale pixels.
static void readCapture(const pm::ImageRegion &g) {
    if (!device || closing) fail("PsychMetal is not open.");
    if (!captureBuffer) fail("GetImage requires a window opened with readback.");
    if (!g.width || !g.height || g.x > (size_t)renderWidth || g.y > (size_t)renderHeight ||
        g.width > (size_t)renderWidth - g.x || g.height > (size_t)renderHeight - g.y)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    pthread_mutex_lock(&lock);
    uint64_t token = captureToken;
    // Tokens are issued in order by Flip and PrepareFlip, so the newest one is
    // nextToken - 1. A frame with no drawable or a failed encoding was never
    // copied, and an older copy must not be passed off as that frame.
    if (!token || token != nextToken - 1) {
        pthread_mutex_unlock(&lock);
        fail(token ? "The last frame was not copied; there is nothing to read."
                   : "GetImage needs a frame; Flip first.");
    }
    double deadline = CACurrentMediaTime() + 2.0;
    Record *r = recordFor(token);
    // A queued frame is copied when it is rendered, long before it is shown, and
    // cancelling it marks it done at once: only its render says the copy is there.
    auto ready = [](const Record *q) { return q->queued ? q->renderDone != 0 : q->gpuDone != 0; };
    while (r && !ready(r)) {
        if (waitRelative(deadline) == ETIMEDOUT) break;
        r = recordFor(token);
    }
    bool rendered = r && ready(r), failed = r && r->status == 3;
    pthread_mutex_unlock(&lock);
    if (!rendered) fail("Timed out waiting for the frame to render.");
    if (failed) fail("GPU command or frame encoding failed.");

}

void pm::getImage(const pm::ImageRegion &g, const pm::MutableByteView &out) {
    if (outputBits != 8) fail("This window is 10-bit; its frames are read as 16-bit values.");
    if (!out.data || out.ndim != 3 || out.shape[0] != g.height || out.shape[1] != g.width || out.shape[2] != 3)
        fail("Image output buffer does not match the request.");
    readCapture(g);
    const uint8_t *src = (const uint8_t *)captureBuffer.contents + g.y * capturePitch + g.x * 4;
    pm::internal::unpackReadback8(src, capturePitch, out);
}

void pm::getImage16(const pm::ImageRegion &g, const pm::MutableWordView &out) {
    if (outputBits != 10) fail("This window is 8-bit; its frames are read as bytes.");
    if (!out.data || out.ndim != 3 || out.shape[0] != g.height || out.shape[1] != g.width || out.shape[2] != 3)
        fail("Image output buffer does not match the request.");
    readCapture(g);
    const uint8_t *src = (const uint8_t *)captureBuffer.contents + g.y * capturePitch + g.x * 4;
    pm::internal::unpackReadback10(src, capturePitch, out);
}

#if !PM_IOS
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
            if (!(hz > 0.0) || !std::isfinite(hz)) hz = 0.0;
            out.push_back({(double)CGDisplayModeGetWidth(m), (double)CGDisplayModeGetHeight(m),
                           (double)CGDisplayModeGetPixelWidth(m), (double)CGDisplayModeGetPixelHeight(m), hz});
        }
    }
    if (cur) CGDisplayModeRelease(cur);
    CFRelease(all);
    return out;
}

void pm::setMode(double screenIndex, double wantW, double wantH, double refreshHz) {
    if (device) fail("Close the PsychMetal window before changing the display mode.");
    CGDirectDisplayID did = displayForIndex(screenIndex);
    CFArrayRef all = copyAllModes(did);
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(did);
    std::vector<pm::DisplayMode> options;
    size_t currentIndex=(size_t)CFArrayGetCount(all);
    for (CFIndex i=0;i<CFArrayGetCount(all);i++) {
        CGDisplayModeRef m=(CGDisplayModeRef)CFArrayGetValueAtIndex(all,i);
        if (current && CFEqual(m,current)) currentIndex=(size_t)i;
        options.push_back({(double)CGDisplayModeGetWidth(m),(double)CGDisplayModeGetHeight(m),
                           (double)CGDisplayModeGetPixelWidth(m),(double)CGDisplayModeGetPixelHeight(m),
                           CGDisplayModeGetRefreshRate(m)});
    }
    if (current) CGDisplayModeRelease(current);
    size_t best;
    try { best=pm::internal::selectDisplayMode(options,currentIndex,wantW,wantH,refreshHz); }
    catch (...) { CFRelease(all); throw; }
    if (best==options.size()) {
        CFRelease(all);
        failWith(pm::kErrMode, "No matching display mode for %g x %g points and refreshHz %g (0 means unspecified).",wantW,wantH,refreshHz);
    }
    CGError e = CGDisplaySetDisplayMode(did,(CGDisplayModeRef)CFArrayGetValueAtIndex(all,(CFIndex)best),NULL);
    CFRelease(all);
    if (e != kCGErrorSuccess) failWith(pm::kErrMode, "CGDisplaySetDisplayMode failed with error %d.",(int)e);
}

void pm::setCursorVisible(bool show) {
    CGDirectDisplayID d = selectedDisplayID ? selectedDisplayID : CGMainDisplayID();
    if (show)
        CGDisplayShowCursor(d);
    else
        CGDisplayHideCursor(d);
}

// --- display link -------------------------------------------------------------

static double numberValue(CFTypeRef value) {
    double v = NAN;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &v);
    return v;
}

// The signalling rate per lane, in Hz. The registry holds it as a collection with
// one member (a set on the systems seen, shown by ioreg in brackets), and as a
// description that starts with the rate in Gbit/s, such as "5.4 Gbps (HBR2)".
static double signalingRate(CFDictionaryRef p) {
    CFTypeRef rates = CFDictionaryGetValue(p, CFSTR("NominalSignalingFrequenciesHz"));
    const void *only = NULL;
    if (rates && CFGetTypeID(rates) == CFSetGetTypeID() && CFSetGetCount((CFSetRef)rates) == 1)
        CFSetGetValues((CFSetRef)rates, &only);
    else if (rates && CFGetTypeID(rates) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)rates) == 1)
        only = CFArrayGetValueAtIndex((CFArrayRef)rates, 0);
    double rate = numberValue((CFTypeRef)only);
    if (isfinite(rate))
        return rate;
    CFTypeRef described = CFDictionaryGetValue(p, CFSTR("LinkRateDescription"));
    if (described && CFGetTypeID(described) == CFStringGetTypeID())
        rate = CFStringGetDoubleValue((CFStringRef)described) * 1e9;
    return rate > 0 ? rate : NAN;
}

// Read from the IO registry entries that describe DisplayPort transports. None of
// this is a documented interface, so every step falls back to "unknown".
pm::LinkInfo pm::linkInfo() {
    if (!device || closing) fail("LinkInfo requires an open PsychMetal window.");
    pm::LinkInfo info{NAN, NAN, NAN, NAN, NAN};
    info.pixelGbps = (double)renderWidth * (double)renderHeight * (3.0 * outputBits) / ifi / 1e9;
    const CGDirectDisplayID display = selectedDisplayID ? selectedDisplayID : CGMainDisplayID();
    const double model = (double)CGDisplayModelNumber(display);
    const double serial = (double)CGDisplaySerialNumber(display);
    uint32_t displays = 0;
    CGGetActiveDisplayList(0, NULL, &displays);
    double matchedLanes = 0, matchedRate = NAN, matchedPayload = 0;
    double modelLanes = 0, modelRate = NAN, modelPayload = 0;
    double activeLanes = 0, activeRate = NAN, activePayload = 0;
    int matched = 0, sameModel = 0, active = 0, entries = 0;
    // First by service matching; if that finds no such entries, by walking the
    // registry, which also reaches entries that are not registered services.
    for (int walk = 0; walk < 2 && !entries; walk++) {
        io_iterator_t iterator = 0;
        if (walk) {
            if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, kIORegistryIterateRecursively,
                                         &iterator) != KERN_SUCCESS)
                break;
        } else {
            CFMutableDictionaryRef matching = IOServiceMatching("IOPortTransportStateDisplayPort");
            if (!matching || IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS)
                continue;
        }
        for (io_object_t entry; (entry = IOIteratorNext(iterator)); IOObjectRelease(entry)) {
            if (!IOObjectConformsTo(entry, "IOPortTransportStateDisplayPort"))
                continue;
            entries++;
            CFMutableDictionaryRef properties = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &properties, NULL, 0) != KERN_SUCCESS || !properties)
                continue;
            CFDictionaryRef p = (CFDictionaryRef)properties;
            CFTypeRef isActive = CFDictionaryGetValue(p, CFSTR("Active"));
            double lanes = numberValue(CFDictionaryGetValue(p, CFSTR("LaneCount")));
            double rate = signalingRate(p);
            if (isActive == kCFBooleanTrue && lanes >= 1 && lanes <= 4 && rate >= 1e9 && rate <= 40e9) {
                // 8b/10b line coding up to HBR3; 128b/132b above it.
                double payload = lanes * rate * (rate <= 8.1e9 ? 0.8 : 128.0 / 132.0);
                active++; activeLanes += lanes; activeRate = rate; activePayload += payload;
                CFTypeRef metadata = CFDictionaryGetValue(p, CFSTR("Metadata"));
                if (metadata && CFGetTypeID(metadata) == CFDictionaryGetTypeID()) {
                    double product = numberValue(CFDictionaryGetValue((CFDictionaryRef)metadata, CFSTR("ProductID")));
                    double number = numberValue(CFDictionaryGetValue((CFDictionaryRef)metadata, CFSTR("SerialNumber")));
                    if (product == model) {
                        sameModel++; modelLanes = lanes; modelRate = rate; modelPayload = payload;
                    }
                    if (product == model && (serial == 0 || number == serial)) {
                        matched++; matchedLanes += lanes; matchedRate = rate; matchedPayload += payload;
                    }
                }
            }
            CFRelease(properties);
        }
        IOObjectRelease(iterator);
    }
    // The transport that names this display by model and serial number; or the
    // only one to a display of this model; or, with one display and one active
    // transport, that one.
    if (matched) {
        info.lanes = matchedLanes; info.laneGbps = matchedRate / 1e9; info.payloadGbps = matchedPayload / 1e9;
    } else if (sameModel == 1) {
        info.lanes = modelLanes; info.laneGbps = modelRate / 1e9; info.payloadGbps = modelPayload / 1e9;
    } else if (active == 1 && displays == 1) {
        info.lanes = activeLanes; info.laneGbps = activeRate / 1e9; info.payloadGbps = activePayload / 1e9;
    } else {
        return info;
    }
    // Certainly compressed if the link cannot carry even the visible pixels at 8
    // bits per channel; uncompressed with room for blanking at 10 bits if it can
    // carry a quarter more than those. Between the two it cannot be told.
    double least = (double)renderWidth * (double)renderHeight * 24.0 / ifi / 1e9;
    double ample = (double)renderWidth * (double)renderHeight * 30.0 * 1.25 / ifi / 1e9;
    if (info.payloadGbps < least) info.compressed = 1;
    else if (info.payloadGbps >= ample) info.compressed = 0;
    return info;
}

// --- input ------------------------------------------------------------------

// Fingers on the trackpad. The first call starts listening and returns nothing.
// Where the experiment runs on the main thread (Octave, or Python without a
// thread of its own) nothing else delivers the events that carry them, so this
// does.
pm::TouchEvents pm::touchEvents() {
    if (!device || closing || !metalWindow) fail("TouchEvents requires an open PsychMetal window.");
    if (!trackpadListening) {
        {
            std::lock_guard<std::mutex> guard(trackpadLock);
            touchRing.clear();
            for (int k = 0; k < PM_FINGERS; k++) trackpadFinger[k] = nil;
        }
        onMainSync(^{ metalWindow.contentView.allowedTouchTypes = NSTouchTypeMaskIndirect; });
        trackpadListening = true;
        return {};
    }
    if (pthread_main_np())
        @autoreleasepool { deliverAppKitEvents([NSDate distantPast]); }
    std::lock_guard<std::mutex> guard(trackpadLock);
    return touchRing.take();
}

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

void pm::setMouse(double x, double y) {
    if (!metalWindow || !selectedDisplayID || !renderWidth || !renderHeight)
        fail("SetMouse requires an open PsychMetal window.");
    if (!(x >= 0 && x <= (double)renderWidth && y >= 0 && y <= (double)renderHeight))
        fail("SetMouse position must be inside the window, in pixels.");
    CGRect b = CGDisplayBounds(selectedDisplayID);
    if (!(b.size.width > 0) || !(b.size.height > 0))
        fail("Could not read the presentation display bounds.");
    CGPoint p = {b.origin.x + x * b.size.width / (double)renderWidth,
                 b.origin.y + y * b.size.height / (double)renderHeight};
    if (CGWarpMouseCursorPosition(p) != kCGErrorSuccess)
        fail("Could not move the mouse cursor.");
    // After a warp the system ignores mouse movement for a quarter of a second
    // unless the mouse and the cursor are associated again.
    CGAssociateMouseAndMouseCursorPosition(true);
}
#endif

pm::KbQueueStatus pm::kbQueueStatus() {
    auto state=keyboardQueue.stats();
    double pid=0;
#if !PM_IOS
    CFDictionaryRef sess=CGSessionCopyCurrentDictionary();
    if(sess) { CFTypeRef value=CFDictionaryGetValue(sess,CFSTR("kCGSSessionSecureInputPID"));
        if(value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value,kCFNumberDoubleType,&pid);
        CFRelease(sess); }
#endif
    return {state.created, state.running, state.interval, state.lastScanInterval,
            state.maxScanInterval, (uint64_t)state.scans, (uint64_t)state.dropped, pid,
            state.events, (uint64_t)state.eventStamped, (uint64_t)state.pollStamped,
            state.maxEventDelay * 1000};
}

void pm::kbQueueCreate(const std::array<double, 256> &m, double interval) {
    bool filter[256];
    for(int k=0;k<256;k++) { if(!isfinite(m[(size_t)k])) fail("Key mask must be finite."); filter[k]=(m[(size_t)k]!=0); }
    if(interval<.001 || interval>.1) fail("Poll interval must be between .001 and .1 seconds.");
    stopKeyTap();       // creating stops a running queue
    keyboardQueue.create(filter,interval);
    if(!keyboardQueueLocked) { hookPin(); keyboardQueueLocked=true; }
}

void pm::kbQueueRelease() { releaseKeyboardQueue(); }

void pm::kbQueueStart() {
    if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
#if !PM_IOS
    uint32_t displayCount=0;
    if(CGGetActiveDisplayList(0,nullptr,&displayCount)!=kCGErrorSuccess || !displayCount)
        fail("No active desktop session for keyboard polling.");
#endif
    if(keyboardQueue.isRunning()) return;
    if(!keyboardQueue.start()) fail("Cannot start keyboard queue worker.");
    startKeyTap();
}

void pm::kbQueueStop() {
    if(!keyboardQueue.exists()) fail("Create a keyboard queue first.");
    stopKeyTap();
    keyboardQueue.stop();
}

#if !PM_IOS
// 'MouseEvents'. The first call starts listening and returns nothing.
pm::MouseEvents pm::mouseEvents() {
    if (!metalWindow || !selectedDisplayID || !renderWidth || !renderHeight)
        fail("MouseEvents requires an open PsychMetal window.");
    pm::MouseEvents out{};
    if (!mouseTap) {
        CGRect b = CGDisplayBounds(selectedDisplayID);
        if (!(b.size.width > 0) || !(b.size.height > 0))
            fail("Could not read the presentation display bounds.");
        {
            std::lock_guard<std::mutex> guard(tapLock);
            mouseOriginX = b.origin.x; mouseOriginY = b.origin.y;
            mouseScaleX = (double)renderWidth / b.size.width;
            mouseScaleY = (double)renderHeight / b.size.height;
            mouseEventHead = mouseEventCount = 0;
            mouseEventsDropped = 0;
        }
        CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                           CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                           CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);
        CFRunLoopSourceRef source = NULL;
        CFMachPortRef port = startTap(mask, mouseTapCallback, &source);
        if (!port)
            fail("The system refused a listener for mouse events. Allow this application Input Monitoring "
                 "in System Settings, Privacy & Security, or read the buttons with GetMouse.");
        std::lock_guard<std::mutex> guard(tapLock);
        mouseTap = port; mouseTapSource = source;
        return out;
    }
    std::lock_guard<std::mutex> guard(tapLock);
    out.events.reserve(mouseEventCount);
    for (unsigned i = 0; i < mouseEventCount; i++)
        out.events.push_back(mouseEventBuffer[(mouseEventHead + i) % PM_MOUSE_EVENTS]);
    out.dropped = mouseEventsDropped;
    mouseEventHead = mouseEventCount = 0;
    mouseEventsDropped = 0;
    return out;
}
#endif

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
#if !PM_IOS
    { std::lock_guard<std::mutex> guard(secureInputStateLock);
      secureActive=IsSecureEventInputEnabled()!=0; }
#endif
    out.securePid=secureActive ? -1.0 : 0.0; // -1 means active, owner not queried

    double secureMs=(CACurrentMediaTime()-secureBegan)*1000;
    keyScanMaxMs=std::max(keyScanMaxMs,scanMs);secureQueryMaxMs=std::max(secureQueryMaxMs,secureMs);
    keyScanTotalMs+=scanMs;secureQueryTotalMs+=secureMs;++keyReadCount;
    return out;
}

// --- time ---------------------------------------------------------------------

double pm::now() noexcept { return CACurrentMediaTime(); }

double pm::waitUntil(double untilTime) {
    // Shared by every thread that waits; it touches nothing else of the engine's.
    static std::atomic<double> spinMargin{0.004};
    double sleepUntilT = untilTime - spinMargin.load(std::memory_order_relaxed);
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
        double overrun = afterSleep - sleepUntilT, margin = spinMargin.load(std::memory_order_relaxed);
        if (overrun > margin * 0.5 && margin < 0.020)
            spinMargin.store(fmin(0.020, overrun * 2.0), std::memory_order_relaxed);
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
#if !PM_IOS
        d.cgDisplayID = (double)selectedDisplayID;
#endif
        d.renderWidth = (double)renderWidth;
        d.renderHeight = (double)renderHeight;
        d.drawableWidth = drawableSize.width;
        d.drawableHeight = drawableSize.height;
        d.displayCaptured = displayCaptured;
        d.readbackEnabled = captureBuffer != nil;
        double modePointWidth = NAN, modePixelWidth = NAN, nativePixelWidth = NAN;
#if PM_IOS
        if (metalWindow) {
            const PMScreen screen = iosScreen();
            modePointWidth = screen.pointWidth;
            modePixelWidth = nativePixelWidth = (double)screen.pixelWidth;
        }
#else
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
#endif
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
#if PM_IOS
        iosDescribeWindow(d);
#else
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
#endif
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

uint64_t pm::createShader(const std::string &source) {
    if(!device || closing)fail("PsychMetal is not open.");
    if(source.empty() || source.size()>262144 || source.find('\0')!=std::string::npos)fail("Shader source must be nonempty UTF-8 text of at most 256 KiB without NUL.");
    if(userShaders.size()>=64 || nextShaderHandle>=pm::kMaxId)fail("Shader capacity exceeded.");
    PMShaderRef resource;auto cached=shaderCache.find(source);
    if(cached!=shaderCache.end())resource=cached->second.lock();
    if(!resource) {
        resource=std::make_shared<PMShaderResource>();
        auto full=pm::internal::customShaderSource(PMMetalSource,source);
        NSString *text=[[NSString alloc]initWithBytes:full.data() length:full.size() encoding:NSUTF8StringEncoding];
        if(!text)fail("Shader source must be valid UTF-8.");
        NSError *error=nil;MTLCompileOptions *options=[MTLCompileOptions new];
        // A runtime availability check alone cannot compile against Xcode 15.
#if (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 150000) || (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000)
        if(@available(macOS 15.0,iOS 18.0,*))options.mathMode=MTLMathModeSafe;
        else
#endif
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            options.fastMathEnabled=NO;
#pragma clang diagnostic pop
        }
        resource->library=[device newLibraryWithSource:text options:options error:&error];
        if(!resource->library)failWith(pm::kErrPipeline,"Custom shader compilation failed: %s",error.localizedDescription.UTF8String);
        for(int t=0;t<PM_TARGET_COUNT;t++)for(int b=0;b<PM_BLEND_COUNT;b++) {
            auto format=t==PM_TARGET_DRAWABLE ? drawableFormat : MTLPixelFormatRGBA16Float;
            resource->pipelines[t][b]=makePipeline(@"cvmain",@"cfmain",format,pm::internal::blendFor(b,false,t==PM_TARGET_OFFSCREEN),&error,resource->library);
            if(!resource->pipelines[t][b])failWith(pm::kErrPipeline,"Custom shader pipeline failed: %s",error.localizedDescription.UTF8String);
        }
        if(shaderCache.size()>=64)shaderCache.erase(shaderCache.begin());
        shaderCache[source]=resource;
    }
    uint64_t handle=nextShaderHandle++;userShaders.emplace(handle,resource);return handle;
}
void pm::closeShader(uint64_t handle) {
    if(!userShaders.erase(handle))fail("Invalid or expired shader handle.");
}
void pm::drawShader(uint64_t handle,const ArrayView &parameters,const ArrayView &dst,uint64_t mask,const ArrayView *coverage) {
    if(!device || closing)fail("PsychMetal is not open.");
    auto p=checkShaderParameters(parameters);auto found=userShaders.find(handle);
    if(found==userShaders.end())fail("Invalid or expired shader handle.");
    if(dst.type!=ScalarType::Float64 || dst.ndim!=1 || dst.shape[0]!=4 || !dst.data)fail("Shader destination must be four doubles.");
    double r[4];for(int i=0;i<4;i++){r[i]=viewAt(dst,i);if(!isfinite(r[i]) || fabs(r[i])>1e6)fail("Invalid shader destination.");}
    if(r[2]<=r[0] || r[3]<=r[1])fail("Shader destination must have positive size.");
    std::array<double,8> c{};if(coverage)c=checkMask(*coverage);
    PMTextureRef m;if(mask){m=userTextures[textureSlot(mask)];if(m->channels!=1 || m->offscreen)fail("Shader mask must be a one-channel image texture.");}
    if(drawCount>=PM_MAX_SHAPES)fail("Frame draw capacity exceeded.");
    PMDrawItem item{};item.type=PM_ITEM_CUSTOM;item.blend=blendMode;memcpy(item.clip,clipRect,sizeof(item.clip));
    auto &u=item.stimulus;for(int i=0;i<4;i++){u.dst[i]=(float)r[i];u.mean[i]=(float)p[i];u.wave[i]=(float)p[i+4];u.noise[i]=(float)p[i+8];u.aperture[i]=(float)p[i+12];}
    u.maskA[0]=-1;if(coverage)for(int i=0;i<4;i++){u.maskA[i]=(float)c[i];u.maskB[i]=(float)c[i+4];}
    drawTextureRefs[drawCount]=m;drawShaderRefs[drawCount]=found->second;
    pthread_mutex_lock(&lock);drawList[drawCount++]=item;pthread_mutex_unlock(&lock);
}

void pm::drawMaskedTexture(uint64_t source, const pm::ArrayView &parameters, uint64_t mask, const pm::ArrayView *coverage) {
    if(!device || closing) fail("PsychMetal is not open.");
    if(parameters.type!=pm::ScalarType::Float64 || parameters.ndim!=1 || parameters.shape[0]!=14 || !parameters.data)
        fail("Masked texture parameters must be fourteen real doubles.");
    double p[14];
    for(int i=0;i<14;i++) {p[i]=viewAt(parameters,i);if(!isfinite(p[i])) fail("Masked texture parameters must be finite.");}
    for(int i=0;i<4;i++) if(p[i]<0 || p[i]>1 || fabs(p[i+4])>1e6 || p[i+8]<0 || p[i+8]>1)
        fail("Invalid masked texture crop, destination or tint.");
    if(p[2]<=p[0] || p[3]<=p[1] || p[6]<=p[4] || p[7]<=p[5] || fabs(p[12])>1e6 || (p[13]!=0 && p[13]!=1))
        fail("Masked texture rectangles must have positive size; filter must be 0 or 1.");
    std::array<double,8> c{};if(coverage)c=pm::checkMask(*coverage);
    auto image=userTextures[textureSlot(source)];PMTextureRef m;
    if(image==targetTexture) fail("Cannot sample the current drawing target.");
    if(mask) {m=userTextures[textureSlot(mask)];if(m->channels!=1 || m->offscreen) fail("Image mask must be a one-channel image texture.");}
    if(drawCount>=PM_MAX_SHAPES) fail("Frame draw capacity exceeded; split the work across frames.");
    PMDrawItem item{};item.type=PM_ITEM_MASKED_TEXTURE;item.blend=blendMode;
    memcpy(item.clip,clipRect,sizeof(item.clip));
    for(int i=0;i<4;i++) {item.src[i]=(float)p[i];item.dst[i]=(float)p[i+4];item.tint[i]=(float)p[i+8];}
    item.angle=(float)p[12];item.filterMode=(int)p[13];item.stimulus.maskA[0]=-1;
    if(coverage)for(int i=0;i<4;i++) {item.stimulus.maskA[i]=(float)c[i];item.stimulus.maskB[i]=(float)c[i+4];}
    drawTextureRefs[drawCount]=image;drawCoverageRefs[drawCount]=m;
    pthread_mutex_lock(&lock);drawList[drawCount++]=item;pthread_mutex_unlock(&lock);
}

void pm::drawStimulus(const pm::ArrayView &parameters, const pm::ArrayView &dst, uint64_t mask, const pm::ArrayView *coverage) {
    if(!device || closing) fail("PsychMetal is not open.");
    auto p=pm::checkStimulus(parameters);
    std::array<double,8> coverageValues{};
    if(coverage) coverageValues=pm::checkMask(*coverage);
    if(dst.type!=pm::ScalarType::Float64 || dst.ndim!=1 || dst.shape[0]!=4 || !dst.data)
        fail("Stimulus destination must be four real doubles.");
    double r[4];
    for(int i=0;i<4;i++) { r[i]=viewAt(dst,i); if(!isfinite(r[i]) || fabs(r[i])>1e6) fail("Invalid stimulus destination."); }
    if(!(r[2]>r[0] && r[3]>r[1])) fail("Stimulus destination must have positive width and height.");
    PMTextureRef m;
    if(mask) { m=userTextures[textureSlot(mask)]; if(m->channels!=1 || m->offscreen) fail("Stimulus mask must be a one-channel image texture."); }
    if(drawCount>=PM_MAX_SHAPES) fail("Frame draw capacity exceeded; split the work across frames.");
    PMDrawItem item{}; item.type=PM_ITEM_STIMULUS; item.blend=blendMode;
    memcpy(item.clip,clipRect,sizeof(item.clip));
    auto &u=item.stimulus;
    for(int i=0;i<4;i++) u.dst[i]=(float)r[i];
    for(int i=0;i<3;i++) u.mean[i]=(float)p[i+1];
    u.mean[3]=(float)p[12];
    u.wave[0]=(float)p[5]; u.wave[1]=(float)(p[6]*M_PI/180); u.wave[2]=(float)(p[7]*M_PI/180); u.wave[3]=(float)p[4];
    u.noise[0]=(float)p[8];u.noise[1]=(float)p[9];u.noise[2]=(float)p[10];u.noise[3]=(float)p[11];
    u.aperture[0]=(float)p[0];u.aperture[1]=(float)p[13];u.aperture[2]=(float)p[14];
    u.maskA[0]=-1; // no analytic recipe; old aperture/image-mask behavior
    if(coverage) {
        for(int i=0;i<4;i++) {u.maskA[i]=(float)coverageValues[i];u.maskB[i]=(float)coverageValues[i+4];}
    }
    // Keep the precise mask version alive just like a queued image draw.
    drawTextureRefs[drawCount]=m;
    pthread_mutex_lock(&lock); drawList[drawCount++]=item; pthread_mutex_unlock(&lock);
}

std::vector<pm::FrameRecord> pm::recentFrames(size_t count) {
    if(count < 1 || count > 256) fail("History count must be from 1 to 256.");
    if(!layer) fail("Open a window first.");
    return historyRecords(count);
}

void pm::updateTimeline(const ArrayView &updates) {liveTimeline.update(updates);}

void pm::cancelTimeline(bool cancel) noexcept { timelineCancellation.store(cancel); }

// What the display has reported of a frame. False while it has not; then
// presented is its time on screen, or 0 if it was not shown or its record is gone.
static bool reportedPresentation(uint64_t token, double &presented) {
    pthread_mutex_lock(&lock);
    Record *q = recordFor(token);
    const bool done = !q || q->done;
    presented = q && q->done && q->status == 0 ? q->presented : 0;
    pthread_mutex_unlock(&lock);
    return done;
}
// Wait until the display has reported on a frame, or until a deadline.
static void awaitPresentation(uint64_t token, double deadline) {
    pthread_mutex_lock(&lock);
    for (Record *q; (q = recordFor(token)) && !q->done && !closing; )
        if (waitRelative(deadline) == ETIMEDOUT) break;
    pthread_mutex_unlock(&lock);
}

pm::TimelineResult pm::playTimeline(uint64_t frames, const pm::ArrayView &tracks, const pm::ArrayView *keyframes) {
    if(!device || closing) fail("PsychMetal is not open.");
    if(frames<1 || frames>1000000) fail("Timeline frames must be from 1 to 1000000.");
    if(targetHandle || preparedToken) fail("Timeline requires the window target and no prepared frame.");
    if(tracks.type!=pm::ScalarType::Float64 || tracks.ndim!=2 || tracks.shape[1]!=6 ||
       tracks.shape[0]>PM_MAX_SHAPES*4 || (tracks.shape[0] && !tracks.data))
        fail("Timeline tracks must be N x 6 real doubles.");
    // Validate all tracks before consuming any queued draw. No host-owned arrays
    // are read after installation; no allocations occur in the sampling loop.
    const size_t count=drawCount;
    std::vector<pm::timeline::Track> program;
    program.reserve(tracks.shape[0]);
    std::vector<std::array<bool,4>> used(count);
    for(size_t i=0;i<tracks.shape[0];i++) {
        if(!count) fail("A timeline track needs a queued stimulus draw.");
        auto index=pm::checkUnsigned(viewAt(tracks,i,0),"timeline draw index",count-1);
        auto parameter=pm::checkUnsigned(viewAt(tracks,i,1),"timeline parameter",3);
        auto kind=pm::checkUnsigned(viewAt(tracks,i,2),"timeline kind",1);
        auto period=pm::checkUnsigned(viewAt(tracks,i,3),"timeline period",1000000);
        double amplitude=viewAt(tracks,i,4),offset=viewAt(tracks,i,5);
        if(period<2 || period%2) fail("Timeline periods must be even integers >=2.");
        if(!std::isfinite(amplitude) || !std::isfinite(offset)) fail("Timeline values must be finite.");
        if(drawList[index].type!=PM_ITEM_STIMULUS) fail("Timeline tracks must target procedural stimulus draws.");
        if(used[index][parameter]) fail("Only one timeline track may control each draw parameter.");
        // Bound the full range, including limits approached by a ramp. Prevent
        // float overflow and preserve the existing stimulus/coordinate ranges.
        double low=kind ? std::min(offset,offset+amplitude) : offset-std::fabs(amplitude);
        double high=kind ? std::max(offset,offset+amplitude) : offset+std::fabs(amplitude);
        double limit=parameter==1 ? 1000000 : parameter==0 ? 1 : 1000000;
        if(!std::isfinite(low) || !std::isfinite(high) || low < (parameter==0 ? 0 : -limit) || high>limit)
            fail("Timeline values exceed the parameter range.");
        if(parameter>=2) {
            auto &r=drawList[index].stimulus.dst;
            size_t axis=parameter-2;
            if(double(r[axis])+low < -1000000 || double(r[axis+2])+high > 1000000)
                fail("Timeline translation moves the stimulus outside the coordinate range.");
        }
        used[index][parameter]=true;
        program.push_back({index,parameter,kind,period,amplitude,offset});
    }
    std::vector<std::array<double,4>> bounds(count);std::vector<bool> eligible(count);
    for(size_t i=0;i<count;i++) {eligible[i]=drawList[i].type==PM_ITEM_STIMULUS;for(int j=0;j<4;j++)bounds[i][j]=drawList[i].stimulus.dst[j];}
    auto keyed=pm::timeline::keyTracks(keyframes,bounds,eligible,used);
    std::vector<PMDrawItem> scene(drawList,drawList+count);
    std::vector<PMTextureRef> resources(drawTextureRefs,drawTextureRefs+count);
    std::vector<PMTextureRef> masks(drawCoverageRefs,drawCoverageRefs+count);
    std::vector<PMShaderRef> shaders(drawShaderRefs,drawShaderRefs+count);
    // What would make the first Flip fail is checked before the scene is consumed.
#if PM_IOS
    iosRequireFront();
#endif
    pthread_mutex_lock(&lock);
    const bool idle=waitQueueIdleLocked();
    const double period=gridPeriod();
    pthread_mutex_unlock(&lock);
    if(!idle) fail("Timed out waiting for queued frames; QueueCancel them before PlayTimeline.");
    pm::TimelineResult result{};
    result.expectedRefreshHz=1/period;
    pm::timeline::Presentations shown;shown.period=period;
    uint64_t reported=0;      // the next sample whose report is awaited
    auto collect=[&] {        // take the reports that have arrived, in order
        for(double presented;reported<result.submitted && reportedPresentation(result.firstToken+reported,presented);++reported)
            shown.note(reported,presented);
    };
    // Only Escape (HID 0x29, and three fingers on iOS) is read on each frame.
    static const auto escapeOnly=[] { std::array<bool,256> f{}; f[40]=true; return f; }();
    auto clearQueued=[&] {
        liveTimeline.stop();
        for(size_t i=0;i<count;i++) {drawTextureRefs[i].reset();drawCoverageRefs[i].reset();drawShaderRefs[i].reset();}
        drawCount=0;targetBase=0;haveLastShape=false;
    };
    clearQueued();
    std::vector<pm::timeline::LiveValues> live(count);uint64_t liveVersion=0;
    liveTimeline.start(bounds,eligible);
    try {
        for(uint64_t frame=0;frame<frames;frame++) {
            bool keys[256]={}; readKeyboardState(keys,escapeOnly.data());
            if(timelineCancellation.load() || keys[40]) { result.cancelled=true;break; }
            for(size_t i=0;i<count;i++) {drawList[i]=scene[i];drawTextureRefs[i]=resources[i];drawCoverageRefs[i]=masks[i];drawShaderRefs[i]=shaders[i];}
            drawCount=count;
            for(const auto &track:program) {
                auto &u=drawList[track.drawIndex].stimulus;
                double v=pm::timeline::value(track,frame);
                if(track.parameter==0) u.wave[3]=(float)v;
                else if(track.parameter==1) u.wave[2]=(float)(v*M_PI/180);
                else { size_t axis=track.parameter-2;u.dst[axis]+=(float)v;u.dst[axis+2]+=(float)v; }
            }
            for(const auto &track:keyed) {
                auto &u=drawList[track.draw].stimulus;double v=pm::timeline::sample(track.keys.data(),track.keys.size(),frame);
                if(track.parameter==0)u.wave[3]=(float)v;
                else if(track.parameter==1)u.wave[2]=(float)(v*M_PI/180);
                else {size_t axis=track.parameter-2;u.dst[axis]+=(float)v;u.dst[axis+2]+=(float)v;}
            }
            liveTimeline.snapshot(live,liveVersion);
            for(size_t i=0;i<count;i++)for(size_t parameter=0;parameter<4;parameter++)if(live[i].set[parameter]) {
                auto &u=drawList[i].stimulus;double v=live[i].values[parameter];
                if(parameter==0)u.wave[3]=(float)v;
                else if(parameter==1)u.wave[2]=(float)(v*M_PI/180);
                else {size_t axis=parameter-2;u.dst[axis]=scene[i].stimulus.dst[axis]+(float)v;u.dst[axis+2]=scene[i].stimulus.dst[axis+2]+(float)v;}
            }
            auto flipped=pm::flip(0);
            if(!result.submitted) result.firstToken=flipped.token;
            result.lastToken=flipped.token;
            result.lastQueueMs=flipped.queueMs;result.lastFlipMs=flipped.callMs;
            result.lastConfirmed=flipped.confirmed;
            ++result.submitted;
            collect();
        }
    } catch(...) { clearQueued();throw; }
    clearQueued();
    if(result.cancelled) timelineCancellation.store(false);    // the request is spent
    if(result.submitted) {      // the last reports arrive a few refreshes after the last Flip
        awaitPresentation(result.lastToken,CACurrentMediaTime()+0.1+8*period);
        collect();
    }
    result.shown=shown.shown;result.late=shown.late;result.lateRefreshes=shown.lateRefreshes;
    result.firstLateSample=shown.late ? double(shown.firstLate) : NAN;
    result.meanSampleMs=shown.meanSampleSeconds()*1000;result.longestIntervalMs=shown.longest*1000;
    return result;
}
