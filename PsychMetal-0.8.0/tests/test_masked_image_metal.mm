// Actual masked still-image shader: independent offscreen Metal pixel checks.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include "../PsychMetalShaders.h"
#include "../PsychMetalInternal.h"
struct U {float dst[4],src[4],tint[4],size[2],angle,mono,maskA[4],maskB[4];};
static_assert(sizeof(U)==96);
int main(){@autoreleasepool{
 auto d=MTLCreateSystemDefaultDevice();if(!d){puts("SKIP: no Metal device available.");return 77;}
 NSError *error=nil;auto lib=[d newLibraryWithSource:[NSString stringWithUTF8String:PMMetalSource] options:nil error:&error];
 if(!lib){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
 auto texture=[&](MTLPixelFormat format,int w,int h,MTLTextureUsage usage){
  auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];td.usage=usage;td.storageMode=MTLStorageModeShared;
  auto t=[d newTextureWithDescriptor:td];assert(t);return t;
 };
 auto source=texture(MTLPixelFormatRGBA16Float,2,2,MTLTextureUsageShaderRead);
 __fp16 pixels[16]={.8,.4,.2,.5, .2,.6,.8,1, .2,.6,.8,1, .8,.4,.2,.5};
 [source replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
 auto mask=texture(MTLPixelFormatR16Float,2,2,MTLTextureUsageShaderRead);__fp16 masks[4]={.5,.5,.5,.5};
 [mask replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:masks bytesPerRow:4];
 auto sd=[MTLSamplerDescriptor new];sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterNearest;sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
 auto nearest=[d newSamplerStateWithDescriptor:sd];sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;auto linear=[d newSamplerStateWithDescriptor:sd];
 auto queue=[d newCommandQueue];
 U u={{0,0,64,64},{0,0,1,1},{1,.5,1,.8},{64,64},0,0,{1,.5,0,1},{0,0,0,0}};
 auto render=[&](MTLPixelFormat format,int mode,bool premultiplied,bool offscreen,bool bilinear=false){
  auto desc=[MTLRenderPipelineDescriptor new];desc.vertexFunction=[lib newFunctionWithName:@"mvmain"];desc.fragmentFunction=[lib newFunctionWithName:@"mfmain"];
  auto a=desc.colorAttachments[0];a.pixelFormat=format;auto b=pm::internal::blendFor(mode,premultiplied,offscreen);
  a.blendingEnabled=b.enabled;a.sourceRGBBlendFactor=(MTLBlendFactor)b.sourceRGB;a.destinationRGBBlendFactor=(MTLBlendFactor)b.destinationRGB;
  a.sourceAlphaBlendFactor=(MTLBlendFactor)b.sourceAlpha;a.destinationAlphaBlendFactor=(MTLBlendFactor)b.destinationAlpha;
  auto pipeline=[d newRenderPipelineStateWithDescriptor:desc error:&error];assert(pipeline);
  auto out=texture(format,64,64,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead);
  auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto c=pass.colorAttachments[0];c.texture=out;c.loadAction=MTLLoadActionClear;c.storeAction=MTLStoreActionStore;c.clearColor=MTLClearColorMake(.1,.1,.1,.25);
  auto e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:pipeline];[e setVertexBytes:&u length:sizeof(u) atIndex:0];[e setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [e setFragmentTexture:source atIndex:0];[e setFragmentTexture:mask atIndex:1];[e setFragmentSamplerState:(bilinear?linear:nearest) atIndex:0];[e setFragmentSamplerState:linear atIndex:1];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[e endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);return out;
 };
 auto rgb=[&](id<MTLTexture> t,int x,int y){
  if(t.pixelFormat==MTLPixelFormatRGBA16Float){__fp16 p[4];[t getBytes:p bytesPerRow:8 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];return double(p[0]);}
  uint32_t p;[t getBytes:&p bytesPerRow:4 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];
  return t.pixelFormat==MTLPixelFormatBGRA8Unorm ? double((p>>16)&255)/255 : double((p>>20)&1023)/1023;
 };
 // Source alpha, image mask, Gaussian and tint opacity multiply; exact blend factors.
 for(int premul=0;premul<2;premul++){
  u.mono=premul?3:0;
  auto data=std::vector<__fp16>(pixels,pixels+16);
  if(premul)for(int i=0;i<4;i++)for(int ch=0;ch<3;ch++)data[i*4+ch]*=data[i*4+3];
  [source replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:data.data() bytesPerRow:16];
  for(int mode=0;mode<3;mode++)for(bool offscreen:{false,true})for(auto format:{MTLPixelFormatBGRA8Unorm,MTLPixelFormatBGR10A2Unorm,MTLPixelFormatRGBA16Float}){
   auto out=render(format,mode,premul,offscreen);double q=-.484375,coverage=.5*exp(-(2*q*q)/(.5));double alpha=.5*.8*coverage;
   double expected=mode==0?.8*alpha+.1*(1-alpha):mode==1?.8*alpha+.1:(premul||offscreen)?.8*alpha:.8;
   assert(fabs(rgb(out,16,16)-expected)<.007);
  }
 }
 [source replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:pixels bytesPerRow:16];u.mono=0;u.maskA[0]=-1;
 u.mono=1;auto gray=render(MTLPixelFormatRGBA16Float,0,false,false);assert(fabs(rgb(gray,16,16)-.38)<.002);u.mono=0;
 // Crop the right half of the source, keeping destination mask coordinates.
 u.src[0]=.5;auto out=render(MTLPixelFormatRGBA16Float,2,false,false);assert(fabs(rgb(out,16,16)-.2)<.002);
 u.src[0]=0;u.angle=float(M_PI);out=render(MTLPixelFormatRGBA16Float,2,false,false);assert(fabs(rgb(out,16,48)-.2)<.002);
 // Bilinear blend at the source centre; tint/mask do not resample the source.
 u.angle=0;out=render(MTLPixelFormatRGBA16Float,2,false,false,true);
 double uv=31.5/64,frac=uv*2-.5,expected=.8*((1-frac)*(1-frac)+frac*frac)+.2*(2*frac*(1-frac));
 assert(fabs(rgb(out,31,31)-expected)<.002);
 // A smaller rotated destination leaves the cleared corners untouched.
 u.dst[0]=u.dst[1]=16;u.dst[2]=u.dst[3]=48;u.angle=float(M_PI/4);
 out=render(MTLPixelFormatRGBA16Float,0,false,false);assert(fabs(rgb(out,0,0)-.1)<.002);
 puts("PASS: masked-image shader crops, rotation, filtering, multiplicative alpha, straight/premultiplied sources, blends and 8/10-bit/float targets.");
}}
