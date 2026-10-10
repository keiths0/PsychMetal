"""Exercise the actual draw-pass ownership code with a CPU command-buffer double."""
from pathlib import Path
import subprocess, sys, tempfile
if sys.platform != 'darwin':
    print('Resource lifetime check requires Foundation: SKIPPED.'); sys.exit(0)
root = Path(__file__).resolve().parents[1]
engine = (root/'PsychMetalEngine.mm').read_text()
start = engine.index('    size_t textureCount=0;')
end = engine.index('    NSUInteger written = 0;', start)
source = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <memory>
#include <vector>
#include <cassert>
#include <stdexcept>
@interface FakeCommand : NSObject
@property NSMutableArray *handlers;
-(void)addCompletedHandler:(MTLCommandBufferHandler)handler;
-(void)finish;
@end
@implementation FakeCommand
-(instancetype)init { if((self=[super init])) self.handlers=[NSMutableArray new]; return self; }
-(void)addCompletedHandler:(MTLCommandBufferHandler)handler { [self.handlers addObject:[handler copy]]; }
-(void)finish { for(MTLCommandBufferHandler h in self.handlers) h((id<MTLCommandBuffer>)self); [self.handlers removeAllObjects]; }
@end
@interface FakeBuffer : NSObject
-(void *)contents;
@end
@implementation FakeBuffer
-(void *)contents { static char memory[256]; return memory; }
@end
using PMTextureRef=std::shared_ptr<int>;
struct PMDrawItem { int type; }; struct PMShape { float x; };
enum { PM_ITEM_SHAPE=0, PM_ITEM_TEXTURE=1, PM_ITEM_STIMULUS=2, PM_SHAPE_RING=3 };
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond=PTHREAD_COND_INITIALIZER;
static bool shapeBufferBusy[PM_SHAPE_RING]={};
static int shapeBufferIndex=0;
static uint64_t sessionEpoch=1;
static id<MTLBuffer> shapeBuffers[PM_SHAPE_RING];
static int waitRelative(double) { throw std::runtime_error("Unexpected busy slot"); }
static void fail(const char *message) { throw std::runtime_error(message); }
using PMShaderRef=PMTextureRef;
static bool prepare(FakeCommand *command, const PMDrawItem *items, PMTextureRef *refs, NSUInteger n, PMTextureRef *coverageRefs=nullptr) {
    PMTextureRef empty[3];PMShaderRef shaderRefs[3];if(!coverageRefs)coverageRefs=empty;
    id<MTLCommandBuffer> cb=(id<MTLCommandBuffer>)command;
''' + engine[start:end] + r'''
    return base!=nullptr;
}
int main() { @autoreleasepool {
 for(int i=0;i<PM_SHAPE_RING;i++) shapeBuffers[i]=(id<MTLBuffer>)[FakeBuffer new];
 PMDrawItem stimulus[]={ {PM_ITEM_STIMULUS} }, texture[]={ {PM_ITEM_TEXTURE} }, shape[]={ {PM_ITEM_SHAPE} };
 PMTextureRef none[1];
 FakeCommand *c=[FakeCommand new];
 assert(!prepare(c,stimulus,none,1)); assert(c.handlers.count==0); assert(shapeBufferIndex==0);
 PMTextureRef refs[]={std::make_shared<int>(42)}; std::weak_ptr<int> weak=refs[0];
 assert(!prepare(c,texture,refs,1)); refs[0].reset(); assert(!weak.expired());
 assert(c.handlers.count==1); assert(shapeBufferIndex==0); [c finish]; assert(weak.expired());
 PMTextureRef source[]={std::make_shared<int>(5)}, mask[]={std::make_shared<int>(6)};
 std::weak_ptr<int> sw=source[0],mw=mask[0];
 assert(!prepare(c,texture,source,1,mask));source[0].reset();mask[0].reset();
 assert(!sw.expired() && !mw.expired());[c finish];assert(sw.expired() && mw.expired());
 assert(prepare(c,shape,none,1)); assert(shapeBufferIndex==1); assert(shapeBufferBusy[0]);
 assert(c.handlers.count==1); [c finish]; assert(!shapeBufferBusy[0]);
 PMDrawItem mixed[]={ {PM_ITEM_SHAPE},{PM_ITEM_TEXTURE},{PM_ITEM_STIMULUS} };
 PMTextureRef mixedRefs[]={nullptr,std::make_shared<int>(3),nullptr}; weak=mixedRefs[1];
 assert(prepare(c,mixed,mixedRefs,3)); mixedRefs[1].reset(); assert(!weak.expired());
 assert(c.handlers.count==2); assert(shapeBufferBusy[1]); [c finish];
 assert(weak.expired()); assert(!shapeBufferBusy[1]);
 assert(prepare(c,shape,none,1)); assert(shapeBufferBusy[2]);
 ++sessionEpoch; [c finish]; assert(shapeBufferBusy[2]); // stale completion cannot free a new session's slot
} }
'''
with tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp); (p/'test.mm').write_text(source)
    subprocess.run(['clang++','-std=c++17','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-framework','Foundation','-framework','Metal','-framework','QuartzCore',str(p/'test.mm'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
print('PASS: actual draw-pass setup skips unused resources, retains textures until completion, and protects shape slots across session epochs.')
