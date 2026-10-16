#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
struct Uniform {uint32_t kind=0,channels=4,premultiplied=0,radius=0;float v[32]{};};
int main(){@autoreleasepool{
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device){std::cout<<"SKIP: no Metal device for imaging pixels.\n";return 77;}
 NSError *error=nil;NSString *source=[NSString stringWithContentsOfFile:@"PsychMetalShaders.metal" encoding:NSUTF8StringEncoding error:&error];assert(source);
 id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];if(!lib){std::cerr<<error.localizedDescription.UTF8String;return 1;}
 auto pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"evmain"];pd.fragmentFunction=[lib newFunctionWithName:@"ifmain"];
 pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;auto pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipeline);
 const size_t W=7,H=5;std::vector<float> input(W*H*4);
 for(size_t y=0;y<H;y++)for(size_t x=0;x<W;x++){auto at=(y*W+x)*4;input[at]=float(x)/8;input[at+1]=float(y)/8;input[at+2]=2;input[at+3]=1;}
 auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:W height:H mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
 auto src=[device newTextureWithDescriptor:td];[src replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:input.data() bytesPerRow:W*16];
 td.pixelFormat=MTLPixelFormatRGBA16Float;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;auto dest=[device newTextureWithDescriptor:td];auto queue=[device newCommandQueue];
 auto run=[&](Uniform u){auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=dest;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
 auto re=[cb renderCommandEncoderWithDescriptor:pass];[re setRenderPipelineState:pipeline];[re setFragmentTexture:src atIndex:0];[re setFragmentBytes:&u length:sizeof(u) atIndex:0];[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[re endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
 std::vector<__fp16> out(W*H*4);[dest getBytes:out.data() bytesPerRow:W*8 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];return out;};
 Uniform u;u.kind=3;u.v[0]=4;auto out=run(u);assert(std::abs(float(out[2])-8)<.001); // HDR not clipped to 1
 u={};u.kind=4;u.v[2]=1;u.v[5]=1;u.v[8]=1;out=run(u);assert(float(out[0])==2&&float(out[2])==0); // channel permutation
 u={};u.kind=5;u.radius=3;u.v[0]=3;u.v[1+1*3+0]=1;out=run(u);assert(float(out[(2*W+2)*4])==input[(2*W+3)*4]); // convolution reversal
 u={};u.kind=6;u.v[0]=1;u.v[4]=1;u.v[2]=1;out=run(u);assert(float(out[(W+2)*4])==input[(W+3)*4]); // pixel inverse translation
 u={};u.kind=1;u.radius=1;u.v[0]=.5;u.v[1]=.25;out=run(u);assert(std::abs(float(out[0])-.03125)<.001); // clamped boundary
 std::cout<<"PASS: real Metal HDR-preserving exposure, color matrix, convolution direction, inverse affine and blur pixels.\n";
}}
