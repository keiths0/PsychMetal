// macstubs.h — declarations of the Apple APIs PsychMetal's native core uses, so
// clang can type-check the Objective-C++ on a machine without the macOS SDK.
// SPDX-License-Identifier: MIT
//
// TEST INFRASTRUCTURE ONLY. Nothing here is ever linked or run. The stubs copy
// the SDK's signatures, so code that type-checks here uses the APIs the way the
// SDK declares them. They cannot catch behavioural changes, availability
// problems or SDK differences: the real build on a Mac remains the authority.
#ifndef PM_MACSTUBS_H
#define PM_MACSTUBS_H

#include <cstddef>
#include <cstdint>
#include <pthread.h>
#include <time.h>

// ---- basic types -----------------------------------------------------------
typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef bool BOOL;
#define YES true
#define NO false
#ifndef nil
#define nil nullptr
#endif
typedef double CGFloat;
typedef double NSTimeInterval;
typedef double CFTimeInterval;
struct CGPoint { CGFloat x, y; };
struct CGSize { CGFloat width, height; };
struct CGRect { CGPoint origin; CGSize size; };
typedef CGPoint NSPoint;
typedef CGSize NSSize;
typedef CGRect NSRect;
struct NSEdgeInsets { CGFloat top, left, bottom, right; };
extern const CGRect CGRectZero;
extern const CGSize CGSizeZero;
extern const NSRect NSZeroRect;
CGSize CGSizeMake(CGFloat w, CGFloat h);
NSRect NSMakeRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h);
NSEdgeInsets NSEdgeInsetsMake(CGFloat t, CGFloat l, CGFloat b, CGFloat r);
CGFloat NSWidth(NSRect); CGFloat NSHeight(NSRect);
CGFloat NSMinX(NSRect); CGFloat NSMinY(NSRect); CGFloat NSMaxY(NSRect);

// ---- CoreFoundation --------------------------------------------------------
typedef const void *CFTypeRef;
typedef long CFIndex;
typedef unsigned long CFTypeID;
typedef const struct __CFArray *CFArrayRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFNumber *CFNumberRef;
typedef const struct __CFBoolean *CFBooleanRef;
typedef const struct __CFAllocator *CFAllocatorRef;
struct CFDictionaryKeyCallBacks { int version; };
struct CFDictionaryValueCallBacks { int version; };
extern const CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
extern const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;
extern const CFBooleanRef kCFBooleanTrue;
enum { kCFNumberDoubleType = 13 };
typedef int CFNumberType;
void CFRelease(CFTypeRef);
CFIndex CFArrayGetCount(CFArrayRef);
const void *CFArrayGetValueAtIndex(CFArrayRef, CFIndex);
CFDictionaryRef CFDictionaryCreate(CFAllocatorRef, const void **keys, const void **values, CFIndex n,
                                   const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *);
const void *CFDictionaryGetValue(CFDictionaryRef, const void *key);
CFTypeID CFGetTypeID(CFTypeRef);
CFTypeID CFNumberGetTypeID(void);
bool CFNumberGetValue(CFNumberRef, CFNumberType, void *);
bool CFEqual(CFTypeRef, CFTypeRef);
CFStringRef __CFStringMakeConstantString(const char *);
#define CFSTR(s) __CFStringMakeConstantString(s)

// ---- CoreGraphics ----------------------------------------------------------
typedef uint32_t CGDirectDisplayID;
typedef int32_t CGError;
enum { kCGErrorSuccess = 0 };
typedef struct CGDisplayMode *CGDisplayModeRef;
typedef struct __CGEvent *CGEventRef;
typedef struct CGEventSource *CGEventSourceRef;
typedef uint64_t CGEventFlags;
typedef uint16_t CGKeyCode;
typedef int32_t CGWindowLevel;
typedef struct CGColorSpace *CGColorSpaceRef;
typedef enum { kCGEventSourceStatePrivate = -1, kCGEventSourceStateCombinedSessionState = 0,
               kCGEventSourceStateHIDSystemState = 1 } CGEventSourceStateID;
