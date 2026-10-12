// Offscreen shader/pixel validation. SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include "../PsychMetalShaders.h"
#include "../PsychMetalInternal.h"
int main() { @autoreleasepool {
 id<MTLDevice> d=MTLCreateSystemDefaultDevice();
 if(!d) { fprintf(stderr,"SKIP: no Metal device available.\n"); return 77; }
 NSError *error=nil;
 id<MTLLibrary> lib=[d newLibraryWithSource:[NSString stringWithUTF8String:PMMetalSource] options:nil error:&error];
 if(!lib) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1; }
 for(NSString *prefix in @[@"s",@"t",@"p"]) {
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
 // --- 0.6.0: every pipeline for every target the engine renders into ---------------------------
 for(NSNumber *format in @[@(MTLPixelFormatBGRA8Unorm),@(MTLPixelFormatBGR10A2Unorm),@(MTLPixelFormatRGBA16Float)]) {
  for(NSString *prefix in @[@"s",@"t",@"e"]) {
   if([prefix isEqualToString:@"e"] && format.unsignedIntegerValue==MTLPixelFormatRGBA16Float) continue;
   MTLRenderPipelineDescriptor *q=[MTLRenderPipelineDescriptor new];
   q.vertexFunction=[lib newFunctionWithName:[prefix stringByAppendingString:@"vmain"]];
   q.fragmentFunction=[lib newFunctionWithName:[prefix stringByAppendingString:@"fmain"]];
   if(!q.vertexFunction || !q.fragmentFunction) { fprintf(stderr,"Missing shader function %svmain/%sfmain.\n",prefix.UTF8String,prefix.UTF8String);return 1; }
   q.colorAttachments[0].pixelFormat=(MTLPixelFormat)format.unsignedIntegerValue;
   if(![d newRenderPipelineStateWithDescriptor:q error:&error]) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1; }
  }
 }
 // A texture, a render target and one draw of `count` vertices into it.
 auto makeTexture=[&](MTLPixelFormat format,NSUInteger w,NSUInteger h,MTLTextureUsage usage,const void *bytes,NSUInteger rowBytes) {
  auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
  desc.storageMode=MTLStorageModeShared;desc.usage=usage;
  id<MTLTexture> t=[d newTextureWithDescriptor:desc];assert(t);
  if(bytes) [t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:bytes bytesPerRow:rowBytes];
  return t;
 };
 auto passInto=[&](id<MTLTexture> target) {
  MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
  pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
  return pass;
 };
 // Text: an R8 coverage mask (mono 2) is alpha, and the tint is the colour.
 {
  unsigned char coverage=128;
  id<MTLTexture> mask=makeTexture(MTLPixelFormatR8Unorm,1,1,MTLTextureUsageShaderRead,&coverage,1);
  id<MTLTexture> output=makeTexture(MTLPixelFormatBGRA8Unorm,4,4,MTLTextureUsageRenderTarget,nullptr,0);
  auto cb=[queue commandBuffer];auto enc=[cb renderCommandEncoderWithDescriptor:passInto(output)];
  struct {float dst[4],src[4],tint[4],size[2],angle,mono;} u={{0,0,4,4},{0,0,1,1},{1,1,0,1},{4,4},0,2};
  [enc setRenderPipelineState:pipeline];[enc setVertexBytes:&u length:sizeof(u) atIndex:0];
  [enc setFragmentTexture:mask atIndex:0];[enc setFragmentSamplerState:state atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[enc endEncoding];[cb commit];[cb waitUntilCompleted];
  assert(cb.status==MTLCommandBufferStatusCompleted);unsigned char pixels[64];
  [output getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
  for(int i=0;i<16;i++) {      // half-covered yellow over blue; bytes are B, G, R, A
   assert(std::abs(int(pixels[4*i])-127)<=1);
   assert(std::abs(int(pixels[4*i+1])-128)<=1);
   assert(std::abs(int(pixels[4*i+2])-128)<=1);
  }
 }
 // --- offscreen windows: blended by the engine's own rule, pm::internal::blendFor ----------------------
 // A texture pipeline for one target format, blend mode, kind of source and kind of target.
 auto blended=[&](MTLPixelFormat format,int mode,bool premultipliedSource,bool premultipliedTarget) {
  const pm::internal::Blend b=pm::internal::blendFor(mode,premultipliedSource,premultipliedTarget);
  MTLRenderPipelineDescriptor *q=[MTLRenderPipelineDescriptor new];
  q.vertexFunction=[lib newFunctionWithName:@"tvmain"];q.fragmentFunction=[lib newFunctionWithName:@"tfmain"];
  q.colorAttachments[0].pixelFormat=format;
  if(b.enabled) {
   q.colorAttachments[0].blendingEnabled=YES;
   q.colorAttachments[0].sourceRGBBlendFactor=(MTLBlendFactor)b.sourceRGB;
   q.colorAttachments[0].sourceAlphaBlendFactor=(MTLBlendFactor)b.sourceAlpha;
   q.colorAttachments[0].destinationRGBBlendFactor=(MTLBlendFactor)b.destinationRGB;
   q.colorAttachments[0].destinationAlphaBlendFactor=(MTLBlendFactor)b.destinationAlpha;
  }
  NSError *failure=nil;
  id<MTLRenderPipelineState> made=[d newRenderPipelineStateWithDescriptor:q error:&failure];
  if(!made) fprintf(stderr,"%s\n",failure.localizedDescription.UTF8String);
  assert(made);
  return made;
 };
 for(NSNumber *format in @[@(MTLPixelFormatBGRA8Unorm),@(MTLPixelFormatBGR10A2Unorm),@(MTLPixelFormatRGBA16Float)])
  for(int mode=0;mode<3;mode++) for(int source=0;source<2;source++) for(int target=0;target<2;target++)
   blended((MTLPixelFormat)format.unsignedIntegerValue,mode,source==1,target==1);
 // One texture drawn over all of a 4x4 target, which is first cleared to `clear`, or kept when there is none.
 auto drawInto=[&](id<MTLTexture> target,const double *clear,id<MTLRenderPipelineState> how,id<MTLTexture> what,
                   float tintAlpha,float mono) {
  MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture=target;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
  pass.colorAttachments[0].loadAction=clear?MTLLoadActionClear:MTLLoadActionLoad;
  if(clear) pass.colorAttachments[0].clearColor=MTLClearColorMake(clear[0],clear[1],clear[2],clear[3]);
  auto cb=[queue commandBuffer];auto enc=[cb renderCommandEncoderWithDescriptor:pass];
  struct {float dst[4],src[4],tint[4],size[2],angle,mono;} u={{0,0,4,4},{0,0,1,1},{1,1,1,tintAlpha},{4,4},0,mono};
  [enc setRenderPipelineState:how];[enc setVertexBytes:&u length:sizeof(u) atIndex:0];
  [enc setFragmentTexture:what atIndex:0];[enc setFragmentSamplerState:state atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[enc endEncoding];[cb commit];[cb waitUntilCompleted];
  assert(cb.status==MTLCommandBufferStatusCompleted);
 };
 // Every pixel of an 8-bit target is this colour, to one level.
 auto shows=[&](id<MTLTexture> target,int r,int g,int b,const char *what) {
  unsigned char px[64];
  [target getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
  for(int i=0;i<16;i++)      // bytes are B, G, R, A
   if(std::abs(int(px[4*i+2])-r)>1 || std::abs(int(px[4*i+1])-g)>1 || std::abs(int(px[4*i])-b)>1) {
    fprintf(stderr,"%s: R %d G %d B %d; expected %d, %d, %d.\n",what,px[4*i+2],px[4*i+1],px[4*i],r,g,b);
    return false;
   }
  return true;
 };
 {
  const MTLTextureUsage both=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
  const double transparent[4]={0,0,0,0},black[4]={0,0,0,1},blue[4]={0,0,1,1},grey[4]={.25,.25,.25,1};
  __fp16 white[4]={1,1,1,(__fp16).5},red[4]={1,0,0,(__fp16).5};
  id<MTLTexture> halfWhite=makeTexture(MTLPixelFormatRGBA16Float,1,1,MTLTextureUsageShaderRead,white,8);
  id<MTLTexture> halfRed=makeTexture(MTLPixelFormatRGBA16Float,1,1,MTLTextureUsageShaderRead,red,8);
  id<MTLTexture> window=makeTexture(MTLPixelFormatBGRA8Unorm,4,4,both,nullptr,0);
  id<MTLTexture> off=makeTexture(MTLPixelFormatRGBA16Float,4,4,both,nullptr,0);
  id<MTLTexture> off2=makeTexture(MTLPixelFormatRGBA16Float,4,4,both,nullptr,0);
  // An image is mono 0 and an offscreen window mono 3, in the pipelines the engine uses for each.
  id<MTLRenderPipelineState> imageToWindow=blended(MTLPixelFormatBGRA8Unorm,0,false,false);
  id<MTLRenderPipelineState> imageToOff=blended(MTLPixelFormatRGBA16Float,0,false,true);
  id<MTLRenderPipelineState> imageCopiedToOff=blended(MTLPixelFormatRGBA16Float,2,false,true);
  id<MTLRenderPipelineState> offToWindow=blended(MTLPixelFormatBGRA8Unorm,0,true,false);
  id<MTLRenderPipelineState> offAddedToWindow=blended(MTLPixelFormatBGRA8Unorm,1,true,false);
  id<MTLRenderPipelineState> offToOff=blended(MTLPixelFormatRGBA16Float,0,true,true);
  bool ok=true;
  // Half-alpha white: on the window, and through a transparent offscreen window. Both are half white.
  drawInto(window,black,imageToWindow,halfWhite,1,0);
  ok=shows(window,128,128,128,"half-alpha white drawn on the window")&&ok;
  drawInto(off,transparent,imageToOff,halfWhite,1,0);
  drawInto(window,black,offToWindow,off,1,3);
  ok=shows(window,128,128,128,"half-alpha white drawn through an offscreen window")&&ok;
  drawInto(window,black,offToWindow,off,.5f,3);
  ok=shows(window,64,64,64,"that offscreen window drawn at global alpha 0.5")&&ok;
  // Two overlapping layers over blue: directly, through one offscreen window, and through two.
  drawInto(window,blue,imageToWindow,halfRed,1,0);
  drawInto(window,nullptr,imageToWindow,halfWhite,1,0);
  ok=shows(window,191,128,191,"two half-alpha layers drawn on the window")&&ok;
  drawInto(off,transparent,imageToOff,halfRed,1,0);
  drawInto(off,nullptr,imageToOff,halfWhite,1,0);
  drawInto(window,blue,offToWindow,off,1,3);
  ok=shows(window,191,128,191,"two half-alpha layers drawn through an offscreen window")&&ok;
  drawInto(off2,transparent,offToOff,off,1,3);
  drawInto(window,blue,offToWindow,off2,1,3);
  ok=shows(window,191,128,191,"an offscreen window drawn through a second one")&&ok;
  // A colour copied into an offscreen window replaces what was there and is stored at its alpha.
  drawInto(off,nullptr,imageCopiedToOff,halfRed,1,0);
  drawInto(window,blue,offToWindow,off,1,3);
  ok=shows(window,128,0,128,"half-alpha red copied into an offscreen window")&&ok;
  drawInto(window,blue,offToWindow,off,.5f,3);
  ok=shows(window,64,0,191,"that offscreen window drawn at global alpha 0.5")&&ok;
  drawInto(window,grey,offAddedToWindow,off,1,3);
  ok=shows(window,191,64,64,"that offscreen window added to grey")&&ok;
  if(!ok) return 1;
 }
 // The encode pass: a linear half-float frame written as display values, by exponents and by table.
 __fp16 frame[16*4];
 for(int i=0;i<16;i++) { frame[4*i]=(__fp16).25;frame[4*i+1]=(__fp16).5;frame[4*i+2]=(__fp16)1;frame[4*i+3]=(__fp16)1; }
 id<MTLTexture> source=makeTexture(MTLPixelFormatRGBA16Float,4,4,MTLTextureUsageShaderRead,frame,32);
 float table[2*4]={0,1,.5f,1, 1,0,.5f,1};   // R rises, G falls, B is flat
 id<MTLTexture> lut=makeTexture(MTLPixelFormatRGBA32Float,2,1,MTLTextureUsageShaderRead,table,32);
 struct EncodeUniforms { float exponent[4]; uint32_t mode,n,pad[2]; };
 assert(sizeof(EncodeUniforms)==32);
 auto encode=[&](MTLPixelFormat format,EncodeUniforms u,void *out,NSUInteger rowBytes) {
  MTLRenderPipelineDescriptor *q=[MTLRenderPipelineDescriptor new];
  q.vertexFunction=[lib newFunctionWithName:@"evmain"];q.fragmentFunction=[lib newFunctionWithName:@"efmain"];
  q.colorAttachments[0].pixelFormat=format;
  NSError *failure=nil;
  id<MTLRenderPipelineState> encodeState=[d newRenderPipelineStateWithDescriptor:q error:&failure];assert(encodeState);
  id<MTLTexture> output=makeTexture(format,4,4,MTLTextureUsageRenderTarget,nullptr,0);
  auto cb=[queue commandBuffer];auto enc=[cb renderCommandEncoderWithDescriptor:passInto(output)];
  [enc setRenderPipelineState:encodeState];[enc setFragmentTexture:source atIndex:0];[enc setFragmentTexture:lut atIndex:1];
  [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];[cb commit];[cb waitUntilCompleted];
  assert(cb.status==MTLCommandBufferStatusCompleted);
  [output getBytes:out bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
 };
 unsigned char bytes[64];
 encode(MTLPixelFormatBGRA8Unorm,EncodeUniforms{{.5f,1,2,1},1,0,{0,0}},bytes,16);
 for(int i=0;i<16;i++) {      // R 0.25^0.5, G 0.5^1, B 1^2; bytes are B, G, R, A
  assert(bytes[4*i]==255);
  assert(std::abs(int(bytes[4*i+1])-128)<=1);
  assert(std::abs(int(bytes[4*i+2])-128)<=1);
  assert(bytes[4*i+3]==255);
 }
 encode(MTLPixelFormatBGRA8Unorm,EncodeUniforms{{1,1,1,1},2,2,{0,0}},bytes,16);
 for(int i=0;i<16;i++) {      // table: R 0.25, G 1-0.5, B 0.5
  assert(std::abs(int(bytes[4*i+2])-64)<=1);
  assert(std::abs(int(bytes[4*i+1])-128)<=1);
  assert(std::abs(int(bytes[4*i])-128)<=1);
 }
 // Ten bits: the word holds blue in bits 0-9, green in 10-19, red in 20-29, as GetImage unpacks it.
 uint32_t words[16];
 encode(MTLPixelFormatBGR10A2Unorm,EncodeUniforms{{1,1,1,1},0,0,{0,0}},words,16);
 for(int i=0;i<16;i++) {
  int blue=int(words[i]&1023),green=int((words[i]>>10)&1023),red=int((words[i]>>20)&1023);
  if(std::abs(red-256)>1 || std::abs(green-512)>1 || blue!=1023) {
   fprintf(stderr,"BGR10A2 word %08x unpacks to R %d G %d B %d; expected 256, 512, 1023.\n",words[i],red,green,blue);return 1;
  }
 }
 // Batch breaks must select later shapes without rebinding an unaligned buffer.
 // Draw index 2 (previously byte offset 128), then index 3 using baseInstance.
 {
  struct Shape { float rect[4],color[4]; uint32_t kind; float param,pad[2],extra[4]; };
  static_assert(sizeof(Shape)==64,"Shape shader layout");
  Shape shapes[4] = {};
  for(int i=0;i<4;i++) {
   shapes[i].rect[0]=0; shapes[i].rect[1]=0; shapes[i].rect[2]=4; shapes[i].rect[3]=4;
   shapes[i].color[0]=float(i==2); shapes[i].color[1]=float(i==3); shapes[i].color[3]=1;
  }
  id<MTLBuffer> buffer=[d newBufferWithBytes:shapes length:sizeof(shapes) options:MTLResourceStorageModeShared];
  MTLRenderPipelineDescriptor *desc=[MTLRenderPipelineDescriptor new];
  desc.vertexFunction=[lib newFunctionWithName:@"svmain"];
  desc.fragmentFunction=[lib newFunctionWithName:@"sfmain"];
  desc.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  auto pipeline=[d newRenderPipelineStateWithDescriptor:desc error:&error]; assert(pipeline);
  for(NSUInteger start=2;start<=3;start++) {
   auto output=makeTexture(MTLPixelFormatBGRA8Unorm,4,4,MTLTextureUsageRenderTarget,nullptr,0);
   auto cb=[queue commandBuffer]; auto enc=[cb renderCommandEncoderWithDescriptor:passInto(output)];
   float size[2]={4,4};
   [enc setRenderPipelineState:pipeline]; [enc setVertexBuffer:buffer offset:0 atIndex:0];
   [enc setVertexBytes:size length:sizeof(size) atIndex:1];
   [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1 baseInstance:start];
   [enc endEncoding]; [cb commit]; [cb waitUntilCompleted]; assert(cb.status==MTLCommandBufferStatusCompleted);
   unsigned char pixel[4]; [output getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(2,2,1,1) mipmapLevel:0];
   assert(pixel[0]==0 && pixel[1]==(start==3?255:0) && pixel[2]==(start==2?255:0));
  }
 }
 puts("PASS: every Metal pipeline for 8-bit, 10-bit and linear targets; grayscale replication, RGBA blending, output alpha, "
      "text coverage masks, offscreen windows (half alpha, global alpha, overlapping layers, one through another, copy "
      "and additive), the encode pass by exponent and by table, and the 10-bit word layout.");
 return 0;
} }
