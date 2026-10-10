// macstubs.h — declarations of the Apple APIs PsychMetal's native core uses, so
// clang can type-check the Objective-C++ on a machine without the macOS SDK.
// With -DPM_STUB_IOS it declares what an iPhone has instead: the Mac's display,
// event, registry and AppKit interfaces are left out, and UIKit's are put in.
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
CGRect CGRectMake(CGFloat x, CGFloat y, CGFloat w, CGFloat h);
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
typedef struct __CFDictionary *CFMutableDictionaryRef;
typedef const struct __CFAttributedString *CFAttributedStringRef;
typedef uint32_t CFStringEncoding;
enum { kCFStringEncodingUTF8 = 0x08000100 };
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
CFTypeID CFArrayGetTypeID(void);
typedef const struct __CFSet *CFSetRef;
CFTypeID CFSetGetTypeID(void);
CFIndex CFSetGetCount(CFSetRef);
void CFSetGetValues(CFSetRef, const void **values);
CFTypeID CFStringGetTypeID(void);
double CFStringGetDoubleValue(CFStringRef);
CFTypeID CFDictionaryGetTypeID(void);
CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, CFStringEncoding);
CFAttributedStringRef CFAttributedStringCreate(CFAllocatorRef, CFStringRef, CFDictionaryRef);
bool CFNumberGetValue(CFNumberRef, CFNumberType, void *);
bool CFEqual(CFTypeRef, CFTypeRef);
CFStringRef __CFStringMakeConstantString(const char *);
#define CFSTR(s) __CFStringMakeConstantString(s)

// ---- CoreGraphics ----------------------------------------------------------
typedef struct CGColorSpace *CGColorSpaceRef;
#ifndef PM_STUB_IOS
typedef uint32_t CGDirectDisplayID;
typedef int32_t CGError;
enum { kCGErrorSuccess = 0 };
typedef struct CGDisplayMode *CGDisplayModeRef;
typedef struct __CGEvent *CGEventRef;
typedef struct CGEventSource *CGEventSourceRef;
typedef uint64_t CGEventFlags;
typedef uint16_t CGKeyCode;
typedef int32_t CGWindowLevel;
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
// Event taps.
typedef struct __CGEventTapProxy *CGEventTapProxy;
typedef uint32_t CGEventType;
enum { kCGEventLeftMouseDown = 1, kCGEventLeftMouseUp = 2, kCGEventRightMouseDown = 3, kCGEventRightMouseUp = 4,
       kCGEventKeyDown = 10, kCGEventKeyUp = 11, kCGEventFlagsChanged = 12, kCGEventOtherMouseDown = 25,
       kCGEventOtherMouseUp = 26, kCGEventTapDisabledByTimeout = 0xFFFFFFFE,
       kCGEventTapDisabledByUserInput = 0xFFFFFFFF };
typedef uint64_t CGEventMask;
#define CGEventMaskBit(type) ((CGEventMask)1 << (type))
typedef uint64_t CGEventTimestamp;
CGEventTimestamp CGEventGetTimestamp(CGEventRef);
CGEventFlags CGEventGetFlags(CGEventRef);
typedef uint32_t CGEventField;
enum { kCGMouseEventButtonNumber = 3, kCGKeyboardEventAutorepeat = 8, kCGKeyboardEventKeycode = 9 };
int64_t CGEventGetIntegerValueField(CGEventRef, CGEventField);
typedef CGEventRef (*CGEventTapCallBack)(CGEventTapProxy, CGEventType, CGEventRef, void *);
typedef struct __CFMachPort *CFMachPortRef;
typedef struct __CFRunLoop *CFRunLoopRef;
typedef struct __CFRunLoopSource *CFRunLoopSourceRef;
typedef struct __CFRunLoopTimer *CFRunLoopTimerRef;
typedef uint32_t CGEventTapLocation, CGEventTapPlacement, CGEventTapOptions;
enum { kCGSessionEventTap = 1, kCGHeadInsertEventTap = 0, kCGEventTapOptionListenOnly = 1 };
CFMachPortRef CGEventTapCreate(CGEventTapLocation, CGEventTapPlacement, CGEventTapOptions, CGEventMask,
                               CGEventTapCallBack, void *);
