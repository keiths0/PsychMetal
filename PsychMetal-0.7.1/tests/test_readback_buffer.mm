// Exercise the actual texture-to-shared-buffer layout on a real GPU.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "PsychMetalReadback.h"
#include <vector>
#include <cassert>
#include <cstdio>
int main(){@autoreleasepool {
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
    if(!dev){puts("SKIP: no Metal device available.");return 77;}
    id<MTLCommandQueue> queue=[dev newCommandQueue];
    for(bool deep:{false,true}) {
        const size_t W=53,H=37,pitch=256;
        auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:deep?MTLPixelFormatBGR10A2Unorm:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;
        id<MTLTexture> tex=[dev newTextureWithDescriptor:desc];
        id<MTLBuffer> buf=[dev newBufferWithLength:pitch*H options:MTLResourceStorageModeShared];
        assert(tex && buf);
        for(int frame=0;frame<3;frame++) {
            std::vector<uint32_t> src(W*H);
            for(size_t y=0;y<H;y++)for(size_t x=0;x<W;x++) {
                uint32_t r=(x*17+y*3+frame*39)&(deep?1023:255),g=(x+y+frame*7)&(deep?1023:255),b=(y*13+frame)&(deep?1023:255);
                src[y*W+x]=deep?(r<<20)|(g<<10)|b|0xc0000000:(r<<16)|(g<<8)|b|0xff000000;
            }
            [tex replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:src.data() bytesPerRow:W*4];
            id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch*H];
            [blit endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
            for(size_t y=0;y<H;y++)assert(memcmp((uint8_t*)buf.contents+y*pitch,src.data()+y*W,W*4)==0);
            // Crop is a pointer offset into the padded source, not a CPU copy.
            const size_t cw=17,ch=11;const auto *s=(uint8_t*)buf.contents+3*pitch+2*4;
            if(deep){std::vector<uint16_t> rgb(cw*ch*3);pm::MutableWordView v;v.data=rgb.data();v.ndim=3;v.shape={ch,cw,3};v.strides={cw*6,6,2};pm::internal::unpackReadback10(s,pitch,v);
                for(size_t y=0;y<ch;y++)for(size_t x=0;x<cw;x++){auto p=src[(y+3)*W+x+2];assert(rgb[(y*cw+x)*3]==((p>>20)&1023));assert(rgb[(y*cw+x)*3+1]==((p>>10)&1023));assert(rgb[(y*cw+x)*3+2]==(p&1023));}}
            else{std::vector<uint8_t> rgb(cw*ch*3);pm::MutableByteView v;v.data=rgb.data();v.ndim=3;v.shape={ch,cw,3};v.strides={cw*3,3,1};pm::internal::unpackReadback8(s,pitch,v);
                for(size_t y=0;y<ch;y++)for(size_t x=0;x<cw;x++){auto p=src[(y+3)*W+x+2];assert(rgb[(y*cw+x)*3]==((p>>16)&255));assert(rgb[(y*cw+x)*3+1]==((p>>8)&255));assert(rgb[(y*cw+x)*3+2]==(p&255));}}
        }
    }
    puts("PASS: BGRA8/BGR10 GPU buffer blit, padded rows, crops, and successive frame replacement.");
}}
