// Offscreen shader/pixel validation. SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include "../PsychMetalShaders.h"
int main() { @autoreleasepool {
 id<MTLDevice> d=MTLCreateSystemDefaultDevice();
 if(!d) { fprintf(stderr,"SKIP: no Metal device available.\n"); return 77; }
 NSError *error=nil;
 id<MTLLibrary> lib=[d newLibraryWithSource:[NSString stringWithUTF8String:PMMetalSource] options:nil error:&error];
 if(!lib) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1; }
 for(NSString *prefix in @[@"s",@"t"]) {
  MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];
  p.vertexFunction=[lib newFunctionWithName:[prefix stringByAppendingString:@"vmain"]];
  p.fragmentFunction=[lib newFunctionWithName:[prefix stringByAppendingString:@"fmain"]];
  p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  if(![d newRenderPipelineStateWithDescriptor:p error:&error]) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1; }
 }
 MTLRenderPipelineDescriptor *p=[MTLRenderPipelineDescriptor new];
 p.vertexFunction=[lib newFunctionWithName:@"tvmain"];p.fragmentFunction=[lib newFunctionWithName:@"tfmain"];
 p.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
 p.colorAttachments[0].blendingEnabled=YES;
 p.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;
 p.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
 p.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;
 p.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
 id<MTLRenderPipelineState> pipeline=[d newRenderPipelineStateWithDescriptor:p error:&error];assert(pipeline);
 id<MTLCommandQueue> queue=[d newCommandQueue];
 MTLSamplerDescriptor *sampler=[MTLSamplerDescriptor new];sampler.minFilter=sampler.magFilter=MTLSamplerMinMagFilterNearest;
 id<MTLSamplerState> state=[d newSamplerStateWithDescriptor:sampler];
 for(int mono=0;mono<=1;mono++) {
  auto inputDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mono?MTLPixelFormatR16Float:MTLPixelFormatRGBA16Float width:1 height:1 mipmapped:NO];
  inputDesc.storageMode=MTLStorageModeShared;inputDesc.usage=MTLTextureUsageShaderRead;
  id<MTLTexture> input=[d newTextureWithDescriptor:inputDesc];
  __fp16 values[4]={1,0,0,(__fp16).5};if(mono)values[0]=(__fp16).25;
  [input replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:values bytesPerRow:mono?2:8];
  auto outputDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
  outputDesc.storageMode=MTLStorageModeShared;outputDesc.usage=MTLTextureUsageRenderTarget;
  id<MTLTexture> output=[d newTextureWithDescriptor:outputDesc];
  MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture=output;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
  pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
  auto cb=[queue commandBuffer];auto enc=[cb renderCommandEncoderWithDescriptor:pass];
  struct {float dst[4],src[4],tint[4],size[2],angle,mono;} u={{0,0,4,4},{0,0,1,1},{1,1,1,1},{4,4},0,float(mono)};
  [enc setRenderPipelineState:pipeline];[enc setVertexBytes:&u length:sizeof(u) atIndex:0];
  [enc setFragmentTexture:input atIndex:0];[enc setFragmentSamplerState:state atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[enc endEncoding];[cb commit];[cb waitUntilCompleted];
  assert(cb.status==MTLCommandBufferStatusCompleted);unsigned char pixels[64];
  [output getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
  for(int i=0;i<16;i++) {
   assert(std::abs(int(pixels[4*i])-(mono?64:128))<=1);
   assert(std::abs(int(pixels[4*i+1])-(mono?64:0))<=1);
   assert(std::abs(int(pixels[4*i+2])-(mono?64:128))<=1);
   assert(pixels[4*i+3]==255);
  }
 }
 puts("PASS: both Metal shader pipelines, grayscale channel replication, RGBA blending and output alpha.");
 return 0;
} }