void CGEventTapEnable(CFMachPortRef, bool);
bool CGPreflightListenEventAccess(void);
bool CGRequestListenEventAccess(void);
extern const CFStringRef kCFRunLoopDefaultMode, kCFRunLoopCommonModes;
CFRunLoopRef CFRunLoopGetCurrent(void);
void CFRunLoopAddSource(CFRunLoopRef, CFRunLoopSourceRef, CFStringRef mode);
void CFRunLoopRemoveSource(CFRunLoopRef, CFRunLoopSourceRef, CFStringRef mode);
void CFRunLoopWakeUp(CFRunLoopRef);
void CFRunLoopStop(CFRunLoopRef);
int32_t CFRunLoopRunInMode(CFStringRef mode, CFTimeInterval seconds, bool returnAfterSourceHandled);
CFRunLoopSourceRef CFMachPortCreateRunLoopSource(const void *allocator, CFMachPortRef, long order);
void CFMachPortInvalidate(CFMachPortRef);
double CFAbsoluteTimeGetCurrent(void);
CFRunLoopTimerRef CFRunLoopTimerCreate(const void *allocator, double fireDate, CFTimeInterval interval,
                                       unsigned long flags, long order, void (*callout)(CFRunLoopTimerRef, void *), void *context);
void CFRunLoopAddTimer(CFRunLoopRef, CFRunLoopTimerRef, CFStringRef mode);
void CFRunLoopTimerInvalidate(CFRunLoopTimerRef);
CGError CGWarpMouseCursorPosition(CGPoint);
CGError CGAssociateMouseAndMouseCursorPosition(bool);
CFDictionaryRef CGSessionCopyCurrentDictionary(void);
uint32_t CGDisplayModelNumber(CGDirectDisplayID);
uint32_t CGDisplaySerialNumber(CGDirectDisplayID);
#endif
typedef struct CGContext *CGContextRef;
typedef uint32_t CGBitmapInfo;
enum { kCGImageAlphaOnly = 7 };
CGContextRef CGBitmapContextCreate(void *data, size_t width, size_t height, size_t bitsPerComponent,
                                   size_t bytesPerRow, CGColorSpaceRef space, CGBitmapInfo info);
void CGContextSetTextPosition(CGContextRef, CGFloat x, CGFloat y);
void CGContextRelease(CGContextRef);
void CGContextTranslateCTM(CGContextRef, CGFloat tx, CGFloat ty);
void CGContextScaleCTM(CGContextRef, CGFloat sx, CGFloat sy);
void CGContextSetShouldAntialias(CGContextRef, bool);
void CGContextSetGrayFillColor(CGContextRef, CGFloat gray, CGFloat alpha);
void CGContextSetGrayStrokeColor(CGContextRef, CGFloat gray, CGFloat alpha);
void CGContextBeginPath(CGContextRef);
void CGContextMoveToPoint(CGContextRef, CGFloat x, CGFloat y);
void CGContextAddLineToPoint(CGContextRef, CGFloat x, CGFloat y);
void CGContextClosePath(CGContextRef);
void CGContextSetLineWidth(CGContextRef, CGFloat);
typedef int32_t CGLineJoin;
enum { kCGLineJoinMiter = 0 };
void CGContextSetLineJoin(CGContextRef, CGLineJoin);
void CGContextSetMiterLimit(CGContextRef, CGFloat);
void CGContextStrokePath(CGContextRef);
void CGContextEOFillPath(CGContextRef);

// ---- CoreText ----------------------------------------------------------------
typedef const struct __CTFont *CTFontRef;
typedef const struct __CTLine *CTLineRef;
typedef const struct CGAffineTransform *CGAffineTransformPointer;
extern const CFStringRef kCTFontAttributeName;
CTFontRef CTFontCreateWithName(CFStringRef name, CGFloat size, const struct CGAffineTransform *matrix);
CTLineRef CTLineCreateWithAttributedString(CFAttributedStringRef);
double CTLineGetTypographicBounds(CTLineRef, CGFloat *ascent, CGFloat *descent, CGFloat *leading);
void CTLineDraw(CTLineRef, CGContextRef);

// ---- IOKit -------------------------------------------------------------------
#ifndef PM_STUB_IOS
typedef unsigned int mach_port_t;
typedef mach_port_t io_object_t;
typedef io_object_t io_iterator_t;
typedef unsigned int IOOptionBits;
enum { KERN_SUCCESS = 0 };
extern const mach_port_t kIOMainPortDefault;
extern "C" CFMutableDictionaryRef IOServiceMatching(const char *name);
extern "C" int IOServiceGetMatchingServices(mach_port_t, CFDictionaryRef matching, io_iterator_t *existing);
extern "C" io_object_t IOIteratorNext(io_iterator_t);
#define kIOServicePlane "IOService"
enum { kIORegistryIterateRecursively = 1 };
extern "C" int IORegistryCreateIterator(mach_port_t, const char *plane, uint32_t options, io_iterator_t *iterator);
extern "C" int IOObjectConformsTo(io_object_t, const char *className);
extern "C" int IOObjectRelease(io_object_t);
extern "C" int IORegistryEntryCreateCFProperties(io_object_t, CFMutableDictionaryRef *properties,
                                                 CFAllocatorRef, IOOptionBits);