typedef enum { kCGMouseButtonLeft = 0, kCGMouseButtonRight = 1, kCGMouseButtonCenter = 2 } CGMouseButton;
extern const CFStringRef kCGDisplayShowDuplicateLowResolutionModes;
CGError CGGetActiveDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count);
CGRect CGDisplayBounds(CGDirectDisplayID);
size_t CGDisplayPixelsWide(CGDirectDisplayID);
size_t CGDisplayPixelsHigh(CGDirectDisplayID);
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID);
CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID, CFDictionaryRef);
CGError CGDisplaySetDisplayMode(CGDirectDisplayID, CGDisplayModeRef, CFDictionaryRef);
double CGDisplayModeGetRefreshRate(CGDisplayModeRef);
size_t CGDisplayModeGetWidth(CGDisplayModeRef);
size_t CGDisplayModeGetHeight(CGDisplayModeRef);
size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef);
size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef);
void CGDisplayModeRelease(CGDisplayModeRef);
CGError CGDisplayCapture(CGDirectDisplayID);
CGError CGDisplayRelease(CGDirectDisplayID);
CGError CGDisplayShowCursor(CGDirectDisplayID);
CGError CGDisplayHideCursor(CGDirectDisplayID);
CGDirectDisplayID CGMainDisplayID(void);
CGWindowLevel CGShieldingWindowLevel(void);
bool CGEventSourceKeyState(CGEventSourceStateID, CGKeyCode);
CGEventFlags CGEventSourceFlagsState(CGEventSourceStateID);
bool CGEventSourceButtonState(CGEventSourceStateID, CGMouseButton);
CGEventRef CGEventCreate(CGEventSourceRef);
CGPoint CGEventGetLocation(CGEventRef);
CFDictionaryRef CGSessionCopyCurrentDictionary(void);

// ---- Carbon, mach, dispatch, pthread extensions -----------------------------
extern "C" bool IsSecureEventInputEnabled(void);
typedef int kern_return_t;
struct mach_timebase_info_data_t { uint32_t numer, denom; };
typedef mach_timebase_info_data_t *mach_timebase_info_t;
extern "C" kern_return_t mach_timebase_info(mach_timebase_info_t);
extern "C" kern_return_t mach_wait_until(uint64_t deadline);
extern "C" uint64_t mach_absolute_time(void);
typedef void (^dispatch_block_t)(void);
typedef struct dispatch_queue_s *dispatch_queue_t;
extern "C" void dispatch_sync(dispatch_queue_t, dispatch_block_t);
extern "C" void dispatch_async(dispatch_queue_t, dispatch_block_t);
extern "C" dispatch_queue_t dispatch_get_main_queue(void);
extern "C" int pthread_main_np(void);
extern "C" int pthread_cond_timedwait_relative_np(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);
extern "C" double CACurrentMediaTime(void);

// ---- Foundation ------------------------------------------------------------
@class NSString, NSDictionary;
@interface NSObject
+ (instancetype)alloc;
+ (instancetype)new;
- (instancetype)init;
@end
@interface NSString : NSObject
@property (readonly) const char *UTF8String;
+ (instancetype)stringWithFormat:(NSString *)format, ...;
+ (instancetype)stringWithUTF8String:(const char *)s;
@end
@interface NSError : NSObject
@property (readonly, copy) NSString *localizedDescription;
@end
@interface NSDate : NSObject
+ (instancetype)dateWithTimeIntervalSinceNow:(NSTimeInterval)secs;
+ (NSDate *)distantPast;
@property (readonly) NSTimeInterval timeIntervalSinceNow;
@end
typedef NSString *NSRunLoopMode;
extern NSRunLoopMode const NSDefaultRunLoopMode;
@interface NSRunLoop : NSObject
@property (class, readonly, strong) NSRunLoop *mainRunLoop;
- (BOOL)runMode:(NSRunLoopMode)mode beforeDate:(NSDate *)limit;
@end
@interface NSArray<ObjectType> : NSObject
@property (readonly) NSUInteger count;
- (ObjectType)objectAtIndexedSubscript:(NSUInteger)i;
@end
@interface NSNumber : NSObject
@property (readonly) unsigned int unsignedIntValue;
@end
@interface NSDictionary<K, V> : NSObject
- (V)objectForKeyedSubscript:(K)key;
@end
@interface NSBundle : NSObject
@property (class, readonly, strong) NSBundle *mainBundle;
@property (readonly, copy) NSString *bundleIdentifier;
@end
@interface NSProcessInfo : NSObject
@property (class, readonly, strong) NSProcessInfo *processInfo;
@property (readonly, copy) NSString *operatingSystemVersionString;
@property (readonly, copy) NSString *processName;
@end

// ---- AppKit ----------------------------------------------------------------
typedef NSUInteger NSWindowStyleMask;
enum { NSWindowStyleMaskBorderless = 0 };
typedef NSUInteger NSBackingStoreType;
enum { NSBackingStoreBuffered = 2 };
typedef NSInteger NSWindowAnimationBehavior;
enum { NSWindowAnimationBehaviorNone = 2 };
typedef NSUInteger NSWindowCollectionBehavior;
enum { NSWindowCollectionBehaviorStationary = 1 << 4, NSWindowCollectionBehaviorIgnoresCycle = 1 << 6,
       NSWindowCollectionBehaviorFullScreenNone = 1 << 9 };
