"""Actual recorder sound worker with generated mixer audio and stalled appends."""
from pathlib import Path
import subprocess
import sys
import tempfile
if sys.platform!='darwin':
 print('Offline recording worker fixture SKIPPED: requires Foundation.');raise SystemExit(0)
root=Path(__file__).resolve().parents[1];s=(root/'PsychMetalRecord.h').read_text()
a=s.index('static void offlineSoundMain(');worker=s[a:s.index('\nvoid pm::startMovieRecording',a)]
code=r'''
#import <Foundation/Foundation.h>
#include "PsychMetalOfflineAudio.h"
#include <atomic>
#include <thread>
#include <cassert>
#include <string>
struct PMRecorder {
 std::mutex mutex;std::condition_variable changed;std::string failure;
 std::atomic<double> firstAim{100.01},endTime{NAN},soundHorizon{100.04};
 std::atomic<bool> soundStop{false};
 double soundRate=48000;uint64_t soundWritten=0;
 std::shared_ptr<pm::audio::OfflineAudio> offlineAudio;
 std::vector<float> written;
 int delay=0;
};
static void finishRecordingInput(PMRecorder *,bool) {}
static bool appendRecordedSound(PMRecorder *r,const float *samples,size_t n,int64_t start) {
 if(r->delay) std::this_thread::sleep_for(std::chrono::milliseconds(r->delay));
 assert(start==(int64_t)r->soundWritten);
 r->written.insert(r->written.end(),samples,samples+2*n);r->soundWritten+=n;return true;
}
'''+worker+r'''
int main() { @autoreleasepool {
 for(bool preRoll:{false,true}) {
 std::vector<float> reference;
 for(double first:{100.01,100+1/59.94}) for(int delay:{0,2,30}) {
  auto r=std::make_unique<PMRecorder>();r->delay=delay;r->firstAim.store(first);
  r->offlineAudio=std::make_shared<pm::audio::OfflineAudio>(100,48000,1);
  auto sound=std::make_shared<pm::audio::Sound>();sound->channels=1;sound->frames=4;sound->samples={1,.5f,-.5f,-1};
  pm::audio::Command c;c.voice=1;c.sound=sound.get();c.when=preRoll?first-2.0/48000:first+.02;r->offlineAudio->capture(c,sound,100);
  std::thread thread([&]{@autoreleasepool{offlineSoundMain(r.get());}});
  std::this_thread::sleep_for(std::chrono::milliseconds(5));
  r->endTime.store(.1);r->soundStop.store(true);thread.join();
  assert(r->failure.empty() && r->soundWritten==4800);
  if(preRoll) assert(r->written[0]==-.5f && r->written[2]==-1);
  else assert(r->written[960*2]==1 && r->written[(960+1)*2]==.5f);
  if(reference.empty())reference=r->written;else assert(reference==r->written);
 }
 }
} }
'''
code=code.replace('#include <atomic>','#include <atomic>\n#include <condition_variable>')
with tempfile.TemporaryDirectory() as temp:
 src=Path(temp)/'worker.mm';src.write_text(code)
 for sanitizer in ('address,undefined','thread'):
  binary=Path(temp)/sanitizer.replace(',','-')
  subprocess.run(['clang++','-std=c++17','-fobjc-arc','-g','-O1','-fsanitize='+sanitizer,'-iquote',root,src,'-framework','Foundation','-o',binary],check=True)
  subprocess.run([binary],check=True,timeout=20)
print('PASS: actual offline sound worker trims pre-roll, streams/stops contiguously and preserves sample alignment under slow appends; ASan/UBSan/TSan.')