// ---- Carbon, mach, dispatch, pthread extensions -----------------------------
extern "C" bool IsSecureEventInputEnabled(void);
#endif
typedef int kern_return_t;
struct mach_timebase_info_data_t { uint32_t numer, denom; };
typedef mach_timebase_info_data_t *mach_timebase_info_t;
extern "C" kern_return_t mach_timebase_info(mach_timebase_info_t);
extern "C" kern_return_t mach_wait_until(uint64_t deadline);
extern "C" uint64_t mach_absolute_time(void);
extern "C" uint64_t mach_continuous_time(void);
typedef void (^dispatch_block_t)(void);
typedef struct dispatch_queue_s *dispatch_queue_t;
extern "C" void dispatch_sync(dispatch_queue_t, dispatch_block_t);
extern "C" void dispatch_async(dispatch_queue_t, dispatch_block_t);
extern "C" dispatch_queue_t dispatch_get_main_queue(void);
extern "C" int pthread_main_np(void);
extern "C" int pthread_set_qos_class_self_np(int qosClass, int relativePriority);
enum { QOS_CLASS_USER_INTERACTIVE = 0x21 };
#define pthread_setname_np(name) ((void)(name))   // macOS: one argument, names the calling thread
extern "C" int pthread_cond_timedwait_relative_np(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);
extern "C" double CACurrentMediaTime(void);

// ---- Foundation ------------------------------------------------------------
@class NSString, NSDictionary;
@interface NSObject
+ (instancetype)alloc;
+ (instancetype)new;
+ (Class)class;
- (instancetype)init;
- (BOOL)isKindOfClass:(Class)aClass;
@end
enum { NSUTF8StringEncoding = 4 };
@interface NSString : NSObject
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length encoding:(NSUInteger)encoding;
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
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
@interface NSProcessInfo : NSObject
@property (class, readonly, strong) NSProcessInfo *processInfo;
@property (readonly, copy) NSString *operatingSystemVersionString;
@property (readonly, copy) NSString *processName;
@property (readonly, getter=isLowPowerModeEnabled) BOOL lowPowerModeEnabled;
@end

// ---- AppKit ----------------------------------------------------------------
#ifndef PM_STUB_IOS
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
#endif

// ---- Metal -----------------------------------------------------------------
typedef NSUInteger MTLPixelFormat;
enum { MTLPixelFormatR8Unorm = 10, MTLPixelFormatR16Float = 25, MTLPixelFormatRGBA8Unorm = 70,
       MTLPixelFormatBGRA8Unorm = 80, MTLPixelFormatBGR10A2Unorm = 94, MTLPixelFormatRGBA16Float = 115, MTLPixelFormatRGBA32Float = 125 };
typedef NSUInteger MTLTextureUsage;
enum { MTLTextureUsageShaderRead = 1, MTLTextureUsageRenderTarget = 4 };
typedef NSUInteger MTLStorageMode;
enum { MTLStorageModeShared = 0, MTLStorageModePrivate = 2 };
typedef NSUInteger MTLResourceOptions;
enum { MTLResourceStorageModeShared = 0 };
typedef NSUInteger MTLLoadAction;
enum { MTLLoadActionDontCare = 0, MTLLoadActionLoad = 1, MTLLoadActionClear = 2 };
typedef NSUInteger MTLStoreAction;
enum { MTLStoreActionStore = 1 };
typedef NSUInteger MTLPrimitiveType;
enum { MTLPrimitiveTypeTriangle = 3, MTLPrimitiveTypeTriangleStrip = 4 };
typedef NSUInteger MTLBlendOperation;
enum { MTLBlendOperationAdd = 0 };
typedef NSUInteger MTLBlendFactor;
enum { MTLBlendFactorZero = 0, MTLBlendFactorOne = 1, MTLBlendFactorSourceAlpha = 4, MTLBlendFactorOneMinusSourceAlpha = 5 };
typedef NSUInteger MTLSamplerMinMagFilter;
enum { MTLSamplerMinMagFilterNearest = 0, MTLSamplerMinMagFilterLinear = 1 };
typedef NSUInteger MTLSamplerAddressMode;
enum { MTLSamplerAddressModeClampToEdge = 0 };
typedef NSUInteger MTLCommandBufferStatus;
enum { MTLCommandBufferStatusCompleted = 4, MTLCommandBufferStatusError = 5 };
struct MTLOrigin { NSUInteger x, y, z; };
struct MTLScissorRect { NSUInteger x, y, width, height; };
struct MTLSize { NSUInteger width, height, depth; };
struct MTLRegion { MTLOrigin origin; MTLSize size; };
MTLRegion MTLRegionMake2D(NSUInteger x, NSUInteger y, NSUInteger w, NSUInteger h);
MTLOrigin MTLOriginMake(NSUInteger x, NSUInteger y, NSUInteger z);
MTLSize MTLSizeMake(NSUInteger w, NSUInteger h, NSUInteger d);
struct MTLClearColor { double red, green, blue, alpha; };
MTLClearColor MTLClearColorMake(double r, double g, double b, double a);