typedef NSUInteger NSAutoresizingMaskOptions;
enum { NSViewWidthSizable = 2, NSViewHeightSizable = 16 };
typedef NSInteger NSApplicationActivationPolicy;
enum { NSApplicationActivationPolicyRegular = 0, NSApplicationActivationPolicyAccessory = 1,
       NSApplicationActivationPolicyProhibited = 2 };
typedef NSUInteger NSEventMask;
enum { NSEventMaskAny = ~0UL };
typedef NSUInteger NSEventType;
enum { NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11, NSEventTypeFlagsChanged = 12 };
@class CALayer, NSScreen;
@interface NSEvent : NSObject
@property (readonly) NSEventType type;
@end
@interface NSView : NSObject
- (instancetype)initWithFrame:(NSRect)frame;
@property NSRect bounds;
@property NSAutoresizingMaskOptions autoresizingMask;
@property BOOL wantsLayer;
@property (strong) CALayer *layer;
@end
@interface NSScreen : NSObject
@property (class, readonly, copy) NSArray<NSScreen *> *screens;
@property (class, readonly, strong) NSScreen *mainScreen;
@property (readonly) NSRect frame;
@property (readonly) NSRect visibleFrame;
@property (readonly) NSEdgeInsets safeAreaInsets;
@property (readonly, copy) NSDictionary<NSString *, id> *deviceDescription;
@end
@interface NSWindow : NSObject
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSWindowStyleMask)s
                            backing:(NSBackingStoreType)b defer:(BOOL)d screen:(NSScreen *)screen;
@property BOOL releasedWhenClosed;
@property NSWindowAnimationBehavior animationBehavior;
@property (copy) NSString *title;
@property NSInteger level;
@property NSWindowCollectionBehavior collectionBehavior;
@property (strong) NSView *contentView;
@property (readonly) CGFloat backingScaleFactor;
@property (readonly) NSRect frame;
@property (readonly, strong) NSScreen *screen;
@property BOOL ignoresMouseEvents;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)resignKeyWindow;
- (void)orderOut:(id)sender;
- (void)close;
@end
@interface NSApplication : NSObject
+ (NSApplication *)sharedApplication;
@property (readonly) NSApplicationActivationPolicy activationPolicy;
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)p;
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)finishLaunching;
- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask untilDate:(NSDate *)d inMode:(NSRunLoopMode)m dequeue:(BOOL)q;
- (void)sendEvent:(NSEvent *)e;
@end
extern NSApplication *NSApp;

// ---- Metal -----------------------------------------------------------------
typedef NSUInteger MTLPixelFormat;
enum { MTLPixelFormatR16Float = 25, MTLPixelFormatBGRA8Unorm = 80, MTLPixelFormatRGBA16Float = 115 };
typedef NSUInteger MTLTextureUsage;
enum { MTLTextureUsageShaderRead = 1 };
typedef NSUInteger MTLStorageMode;
enum { MTLStorageModeShared = 0 };
typedef NSUInteger MTLResourceOptions;
enum { MTLResourceStorageModeShared = 0 };
typedef NSUInteger MTLLoadAction;
enum { MTLLoadActionClear = 2 };
typedef NSUInteger MTLStoreAction;
enum { MTLStoreActionStore = 1 };
typedef NSUInteger MTLPrimitiveType;
enum { MTLPrimitiveTypeTriangleStrip = 4 };
typedef NSUInteger MTLBlendOperation;
enum { MTLBlendOperationAdd = 0 };
typedef NSUInteger MTLBlendFactor;
enum { MTLBlendFactorOne = 1, MTLBlendFactorSourceAlpha = 4, MTLBlendFactorOneMinusSourceAlpha = 5 };
typedef NSUInteger MTLSamplerMinMagFilter;
enum { MTLSamplerMinMagFilterNearest = 0, MTLSamplerMinMagFilterLinear = 1 };
typedef NSUInteger MTLSamplerAddressMode;
enum { MTLSamplerAddressModeClampToEdge = 0 };
typedef NSUInteger MTLCommandBufferStatus;
enum { MTLCommandBufferStatusCompleted = 4, MTLCommandBufferStatusError = 5 };
struct MTLOrigin { NSUInteger x, y, z; };
struct MTLSize { NSUInteger width, height, depth; };
struct MTLRegion { MTLOrigin origin; MTLSize size; };
MTLRegion MTLRegionMake2D(NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h);
struct MTLClearColor { double red, green, blue, alpha; };
MTLClearColor MTLClearColorMake(double r, double g, double b, double a);

