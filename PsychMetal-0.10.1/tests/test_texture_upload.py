"""Exercise actual private/shared upload dispatch with a controlled Metal backend.
Tests region/pitch preservation and bounded GPU failure handling; no real GPU claim.
"""
from pathlib import Path
import subprocess,tempfile,sys
if sys.platform!='darwin':
    print('SKIP: texture upload fixture needs Foundation/Metal declarations.');raise SystemExit(0)
root=Path(__file__).resolve().parents[1];s=(root/'PsychMetalEngine.mm').read_text()
a=s.index('static void writeTexture(');helper=s[a:s.index('\nstatic void uploadTexture(',a)]
helper=helper.replace('20*NSEC_PER_SEC','5*NSEC_PER_MSEC')
source=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <memory>
#include <vector>
#include <stdexcept>
#include <cassert>
#include <cstring>
static bool failGPU=false,stallGPU=false;
static unsigned pixelBytes(MTLPixelFormat f){return f==MTLPixelFormatR32Float?4:1;}
@interface Texture:NSObject
@property MTLPixelFormat pixelFormat;
@property NSUInteger width,height;
@property BOOL privateStorage;
@property NSMutableData *data;
-(void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l withBytes:(const void*)b bytesPerRow:(NSUInteger)p;
@end
@implementation Texture
-(void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)l withBytes:(const void*)b bytesPerRow:(NSUInteger)p {
 assert(!self.privateStorage);unsigned n=pixelBytes(self.pixelFormat);
 for(unsigned y=0;y<r.size.height;y++)memcpy((char*)self.data.mutableBytes+((y+r.origin.y)*self.width+r.origin.x)*n,(const char*)b+y*p,r.size.width*n);
}
@end
@interface Blit:NSObject
-(void)copyFromTexture:(Texture*)source sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)size toTexture:(Texture*)dest destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)d;
-(void)endEncoding;
@end
@implementation Blit
-(void)copyFromTexture:(Texture*)source sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)size toTexture:(Texture*)dest destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)d {
 assert(!source.privateStorage&&dest.privateStorage);unsigned n=pixelBytes(dest.pixelFormat);
 for(unsigned y=0;y<size.height;y++)memcpy((char*)dest.data.mutableBytes+((y+d.y)*dest.width+d.x)*n,(const char*)source.data.bytes+((y+o.y)*source.width+o.x)*n,size.width*n);
}
-(void)endEncoding {}
@end
@interface Command:NSObject
@property NSMutableArray *handlers;
@property MTLCommandBufferStatus status;
-(Blit*)blitCommandEncoder;
-(void)addCompletedHandler:(void(^)(id<MTLCommandBuffer>))handler;
-(void)commit;
@end
@implementation Command
-(instancetype)init{if((self=[super init]))self.handlers=[NSMutableArray new];return self;}
-(Blit*)blitCommandEncoder{return [Blit new];}
-(void)addCompletedHandler:(void(^)(id<MTLCommandBuffer>))handler{[self.handlers addObject:[handler copy]];}
-(void)commit{self.status=failGPU?MTLCommandBufferStatusError:MTLCommandBufferStatusCompleted;
 if(!stallGPU)for(void(^h)(id<MTLCommandBuffer>) in self.handlers)h((id<MTLCommandBuffer>)self);}
@end
@interface Device:NSObject
-(id)newTextureWithDescriptor:(MTLTextureDescriptor*)d;
@end
@implementation Device
-(id)newTextureWithDescriptor:(MTLTextureDescriptor*)d{Texture*t=[Texture new];t.width=d.width;t.height=d.height;t.pixelFormat=d.pixelFormat;t.privateStorage=d.storageMode==MTLStorageModePrivate;t.data=[NSMutableData dataWithLength:d.width*d.height*pixelBytes(d.pixelFormat)];return t;}
@end
@interface Queue:NSObject
-(Command*)commandBuffer;
@end
@implementation Queue
-(Command*)commandBuffer{return [Command new];}
@end
struct Resource{Texture*texture;bool gpuOnly;};using PMTextureRef=std::shared_ptr<Resource>;
static Device *device=[Device new];static Queue *queue=[Queue new];
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;static bool asynchronousGpuFailure=false;
[[noreturn]]static void fail(const char*s){throw std::runtime_error(s);}
''' +helper+r'''
int main(){@autoreleasepool {
 for(bool privateStorage:{false,true})for(auto format:{MTLPixelFormatR8Unorm,MTLPixelFormatR32Float}) {
  auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:5 height:4 mipmapped:NO];
  d.storageMode=privateStorage?MTLStorageModePrivate:MTLStorageModeShared;
  auto r=std::make_shared<Resource>();r->texture=[device newTextureWithDescriptor:d];r->gpuOnly=privateStorage;
  unsigned n=pixelBytes(format);std::vector<unsigned char> data(2*4*n,17);
  writeTexture(r,data.data(),3,2,4*n,1,1);
  const unsigned char *out=(const unsigned char*)r->texture.data.bytes;
  for(unsigned y=0;y<4;y++)for(unsigned x=0;x<5;x++)for(unsigned c=0;c<n;c++)
   assert(out[(y*5+x)*n+c]==(x>=1&&x<4&&y>=1&&y<3?17:0));
 }
 auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO];d.storageMode=MTLStorageModePrivate;
 auto r=std::make_shared<Resource>();r->texture=[device newTextureWithDescriptor:d];r->gpuOnly=true;
 unsigned char value=3;
 for(bool stall:{false,true}) {
  stallGPU=stall;failGPU=!stall;asynchronousGpuFailure=false;bool failed=false;
  try{writeTexture(r,&value,1,1,1);}catch(const std::exception&){failed=true;}
  assert(failed&&asynchronousGpuFailure);assert(pthread_mutex_trylock(&lock)==0);pthread_mutex_unlock(&lock);
 }
}}
'''
with tempfile.TemporaryDirectory() as d:
    p=Path(d)/'test.mm';p.write_text(source)
    for sanitizer in ('address,undefined','thread'):
        binary=Path(d)/sanitizer
        subprocess.run(['clang++','-std=c++17','-fobjc-arc','-fblocks','-pthread','-fsanitize='+sanitizer,str(p),'-framework','Foundation','-framework','Metal','-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,timeout=20)
print('PASS: private uploads use staged blits, shared uploads stay direct, partial regions preserve pitch/borders/float bytes, and GPU errors/timeouts invalidate safely; ASan/UBSan/TSan.')