@protocol MTLTexture
@property (readonly) NSUInteger width;
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l withBytes:(const void *)b bytesPerRow:(NSUInteger)bpr;
- (void)getBytes:(void *)b bytesPerRow:(NSUInteger)bpr fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l;
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
- (void)setFragmentBytes:(const void *)b length:(NSUInteger)l atIndex:(NSUInteger)i;
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i;
- (void)setScissorRect:(MTLScissorRect)r;
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c;
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c
         instanceCount:(NSUInteger)n;
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c
         instanceCount:(NSUInteger)n baseInstance:(NSUInteger)b;
- (void)endEncoding;
@end
@protocol MTLBlitCommandEncoder
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz toBuffer:(id<MTLBuffer>)d
       destinationOffset:(NSUInteger)o destinationBytesPerRow:(NSUInteger)r destinationBytesPerImage:(NSUInteger)i;
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz toTexture:(id<MTLTexture>)d
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorigin;
- (void)endEncoding;
@end
@protocol MTLCommandBuffer
@property (readonly) MTLCommandBufferStatus status;
@property (readonly) CFTimeInterval GPUStartTime;
@property (readonly) CFTimeInterval GPUEndTime;
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d;
- (id<MTLBlitCommandEncoder>)blitCommandEncoder;
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))block;
- (void)presentDrawable:(id<MTLDrawable>)d;
- (void)presentDrawable:(id<MTLDrawable>)d atTime:(CFTimeInterval)t;
- (void)commit;
- (void)waitUntilScheduled;
@end
@protocol MTLCommandQueue
- (id<MTLCommandBuffer>)commandBuffer;
@end
@interface MTLCompileOptions : NSObject
@property NSInteger mathMode;
@property BOOL fastMathEnabled __attribute__((deprecated));
@end
enum { MTLMathModeSafe = 0 };
@protocol MTLDevice
@property (readonly) NSString *name;
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
#ifndef PM_STUB_IOS
@property BOOL displaySyncEnabled;      // macOS only
#endif
@property NSUInteger maximumDrawableCount;
@property BOOL presentsWithTransaction;
@property CGSize drawableSize;
- (id<CAMetalDrawable>)nextDrawable;
@end
@interface CATransaction : NSObject
+ (void)flush;
@end

// ---- enumeration, and sets -------------------------------------------------------
struct NSFastEnumerationState { unsigned long state; id __unsafe_unretained *itemsPtr; unsigned long *mutationsPtr;
                                unsigned long extra[5]; };
@interface NSArray<ObjectType> (Enumeration)
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)len;
@end
@interface NSSet<ObjectType> : NSObject
@property (readonly) NSUInteger count;
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)len;
@end
@interface NSObject (Equality)
- (BOOL)isEqual:(id)object;
@end

#ifndef PM_STUB_IOS
// ---- AppKit: the trackpad's contacts ---------------------------------------------
typedef NSUInteger NSTouchPhase;
enum { NSTouchPhaseBegan = 1U << 0, NSTouchPhaseMoved = 1U << 1, NSTouchPhaseStationary = 1U << 2,
       NSTouchPhaseEnded = 1U << 3, NSTouchPhaseCancelled = 1U << 4 };