@protocol MTLTexture
@property (readonly) NSUInteger width;
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l withBytes:(const void *)b bytesPerRow:(NSUInteger)bpr;
@end
@protocol MTLBuffer
- (void *)contents;
@end
@protocol MTLFunction
@end
@protocol MTLLibrary
- (id<MTLFunction>)newFunctionWithName:(NSString *)name;
@end
@protocol MTLRenderPipelineState
@end
@protocol MTLSamplerState
@end
@protocol MTLDrawable
@property (readonly) CFTimeInterval presentedTime;
- (void)present;
- (void)addPresentedHandler:(void (^)(id<MTLDrawable>))block;
@end
@protocol CAMetalDrawable <MTLDrawable>
@property (readonly) id<MTLTexture> texture;
@end
@interface MTLRenderPassColorAttachmentDescriptor : NSObject
@property (strong) id<MTLTexture> texture;
@property MTLLoadAction loadAction;
@property MTLStoreAction storeAction;
@property MTLClearColor clearColor;
@end
@interface MTLRenderPassColorAttachmentDescriptorArray : NSObject
- (MTLRenderPassColorAttachmentDescriptor *)objectAtIndexedSubscript:(NSUInteger)i;
@end
@interface MTLRenderPassDescriptor : NSObject
+ (MTLRenderPassDescriptor *)renderPassDescriptor;
@property (readonly) MTLRenderPassColorAttachmentDescriptorArray *colorAttachments;
@end
@interface MTLRenderPipelineColorAttachmentDescriptor : NSObject
@property MTLPixelFormat pixelFormat;
@property BOOL blendingEnabled;
@property MTLBlendOperation rgbBlendOperation, alphaBlendOperation;
@property MTLBlendFactor sourceRGBBlendFactor, sourceAlphaBlendFactor;
@property MTLBlendFactor destinationRGBBlendFactor, destinationAlphaBlendFactor;
@end
@interface MTLRenderPipelineColorAttachmentDescriptorArray : NSObject
- (MTLRenderPipelineColorAttachmentDescriptor *)objectAtIndexedSubscript:(NSUInteger)i;
@end
@interface MTLRenderPipelineDescriptor : NSObject
@property (strong) id<MTLFunction> vertexFunction;
@property (strong) id<MTLFunction> fragmentFunction;
@property (readonly) MTLRenderPipelineColorAttachmentDescriptorArray *colorAttachments;
@end
@interface MTLTextureDescriptor : NSObject
+ (MTLTextureDescriptor *)texture2DDescriptorWithPixelFormat:(MTLPixelFormat)f width:(NSUInteger)w
                                                      height:(NSUInteger)h mipmapped:(BOOL)m;
@property MTLTextureUsage usage;
@property MTLStorageMode storageMode;
@end
@interface MTLSamplerDescriptor : NSObject
@property MTLSamplerMinMagFilter minFilter, magFilter;
@property MTLSamplerAddressMode sAddressMode, tAddressMode;
@end
@protocol MTLRenderCommandEncoder
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)s;
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i;
- (void)setVertexBytes:(const void *)b length:(NSUInteger)l atIndex:(NSUInteger)i;
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i;
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i;
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c;
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c
         instanceCount:(NSUInteger)n;
- (void)endEncoding;
@end
@protocol MTLCommandBuffer
@property (readonly) MTLCommandBufferStatus status;
@property (readonly) CFTimeInterval GPUStartTime;
@property (readonly) CFTimeInterval GPUEndTime;
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d;
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))block;
- (void)presentDrawable:(id<MTLDrawable>)d;
- (void)presentDrawable:(id<MTLDrawable>)d atTime:(CFTimeInterval)t;
- (void)commit;
- (void)waitUntilScheduled;
@end
@protocol MTLCommandQueue
- (id<MTLCommandBuffer>)commandBuffer;
@end
@protocol MTLDevice
- (id<MTLCommandQueue>)newCommandQueue;
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d;
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)s options:(id)o error:(NSError **)e;
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d
                                                             error:(NSError **)e;
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)l options:(MTLResourceOptions)o;
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d;
@end
extern "C" id<MTLDevice> MTLCreateSystemDefaultDevice(void);

// ---- QuartzCore ------------------------------------------------------------
typedef unsigned int CAAutoresizingMask;
enum { kCALayerWidthSizable = 2, kCALayerHeightSizable = 16 };
@interface CALayer : NSObject
+ (instancetype)layer;
@property CGRect frame;
@property CGFloat contentsScale;
@property CAAutoresizingMask autoresizingMask;
@property BOOL opaque;
@end
@interface CAMetalLayer : CALayer
@property (strong) id<MTLDevice> device;
@property MTLPixelFormat pixelFormat;
@property CGColorSpaceRef colorspace;
@property BOOL wantsExtendedDynamicRangeContent;
@property BOOL framebufferOnly;
@property BOOL displaySyncEnabled;
@property NSUInteger maximumDrawableCount;
@property BOOL presentsWithTransaction;
@property CGSize drawableSize;
- (id<CAMetalDrawable>)nextDrawable;
@end
@interface CATransaction : NSObject
+ (void)flush;
@end

#endif
