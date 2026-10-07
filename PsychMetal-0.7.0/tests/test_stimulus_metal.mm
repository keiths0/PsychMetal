// Real offscreen Metal pixel checks for the procedural shader. No window needed.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include "../PsychMetalShaders.h"
struct U {float dst[4],mean[4],wave[4],noise[4],aperture[4],viewport[4];};
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
 U u={{0,0,64,64},{.5,.5,.5,1},{.125,0,0,1},{7,1,0,0},{0,0,.35,0},{64,64,0,0}};
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
 puts("PASS: real GPU grating frequency/orientation/phase, noise seed/grain/resize, image and procedural masks.");
}}
