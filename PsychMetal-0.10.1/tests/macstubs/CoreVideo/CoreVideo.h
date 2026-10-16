// Stand-in for the CoreVideo declarations the engine uses: pixel buffers and the
// Metal texture cache that shows them to Metal without a copy.
#pragma once
#include "../macstubs.h"
#include "../CoreMedia/CoreMedia.h"
typedef int32_t CVReturn;
enum { kCVReturnSuccess = 0 };
typedef CVImageBufferRef CVPixelBufferRef;
typedef struct __CVPixelBufferPool *CVPixelBufferPoolRef;
CVReturn CVPixelBufferPoolCreatePixelBuffer(CFAllocatorRef, CVPixelBufferPoolRef, CVPixelBufferRef *pixelBufferOut);
void CVPixelBufferRelease(CVPixelBufferRef);
typedef struct __CVMetalTextureCache *CVMetalTextureCacheRef;
typedef CVImageBufferRef CVMetalTextureRef;
extern const CFStringRef kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferWidthKey,
    kCVPixelBufferHeightKey;
enum { kCVPixelFormatType_32BGRA = 0x42475241 };
size_t CVPixelBufferGetWidth(CVPixelBufferRef);
size_t CVPixelBufferGetHeight(CVPixelBufferRef);
CVReturn CVMetalTextureCacheCreate(CFAllocatorRef, CFDictionaryRef cacheAttributes, id<MTLDevice> metalDevice,
                                   CFDictionaryRef textureAttributes, CVMetalTextureCacheRef *cacheOut);
CVReturn CVMetalTextureCacheCreateTextureFromImage(CFAllocatorRef, CVMetalTextureCacheRef, CVImageBufferRef sourceImage,
                                                   CFDictionaryRef textureAttributes, MTLPixelFormat pixelFormat,
                                                   size_t width, size_t height, size_t planeIndex, CVMetalTextureRef *textureOut);
id<MTLTexture> CVMetalTextureGetTexture(CVMetalTextureRef);
void CVMetalTextureCacheFlush(CVMetalTextureCacheRef, uint64_t options);
