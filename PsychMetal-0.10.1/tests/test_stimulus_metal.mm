// Real offscreen Metal pixel checks for the procedural shader. No window needed.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include "../PsychMetalShaders.h"
#include "../PsychMetalInternal.h"
struct U {float dst[4],mean[4],wave[4],noise[4],aperture[4],viewport[4],maskA[4],maskB[4];};
int main(){@autoreleasepool{
 id<MTLDevice>d=MTLCreateSystemDefaultDevice();if(!d){puts("SKIP: no Metal device available.");return 77;}
 NSError*error=nil;
 auto lib=[d newLibraryWithSource:[NSString stringWithUTF8String:PMMetalSource] options:nil error:&error];
 if(!lib){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
 auto pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"pvmain"];pd.fragmentFunction=[lib newFunctionWithName:@"pfmain"];
 pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
 pd.colorAttachments[0].blendingEnabled=YES;pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;
 pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
 auto pipeline=[d newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipeline);
 auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:64 height:64 mipmapped:NO];
 td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;
 auto out=[d newTextureWithDescriptor:td];assert(out);
 auto md=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:2 height:1 mipmapped:NO];md.storageMode=MTLStorageModeShared;md.usage=MTLTextureUsageShaderRead;
 auto mask=[d newTextureWithDescriptor:md];assert(mask);uint8_t white[2]={255,255};[mask replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:white bytesPerRow:2];
 auto sd=[MTLSamplerDescriptor new];sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
 auto sampler=[d newSamplerStateWithDescriptor:sd];auto queue=[d newCommandQueue];
 U u={{0,0,64,64},{.5,.5,.5,1},{.125,0,0,1},{7,1,0,0},{0,0,.35,0},{64,64,0,0},{-1,0,0,0},{0,0,0,0}};
 auto render=[&](){
  auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=out;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
  auto enc=[cb renderCommandEncoderWithDescriptor:pass];[enc setRenderPipelineState:pipeline];[enc setVertexBytes:&u length:sizeof(u) atIndex:0];[enc setFragmentBytes:&u length:sizeof(u) atIndex:0];[enc setFragmentTexture:mask atIndex:0];[enc setFragmentSamplerState:sampler atIndex:0];[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[enc endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
  std::vector<__fp16>v(64*64*4);[out getBytes:v.data() bytesPerRow:64*8 fromRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0];return v;
 };
 auto a=render();for(int y=0;y<64;y++)for(int x=0;x<64;x++){double expected=.5+.5*cos(2*M_PI*.125*(x+.5-32));assert(fabs(a[(y*64+x)*4]-expected)<.002);}
 u.wave[2]=M_PI;auto b=render();for(int i=0;i<64*64;i++)assert(fabs(float(a[i*4])+float(b[i*4])-1)<.002);
 u.wave[1]=M_PI/2;u.wave[2]=0;b=render();for(int y=0;y<64;y++)for(int x=0;x<64;x++)assert(fabs(b[(y*64+x)*4]-a[(x*64+y)*4])<.002);
 u.aperture[0]=1;auto noise=render();b=render();assert(noise==b);
 u.noise[0]=8;b=render();assert(noise!=b);u.noise[0]=7;
 u.noise[1]=2;b=render();for(int y=0;y<64;y+=2)for(int x=0;x<64;x+=2){assert(b[(y*64+x)*4]==b[(y*64+x+1)*4]);assert(b[(y*64+x)*4]==b[((y+1)*64+x)*4]);}
 u.noise[1]=1;u.dst[2]=32;b=render();for(int y=0;y<64;y++)for(int x=0;x<32;x++)assert(noise[(y*64+x)*4]==b[(y*64+x)*4]);u.dst[2]=64;
 uint8_t half[2]={0,255};[mask replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:half bytesPerRow:2];b=render();for(int y=0;y<64;y++){assert(b[(y*64+2)*4]==0);assert(b[(y*64+61)*4]==noise[(y*64+61)*4]);}
 [mask replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:white bytesPerRow:2];u.wave[3]=0;u.aperture[1]=1;b=render();assert(b[0]==0 && fabs(b[(32*64+32)*4]-.5)<.002);
 u.aperture[1]=2;b=render();assert(b[0]<b[(32*64+32)*4]);

 // Analytic masks: compare sample coverage against independent scalar formulas.
 u.aperture[1]=0;u.aperture[0]=0;u.wave[3]=0;u.maskA[0]=1;u.maskA[1]=.35;
 u.maskB[0]=0;u.maskB[1]=.25;u.maskB[2]=-.125;u.maskB[3]=0;
 b=render();for(int y=0;y<64;y++)for(int x=0;x<64;x++) {
   double dx=(x+.5)/32-1-.25,dy=(y+.5)/32-1+.125;
   assert(fabs(b[(y*64+x)*4]-.5*exp(-(dx*dx+dy*dy)/(2*.35*.35)))<.002);
 }
 auto gaussian=b;u.maskB[3]=1;b=render();for(int i=0;i<64*64;i++)assert(fabs(float(b[i*4])+float(gaussian[i*4])-.5)<.002);
 u.maskB[1]=u.maskB[2]=u.maskB[3]=0;u.maskA[0]=2;u.maskA[2]=.4;u.maskA[3]=1;u.maskB[0]=.1;
 b=render();assert(b[(32*64+32)*4]==0 && b[0]==0 && fabs(b[(32*64+54)*4]-.5)<.002);
 for(int y=0;y<64;y++)for(int x=0;x<64;x++){
   double rad=hypot((x+.5)/32-1,(y+.5)/32-1);
   auto fade=[](double t){t=fmax(0,fmin(1,t));return .5-.5*cos(M_PI*t);};
   double expected=.5*fade((rad-.4)/.1)*fade((1-rad)/.1);
   assert(fabs(b[(y*64+x)*4]-expected)<.002);
 }
 u.maskA[0]=3;u.maskB[0]=.2;b=render();
 for(int y=0;y<64;y++)for(int x=0;x<64;x++){
   double rad=hypot((x+.5)/32-1,(y+.5)/32-1),t=fmax(0,fmin(1,(1-rad)/.2));
   assert(fabs(b[(y*64+x)*4]-.25*(1-cos(M_PI*t)))<.002);
 }
 // Recipe, image coverage and opacity multiply, without carrier resampling.
 [mask replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:half bytesPerRow:2];
 u.mean[3]=.5;auto combined=render();
 assert(combined[(32*64+2)*4]==0);
 assert(fabs(combined[(32*64+54)*4]-.5*b[(32*64+54)*4])<.002);
 [mask replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:white bytesPerRow:2];u.mean[3]=1;
 // A hard analytic ellipse is the built-in ellipse aperture.
 u.maskA[0]=0;u.maskB[0]=0;auto ellipse=render();u.maskA[0]=-1;u.aperture[1]=1;b=render();assert(ellipse==b);
 // Edge 0 is exactly hard: every pixel is wholly in or out, by its centre.
 u.aperture[1]=0;u.maskA[0]=2;u.maskA[2]=.4;u.maskA[3]=1;u.maskB[0]=0;b=render();
 for(int y=0;y<64;y++)for(int x=0;x<64;x++){
   double rad=hypot((x+.5)/32-1,(y+.5)/32-1);
   assert(b[(y*64+x)*4]==(rad>=.4 && rad<=1 ? ellipse[(32*64+32)*4] : 0));
 }

 // Exercise the engine's exact blend factors on 8-bit, 10-bit and float targets,
 // including premultiplied offscreen storage and the final gamma encode pass.
 u.aperture[1]=0;u.maskA[0]=3;u.maskA[3]=.8;u.maskB[0]=.2;u.mean[3]=.8;
 auto makePipe=[&](NSString *vertex,NSString *fragment,MTLPixelFormat format,int mode,bool offscreen){
   auto desc=[MTLRenderPipelineDescriptor new];desc.vertexFunction=[lib newFunctionWithName:vertex];desc.fragmentFunction=[lib newFunctionWithName:fragment];
   auto c=desc.colorAttachments[0];c.pixelFormat=format;auto blend=pm::internal::blendFor(mode,false,offscreen);
   c.blendingEnabled=blend.enabled;c.sourceRGBBlendFactor=(MTLBlendFactor)blend.sourceRGB;c.destinationRGBBlendFactor=(MTLBlendFactor)blend.destinationRGB;
   c.sourceAlphaBlendFactor=(MTLBlendFactor)blend.sourceAlpha;c.destinationAlphaBlendFactor=(MTLBlendFactor)blend.destinationAlpha;
   auto result=[d newRenderPipelineStateWithDescriptor:desc error:&error];assert(result);return result;
 };
 auto target=[&](MTLPixelFormat format){auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:64 height:64 mipmapped:NO];desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;auto t=[d newTextureWithDescriptor:desc];assert(t);return t;};
 auto masked=[&](MTLPixelFormat format,int mode,bool offscreen){
   auto t=target(format);auto p=makePipe(@"pvmain",@"pfmain",format,mode,offscreen);
   auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto c=pass.colorAttachments[0];
   c.texture=t;c.loadAction=MTLLoadActionClear;c.storeAction=MTLStoreActionStore;c.clearColor=MTLClearColorMake(.2,.2,.2,.25);
   auto e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:p];[e setVertexBytes:&u length:sizeof(u) atIndex:0];[e setFragmentBytes:&u length:sizeof(u) atIndex:0];[e setFragmentTexture:mask atIndex:0];[e setFragmentSamplerState:sampler atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[e endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);return t;
 };
 auto rgb=[&](id<MTLTexture> t,int x,int y){
   if(t.pixelFormat==MTLPixelFormatRGBA16Float){__fp16 pixel[4];[t getBytes:pixel bytesPerRow:8 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];return double(pixel[0]);}
   uint32_t pixel=0;[t getBytes:&pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];
   return t.pixelFormat==MTLPixelFormatBGRA8Unorm ? double(pixel&255)/255 : double(pixel&1023)/1023;
 };
 double rad=hypot(22.5/32,.5/32),alpha=.8*(.5-.5*cos(M_PI*(.8-rad)/.2));
 for(int mode=0;mode<3;mode++){
   double expected=mode==0 ? .5*alpha+.2*(1-alpha) : mode==1 ? .5*alpha+.2 : .5;
   for(auto format:{MTLPixelFormatBGRA8Unorm,MTLPixelFormatBGR10A2Unorm,MTLPixelFormatRGBA16Float}){
     auto t=masked(format,mode,false);assert(fabs(rgb(t,54,32)-expected)<.007);assert(fabs(rgb(t,0,0)-.2)<.007);
   }
   auto off=masked(MTLPixelFormatRGBA16Float,mode,true);
   assert(fabs(rgb(off,54,32)-(mode==2 ? .5*alpha : expected))<.002);
   auto linear=masked(MTLPixelFormatRGBA16Float,mode,false);
   for(auto format:{MTLPixelFormatBGRA8Unorm,MTLPixelFormatBGR10A2Unorm}){
     auto t=target(format);auto encode=makePipe(@"evmain",@"efmain",format,2,false);
     struct Encode {float gamma[4];uint32_t mode,n,pad[2];} eu={{2,2,2,1},1,0,{0,0}};
     auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto c=pass.colorAttachments[0];c.texture=t;c.loadAction=MTLLoadActionDontCare;c.storeAction=MTLStoreActionStore;
     auto e=[cb renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:encode];[e setFragmentTexture:linear atIndex:0];[e setFragmentTexture:mask atIndex:1];[e setFragmentBytes:&eu length:sizeof(eu) atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
     assert(fabs(rgb(t,54,32)-expected*expected)<.007);
   }
 }
 puts("PASS: real GPU grating frequency/orientation/phase, noise seed/grain/resize, image/procedural/analytic masks, inversion, soft and exactly hard edges, multiplicative coverage, 8/10-bit/float targets, blend modes, premultiplied offscreen storage and gamma encoding.");
}}
