#!/usr/bin/env python3
"""Actual standalone submit/wait path with Foundation and a controlled GPU stub."""
from pathlib import Path
import subprocess,tempfile,sys
if sys.platform!='darwin':
 print('SKIP: export submission fixture requires Foundation.');raise SystemExit(0)
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text();a=s.index('static uint64_t renderExportFrame() {');b=s.index('\n}\n',a)+3
body=s[a:b].replace('20*NSEC_PER_SEC','10*NSEC_PER_MSEC')
source=r'''
#import <Foundation/Foundation.h>
#include "PsychMetalRecordingClock.h"
#include <cassert>
#include <pthread.h>
static bool gpuError=false,neverFinishes=false,encodeFails=false,encodeThrows=false;
static int committed=0,watched=0,flushed=0;
enum {MTLCommandBufferStatusCompleted=4,MTLCommandBufferStatusError=5};
@protocol MTLCommandBuffer
@property(readonly) NSUInteger status;
-(void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler;
-(void)commit;
@end
@interface Buffer:NSObject<MTLCommandBuffer>
@property NSUInteger status;
@property NSMutableArray *handlers;
@end
@implementation Buffer
-(instancetype)init {if((self=[super init]))_handlers=[NSMutableArray new];return self;}
-(void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler {[_handlers addObject:[handler copy]];}
-(void)commit {committed++;self.status=gpuError?MTLCommandBufferStatusError:MTLCommandBufferStatusCompleted;
 if(!neverFinishes)for(void (^handler)(id<MTLCommandBuffer>) in _handlers)handler(self);}
@end
@interface Queue:NSObject
-(id<MTLCommandBuffer>)commandBuffer;
@end
@implementation Queue
-(id<MTLCommandBuffer>)commandBuffer{return [Buffer new];}
@end
static bool device=true,closing=false,asynchronousGpuFailure=false;
static constexpr uint64_t PM_MAX_ID=100000;
static constexpr size_t NREC=16;
struct Record {uint64_t token;int status,renderDone,gpuDone,done;double projected,presented,requestedTime,presentRequest;};
static Record rec[NREC];
static uint64_t nextToken=1;
static Queue *queue;
static id exportTexture;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pm::recording::Clock recordingClock;
static void flushTarget(){flushed++;}
static Record *recordFor(uint64_t token){return rec[token%NREC].token==token?&rec[token%NREC]:nullptr;}
static bool encodeFrame(id<MTLCommandBuffer>,id,uint64_t){if(encodeThrows)throw std::runtime_error("encoding failed");return !encodeFails;}
static void watchRender(id<MTLCommandBuffer>,uint64_t){watched++;}
[[noreturn]] static void fail(const char *s){throw std::runtime_error(s);}
''' + body + r'''
int main(){@autoreleasepool {
 queue=[Queue new];exportTexture=[NSObject new];
 bool rejected=false;try{renderExportFrame();}catch(const std::runtime_error&){rejected=true;}
 assert(rejected&&committed==0);
 recordingClock.begin(100,1.0/60);recordingClock.beginFlip(100,0);
 auto token=renderExportFrame();auto r=recordFor(token);
 assert(r&&r->renderDone&&r->gpuDone&&r->done&&r->status==2);
 assert(std::isnan(r->presented)&&std::isnan(r->projected));
 assert(committed==1&&watched==1&&flushed==1);
 recordingClock.finishFlip(100);
 for(int mode=0;mode<4;mode++) {
  asynchronousGpuFailure=false;gpuError=mode==0;neverFinishes=mode==1;encodeFails=mode==2;encodeThrows=mode==3;
  rejected=false;try{renderExportFrame();}catch(const std::runtime_error&){rejected=true;}
  assert(rejected&&asynchronousGpuFailure);
  assert(recordFor(nextToken-1)->status==3);
  const auto before=nextToken;try{renderExportFrame();}catch(const std::runtime_error&){}
  assert(nextToken==before); // failed sessions cannot keep admitting frames
 }
 recordingClock.end();
}}
'''
with tempfile.TemporaryDirectory(prefix='pm-export-render-') as temp:
 p=Path(temp)/'test.mm';p.write_text(source)
 for sanitizer in ('address,undefined','thread'):
  binary=Path(temp)/sanitizer
  subprocess.run(['clang++','-std=c++17','-fobjc-arc','-fblocks','-pthread','-iquote',str(root),'-framework','Foundation','-fsanitize='+sanitizer,str(p),'-o',str(binary)],check=True)
  subprocess.run([str(binary)],check=True)
print('PASS: actual export submission, GPU completion without presentation claims, encode/GPU failure, bounded timeout and failed-session refusal.')
