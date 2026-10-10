// Fixed custom ABI and target/blend/coverage validation on a real Metal device.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include "../PsychMetalShaders.h"
#include "../PsychMetalCustomShader.h"
#include "../PsychMetalInternal.h"
struct U {float dst[4],params[16],viewport[4],maskA[4],maskB[4];};
static_assert(sizeof(U)==128);
int main(){@autoreleasepool{
 auto d=MTLCreateSystemDefaultDevice();if(!d){puts("SKIP: no Metal device available.");return 77;}
 auto options=[MTLCompileOptions new];if(@available(macOS 15.0,*))options.mathMode=MTLMathModeSafe;
 else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
 options.fastMathEnabled=NO;
#pragma clang diagnostic pop
 }
 NSError *error=nil;
 auto compile=[&](const std::string &program){auto full=pm::internal::customShaderSource(PMMetalSource,program);return [d newLibraryWithSource:[NSString stringWithUTF8String:full.c_str()] options:options error:&error];};
 assert(!compile("float4 psychmetal_main(no such program) {}"));assert(error.localizedDescription.length>0);
 auto lib=compile("float4 psychmetal_main(float2 pixel,float2 uv,constant float4 *p){return p[0];}");assert(lib);
 auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
 auto mask=[d newTextureWithDescriptor:td];__fp16 half=.5;[mask replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&half bytesPerRow:2];
 auto sd=[MTLSamplerDescriptor new];sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;auto sampler=[d newSamplerStateWithDescriptor:sd];auto queue=[d newCommandQueue];
 U u={{0,0,64,64},{.8,.4,.2,.5},{64,64,0,0},{1,.5,0,1},{0,0,0,0}};
 auto red=[&](id<MTLTexture> t,int x,int y){if(t.pixelFormat==MTLPixelFormatRGBA16Float){__fp16 p[4];[t getBytes:p bytesPerRow:8 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];return double(p[0]);}
 uint32_t p;[t getBytes:&p bytesPerRow:4 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];return t.pixelFormat==MTLPixelFormatBGRA8Unorm?double((p>>16)&255)/255:double((p>>20)&1023)/1023;};
 for(auto format:{MTLPixelFormatBGRA8Unorm,MTLPixelFormatBGR10A2Unorm,MTLPixelFormatRGBA16Float})for(int mode=0;mode<3;mode++)for(bool offscreen:{false,true}){
  auto pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"cvmain"];pd.fragmentFunction=[lib newFunctionWithName:@"cfmain"];auto a=pd.colorAttachments[0];a.pixelFormat=format;auto blend=pm::internal::blendFor(mode,false,offscreen);
  a.blendingEnabled=blend.enabled;a.sourceRGBBlendFactor=(MTLBlendFactor)blend.sourceRGB;a.destinationRGBBlendFactor=(MTLBlendFactor)blend.destinationRGB;a.sourceAlphaBlendFactor=(MTLBlendFactor)blend.sourceAlpha;a.destinationAlphaBlendFactor=(MTLBlendFactor)blend.destinationAlpha;
  auto pipeline=[d newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipeline);
  auto output=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:64 height:64 mipmapped:NO];output.storageMode=MTLStorageModeShared;output.usage=MTLTextureUsageRenderTarget;auto out=[d newTextureWithDescriptor:output];
  auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto c=pass.colorAttachments[0];c.texture=out;c.loadAction=MTLLoadActionClear;c.storeAction=MTLStoreActionStore;c.clearColor=MTLClearColorMake(.1,.1,.1,.25);
  auto cb=[queue commandBuffer];auto e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:pipeline];[e setVertexBytes:&u length:sizeof(u) atIndex:0];[e setFragmentBytes:&u length:sizeof(u) atIndex:0];[e setFragmentTexture:mask atIndex:0];[e setFragmentSamplerState:sampler atIndex:0];[e setScissorRect:MTLScissorRect{8,8,48,48}];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[e endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
  double q=16.5/32-1,alpha=.25*exp(-(2*q*q)/.5),expected=mode==0?.8*alpha+.1*(1-alpha):mode==1?.8*alpha+.1:offscreen?.8*alpha:.8;
  assert(fabs(red(out,16,16)-expected)<.007);assert(fabs(red(out,0,0)-.1)<.007);
 }
 puts("PASS: custom source errors, fixed uniform/parameter ABI, analytic/image masks, clip, blend and 8/10-bit/float targets.");
}}