typedef NSUInteger NSTouchTypeMask;
enum { NSTouchTypeMaskDirect = 1U << 0, NSTouchTypeMaskIndirect = 1U << 1 };
@interface NSTouch : NSObject
@property (readonly, strong) id identity;
@property (readonly) NSTouchPhase phase;
@property (readonly) NSPoint normalizedPosition;
@end
@interface NSEvent (Touches)
@property (readonly) NSTimeInterval timestamp;
- (NSSet<NSTouch *> *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view;
@end
@interface NSView (Touches)
@property NSTouchTypeMask allowedTouchTypes;
@end
#endif

#ifdef PM_STUB_IOS
// ---- Foundation and QuartzCore, as the iPhone's side uses them ----------------
@interface NSNumber (Values)
@property (readonly) BOOL boolValue;
@end
@interface NSNotification : NSObject
@end
@class NSOperationQueue;
typedef NSString *NSNotificationName;
@interface NSNotificationCenter : NSObject
@property (class, readonly, strong) NSNotificationCenter *defaultCenter;
- (id)addObserverForName:(NSNotificationName)name object:(id)object queue:(NSOperationQueue *)queue
              usingBlock:(void (^)(NSNotification *note))block;
- (void)removeObserver:(id)observer;
@end
extern NSRunLoopMode const NSRunLoopCommonModes;
struct CAFrameRateRange { float minimum, maximum, preferred; };
CAFrameRateRange CAFrameRateRangeMake(float minimum, float maximum, float preferred);
@interface CADisplayLink : NSObject
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector;
@property CAFrameRateRange preferredFrameRateRange;
- (void)addToRunLoop:(NSRunLoop *)runloop forMode:(NSRunLoopMode)mode;
- (void)invalidate;
@end

// ---- UIKit -------------------------------------------------------------------
struct UIEdgeInsets { CGFloat top, left, bottom, right; };
extern const UIEdgeInsets UIEdgeInsetsZero;
typedef CGFloat UIWindowLevel;
extern const UIWindowLevel UIWindowLevelAlert;
typedef NSInteger UIInterfaceOrientation;
enum { UIInterfaceOrientationUnknown = 0, UIInterfaceOrientationPortrait = 1 };
typedef NSUInteger UIInterfaceOrientationMask;
enum { UIInterfaceOrientationMaskAll = 30 };
typedef NSUInteger UIRectEdge;
enum { UIRectEdgeAll = 15 };
typedef NSInteger UISceneActivationState;
enum { UISceneActivationStateForegroundActive = 0 };
typedef NSInteger UIUserInterfaceIdiom;
enum { UIUserInterfaceIdiomPhone = 0 };
typedef NSInteger UIKeyboardHIDUsage;
extern NSNotificationName const UIApplicationWillResignActiveNotification;
@class UIView, UIWindow, UIScreen, UIViewController, UIEvent, UIPressesEvent;
@interface UIColor : NSObject
@property (class, readonly, strong) UIColor *blackColor;
@property (class, readonly, strong) UIColor *whiteColor;
@end
@interface UIDevice : NSObject
@property (class, readonly, strong) UIDevice *currentDevice;
@property (readonly) UIUserInterfaceIdiom userInterfaceIdiom;
@end
@interface UIScreen : NSObject
@property (readonly) CGRect bounds;
@property (readonly) CGRect nativeBounds;
@property (readonly) CGFloat nativeScale;
@property (readonly) NSInteger maximumFramesPerSecond;
@end
typedef NSInteger UIEditingInteractionConfiguration;
enum { UIEditingInteractionConfigurationNone = 0, UIEditingInteractionConfigurationDefault = 1 };
@interface UIResponder : NSObject
@property (readonly) UIEditingInteractionConfiguration editingInteractionConfiguration;
- (BOOL)becomeFirstResponder;
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)pressesBegan:(NSSet *)presses withEvent:(UIPressesEvent *)event;
- (void)pressesEnded:(NSSet *)presses withEvent:(UIPressesEvent *)event;
- (void)pressesCancelled:(NSSet *)presses withEvent:(UIPressesEvent *)event;
@end
@interface UIView : UIResponder
- (instancetype)initWithFrame:(CGRect)frame;
@property (class, readonly) Class layerClass;
@property (readonly, strong) CALayer *layer;
@property CGRect frame;
@property CGRect bounds;
@property (getter=isHidden) BOOL hidden;
@property (getter=isMultipleTouchEnabled) BOOL multipleTouchEnabled;
@property (copy) UIColor *backgroundColor;
@property (readonly) UIEdgeInsets safeAreaInsets;
- (void)addSubview:(UIView *)view;
- (void)layoutIfNeeded;
@end
typedef NSInteger UIButtonType;
typedef NSUInteger UIControlState;
typedef NSUInteger UIControlEvents;
enum { UIButtonTypeSystem = 1, UIControlStateNormal = 0, UIControlEventTouchUpInside = 64 };
@interface UIButton : UIView
+ (instancetype)buttonWithType:(UIButtonType)type;
- (void)setTitle:(NSString *)title forState:(UIControlState)state;
- (void)setTitleColor:(UIColor *)color forState:(UIControlState)state;
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)events;
@property (copy) NSString *accessibilityLabel;
@end
@interface UIViewController : UIResponder
@property (strong) UIView *view;
- (void)loadView;
- (void)viewDidLoad;
- (void)viewDidLayoutSubviews;
@property (readonly) BOOL prefersStatusBarHidden;
@property (readonly) BOOL prefersHomeIndicatorAutoHidden;
@property (readonly) UIRectEdge preferredScreenEdgesDeferringSystemGestures;
@property (readonly) UIInterfaceOrientationMask supportedInterfaceOrientations;
@end
@interface UIScene : UIResponder
@property (readonly) UISceneActivationState activationState;
@end
@interface UIWindowScene : UIScene
@property (readonly, strong) UIScreen *screen;
@property (readonly) UIInterfaceOrientation interfaceOrientation;
@property (readonly, strong) UIWindow *keyWindow;
@end
@interface UIWindow : UIView
- (instancetype)initWithWindowScene:(UIWindowScene *)scene;
@property UIWindowLevel windowLevel;
@property (strong) UIViewController *rootViewController;
@property (weak) UIWindowScene *windowScene;
- (void)makeKeyAndVisible;
- (void)makeKeyWindow;
@end
@interface UIApplication : UIResponder
@property (class, readonly, strong) UIApplication *sharedApplication;
@property (readonly) NSSet<UIScene *> *connectedScenes;
@property (getter=isIdleTimerDisabled) BOOL idleTimerDisabled;
@end
@interface UITouch : NSObject
@property (readonly) NSTimeInterval timestamp;
- (CGPoint)preciseLocationInView:(UIView *)view;
@end
@interface UIEvent : NSObject
- (NSArray<UITouch *> *)coalescedTouchesForTouch:(UITouch *)touch;
@end
@interface UIPressesEvent : UIEvent
@end
@interface UIKey : NSObject
@property (readonly) UIKeyboardHIDUsage keyCode;
@end
@interface UIPress : NSObject
@property (readonly) NSTimeInterval timestamp;
@property (readonly) UIKey *key;
@end
#endif


