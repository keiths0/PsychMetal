"""Actual Mac host recovery state machine with controlled Core Audio endpoints.
Exercises ownership/session preservation and interruption behavior with the real
mixer and recorder. Does not simulate real device drivers or certify latency.
"""
from pathlib import Path
import subprocess, tempfile, sys
if sys.platform!='darwin':
    print('SKIP: Mac recovery fixture needs Foundation dispatch.');raise SystemExit(0)
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalAudioEngine.h').read_text()
a=s.index('static bool recoverMac(');b=s.index('\n}\n',a)+3
function=s[a:b]
a=s.index('static void checkRecoveryRates(');rate_check=s[a:s.index('\n}\n',a)+3]
source=r'''
#import <Foundation/Foundation.h>
#include "PsychMetalAudioHost.h"
#include <cassert>
using UInt32=unsigned;using AudioObjectID=unsigned;
const int kAudioDevicePropertyDeviceIsAlive=1;
struct Audio {
    int outputDevice=5,inputDevice=6;
    void *output=nullptr,*input=nullptr;
    pm::AudioOptions options;
    std::unique_ptr<pm::audio::Session> session;
    std::shared_ptr<std::atomic<bool>> lost=std::make_shared<std::atomic<bool>>(false);
    bool recoveryPaused=false,recoveryClosing=false;double recoveryRetry=0;
    dispatch_queue_t notices=dispatch_queue_create("notices",DISPATCH_QUEUE_SERIAL);
};
static double now=100;
static bool alive=true,canOpen=true,canStart=true;
static int starts=0,closes=0,opens=0;
static pm::AudioOptions selected;
double CACurrentMediaTime(){return now;}
int address(int value){return value;}
bool getProperty(int d,int,UInt32 &value){value=(d==9||d==10)||alive;return true;}
void closePlatform(Audio &a){++closes;a.output=a.input=nullptr;}
void openMac(Audio &a,const pm::AudioOptions &o,double rate) {
    ++opens;selected=o;
    assert(o.rate==48000&&rate==44100);
    if(!canOpen)throw std::runtime_error("device absent");
    a.outputDevice=o.device<0?9:(int)o.device;a.inputDevice=o.inputDevice<0?10:(int)o.inputDevice;
    a.output=(void*)1;a.input=(void*)2;
}
int AudioOutputUnitStart(void*){++starts;return canStart?0:-1;}
void check(int status,const char *message){if(status)throw std::runtime_error(message);}
''' +r'''
[[noreturn]] static void audioFail(const char *s){throw std::runtime_error(s);}
''' +rate_check+function+r'''
int main(){@autoreleasepool {
 checkRecoveryRates(48000,48000,true);checkRecoveryRates(48000,44100,false);
 bool rateRefused=false;try{checkRecoveryRates(48000,44100,true);}catch(...){rateRefused=true;}assert(rateRefused);
 Audio a;pm::audio::Platform platform;
 platform.playable=[&]{return !a.recoveryPaused;};
 a.session=std::make_unique<pm::audio::Session>(platform);
 a.options.device=5;a.options.inputDevice=6;a.options.input=true;
 a.session->info.rate=48000;a.session->info.inputRate=44100;
 a.session->info.channels=a.session->info.inputChannels=1;a.session->info.input=true;
 a.session->info.timed=true;a.session->allocateInput(1,.1);
 std::vector<float> pcm(100,.5f);pm::ArrayView view{};view.data=pcm.data();view.ndim=1;
 view.shape[0]=pcm.size();view.strides[0]=4;view.type=pm::ScalarType::Float32;
 auto handle=a.session->makeSound(view,0);auto old=a.session->play(handle,NAN,0,0,1,1);
 a.session->startRecording(NAN);
 const float *in[]={pcm.data()};a.session->recorder.capture(in,1,8,now,44100);
 float output[8];float *out[]={output};a.session->mixer.render(out,1,8,now,48000);
 auto *session=a.session.get();
 a.lost->store(true);alive=false;
 assert(recoverMac(a));assert(a.session.get()==session&&!a.recoveryPaused);
 assert(selected.device==-1&&selected.inputDevice==-1&&!a.session->info.timed);
 a.session->mixer.render(out,1,8,now+.001,48000);
 a.session->recorder.capture(in,1,8,now+.001,44100);
 auto recorded=a.session->recording();assert(recorded.frames==8&&!recorded.recording);
 auto events=a.session->results();bool interrupted=false;
 for(auto e:events)if(e.id==old&&e.status==pm::AudioEventStatus::Interrupted)interrupted=true;
 assert(interrupted&&a.session->status().sounds==1);
 auto fresh=a.session->play(handle,NAN,0,0,1,1);assert(fresh!=old);
 a.lost->store(true);assert(recoverMac(a)&&!a.recoveryPaused);
 assert(selected.device==-1&&selected.inputDevice==-1); // a second change on the fallback must not select the absent original

 canOpen=false;a.lost->store(true);assert(recoverMac(a)&&a.recoveryPaused);
 int attempts=opens;assert(!recoverMac(a)&&opens==attempts);
 bool refused=false;try{a.session->play(handle,NAN,0,0,1,1);}catch(...){refused=true;}assert(refused);
 canOpen=true;canStart=false;now+=1.1;recoverMac(a);assert(a.recoveryPaused);
 canStart=true;alive=true;now+=1.1;recoverMac(a);assert(!a.recoveryPaused);
 assert(selected.device==5&&selected.inputDevice==6); // explicit endpoints retained when alive
 assert(a.session.get()==session&&a.session->status().sounds==1);
 attempts=opens;a.recoveryClosing=true;a.lost->store(true);
 assert(recoverMac(a)&&opens==attempts); // final collection at Close cannot reopen units
}}
'''
with tempfile.TemporaryDirectory() as d:
    p=Path(d)/'test.mm';p.write_text(source)
    for sanitizer in ('address,undefined','thread'):
        binary=Path(d)/sanitizer
        subprocess.run(['clang++','-std=c++17','-fobjc-arc','-fblocks','-pthread','-iquote',str(root),'-fsanitize='+sanitizer,str(p),'-framework','Foundation','-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,timeout=20)
print('PASS: Mac recovery retains session/sounds/PCM, interrupts stale voices, preserves client rates, retargets missing endpoints, retries failures and retains available explicit endpoints; ASan/UBSan/TSan.')
