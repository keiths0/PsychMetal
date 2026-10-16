#!/usr/bin/env python3
"""Native Stop/producer EOF order under A/V interleaving backpressure.
Foundation stubs model either input waiting for the other input's EOF. No codec claims.
"""
from pathlib import Path
import subprocess,tempfile,sys
if sys.platform!='darwin':
 print('SKIP: interleaving fixture requires Foundation.');raise SystemExit(0)
root=Path(__file__).resolve().parents[1];s=(root/'PsychMetalRecord.h').read_text()
def function(signature):
 a=s.index(signature);return s[a:s.index('\n}\n',a)+3]
ready=function('static bool recordingInputReady(').replace('std::chrono::seconds(10)','std::chrono::milliseconds(200)')
helpers='\n'.join(function(sig) for sig in ('static void finishRecordingInput(', 'static void closeRecordingAdmission(', 'static void releaseRecordingFrame('))
worker=function('static void offlineSoundMain(')
configure=function('static void configureRecordingInput(')
assert 'configureRecordingInput(r->input);' in s and 'configureRecordingInput(r->soundInput);' in s
source=r'''
#import <Foundation/Foundation.h>
#include "PsychMetalRecordingClock.h"
#include "PsychMetalOfflineAudio.h"
#include <cassert>
#include <condition_variable>
#include <thread>
#include <unistd.h>
constexpr int AVAssetWriterStatusWriting=1;
@interface AVAssetWriterInput:NSObject
@property BOOL finished;
@property BOOL expectsMediaDataInRealTime;
@property BOOL coupled;
@property double audioThrough;
@property double videoAt;
@property BOOL raises;
@property BOOL waits;
@property AVAssetWriterInput *other;
@property(readonly) BOOL readyForMoreMediaData;
@property NSUInteger finishes;
@property NSUInteger finishDelay;
-(void)markAsFinished;
@end
@implementation AVAssetWriterInput
-(BOOL)readyForMoreMediaData {return (!self.coupled || self.expectsMediaDataInRealTime || self.audioThrough>=self.videoAt+.25) && (!self.waits || self.other.finished);}
-(void)markAsFinished {
 if(self.raises) @throw [NSException exceptionWithName:@"test" reason:@"EOF refused" userInfo:nil];
 if(self.finishDelay)std::this_thread::sleep_for(std::chrono::milliseconds(self.finishDelay));
 assert(!self.finished);self.finished=YES;self.finishes++;
}
@end
@interface Writer:NSObject
@property int status;
@end
@implementation Writer
@end
struct PMRecorder {
 Writer *writer=[Writer new];AVAssetWriterInput *input=[AVAssetWriterInput new],*soundInput=[AVAssetWriterInput new];
 std::mutex mutex;std::condition_variable changed;std::string failure;
 bool accepting=true,virtualClock=true;int pending=1;
 pm::recording::Span virtualSpan;
 std::atomic<bool> videoFinished{false},soundFinished{false},soundStop{false};
 std::atomic<double> firstAim{100.01},endTime{NAN},soundHorizon{100.02};
 double period=.01,soundRate=48000;uint64_t soundWritten=0;
 std::shared_ptr<pm::audio::OfflineAudio> offlineAudio;
 std::vector<float> samples;
 PMRecorder(){writer.status=AVAssetWriterStatusWriting;input.other=soundInput;soundInput.other=input;}
 ~PMRecorder(){input.other=nil;soundInput.other=nil;}
};
''' +ready+helpers+configure+r'''
static bool appendRecordedSound(PMRecorder *r,const float *samples,size_t n,int64_t start) {
 if(!recordingInputReady(r,r->soundInput))return false;
 assert(start==(int64_t)r->soundWritten);
 r->samples.insert(r->samples.end(),samples,samples+n*2);r->soundWritten+=n;return true;
}
''' +worker+r'''
int main(){@autoreleasepool {
 // Controlled mid-stream interleaving: audio can advance only to admitted
 // video, while an offline writer asks video to wait for a quarter-second of
 // audio lead. This models the dependency, not Apple's codec implementation.
 {PMRecorder r;r.input.coupled=YES;r.input.videoAt=1;r.input.audioThrough=1;
  assert(!recordingInputReady(&r,r.input)); // negative control: old mode stalls
  assert(r.failure.find("video")!=std::string::npos);
 }
 {PMRecorder r;configureRecordingInput(r.input);configureRecordingInput(r.soundInput);
  assert(r.input.expectsMediaDataInRealTime&&r.soundInput.expectsMediaDataInRealTime);
  r.input.coupled=YES;
  for(int frame=0;frame<360;frame++) {
   r.input.videoAt=frame/120.;r.input.audioThrough=r.input.videoAt;
   assert(recordingInputReady(&r,r.input));
  }
  assert(r.failure.empty());
 }

 for(bool videoWaits:{true,false})for(int delayedVideo:{0,10,40}) {
  auto r=std::make_unique<PMRecorder>();
  r->input.waits=videoWaits;r->soundInput.waits=!videoWaits;r->input.finishDelay=10;
  r->virtualSpan.note(100.01,r->period);r->virtualSpan.note(100.02,r->period);
  r->offlineAudio=std::make_shared<pm::audio::OfflineAudio>(100,48000,1);
  auto hit=std::make_shared<pm::audio::Sound>();hit->channels=1;hit->frames=4;hit->samples={1,.5f,-.5f,-1};
  pm::audio::Command c;c.voice=1;c.sound=hit.get();c.when=100.03;r->offlineAudio->capture(c,hit,100);
  std::thread sound([&]{@autoreleasepool{offlineSoundMain(r.get());}});
  closeRecordingAdmission(r.get(),100.04); // signals exact audio tail BEFORE draining video
  assert(r->soundStop.load()&&std::abs(r->endTime.load()-.03)<1e-8);
  std::thread video([&]{@autoreleasepool{
   std::this_thread::sleep_for(std::chrono::milliseconds(delayedVideo));
   assert(recordingInputReady(r.get(),r->input));releaseRecordingFrame(r.get());
  }});
  {
   std::unique_lock<std::mutex> lock(r->mutex);
   assert(r->changed.wait_for(lock,std::chrono::seconds(2),[&]{return r->pending==0;}));
  }
  video.join();sound.join();
  assert(r->failure.empty()&&r->input.finished&&r->soundInput.finished);
  assert(r->soundWritten==1440&&r->samples[960*2]==1&&r->samples[962*2]==-.5f);
  finishRecordingInput(r.get(),false);finishRecordingInput(r.get(),true);
  assert(r->input.finishes==1&&r->soundInput.finishes==1);
 }
 {PMRecorder r;r.input.raises=YES;finishRecordingInput(&r,false);assert(r.failure.find("EOF refused")!=std::string::npos);}
 {PMRecorder r;r.failure="original failure";finishRecordingInput(&r,true);assert(!r.soundInput.finished&&r.failure=="original failure");}
 {PMRecorder r;r.pending=0;closeRecordingAdmission(&r,100.01);assert(r.input.finished&&r.endTime.load()==0);}
}}
'''
with tempfile.TemporaryDirectory(prefix='pm-interleave-') as temp:
 path=Path(temp)/'test.mm';path.write_text(source)
 for sanitizer in ('address,undefined','thread'):
  binary=Path(temp)/sanitizer
  subprocess.run(['clang++','-std=c++17','-pthread','-fobjc-arc','-fblocks','-iquote',str(root),'-fsanitize='+sanitizer,str(path),'-framework','Foundation','-o',str(binary)],check=True)
  subprocess.run([str(binary)],check=True,timeout=15)
print('PASS: push-source mode avoids modeled mid-stream interleaving deadlock; actual Stop/EOF workers release both directions of interleaving stalls, preserve exact PCM/tail timing, deliver EOF once, and retain errors; ASan/UBSan/TSan.')