// ---- the display link, on both platforms ------------------------------------------
#define API_AVAILABLE(...)
typedef NSInteger NSQualityOfService;
enum { NSQualityOfServiceUserInteractive = 0x21 };
@interface NSCondition : NSObject
- (void)lock;
- (void)unlock;
- (void)wait;
- (BOOL)waitUntilDate:(NSDate *)limit;
- (void)signal;
- (void)broadcast;
@end
@interface NSThread : NSObject
- (instancetype)initWithTarget:(id)target selector:(SEL)selector object:(id)argument;
@property (copy) NSString *name;
@property NSQualityOfService qualityOfService;
- (void)start;
@end
@interface NSRunLoop (Current)
@property (class, readonly, strong) NSRunLoop *currentRunLoop;
@end
#ifndef PM_STUB_IOS
struct CAFrameRateRange { float minimum, maximum, preferred; };
CAFrameRateRange CAFrameRateRangeMake(float minimum, float maximum, float preferred);
#endif
@class CAMetalDisplayLink, CAMetalDisplayLinkUpdate;
@protocol CAMetalDisplayLinkDelegate
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update;
@end
@interface CAMetalDisplayLinkUpdate : NSObject
@property (readonly) id<CAMetalDrawable> drawable;
@property (readonly) double targetTimestamp;
@property (readonly) double targetPresentationTimestamp;
@end
@interface CAMetalDisplayLink : NSObject
- (instancetype)initWithMetalLayer:(CAMetalLayer *)layer;
@property (weak) id<CAMetalDisplayLinkDelegate> delegate;
@property float preferredFrameLatency;
@property CAFrameRateRange preferredFrameRateRange;
- (void)addToRunLoop:(NSRunLoop *)runloop forMode:(NSRunLoopMode)mode;
- (void)invalidate;
@end

#endif
