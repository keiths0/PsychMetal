#include "PsychMetalAudioHost.h"
#include <cassert>
#include <thread>
#include <iostream>
using namespace pm::audio;
pm::ArrayView view(std::vector<float>&v,size_t n) {pm::ArrayView x;x.data=v.data();x.type=pm::ScalarType::Float32;x.ndim=1;x.shape[0]=n;x.strides[0]=4;return x;}
int main(){
 Platform platform;platform.now=[] {return 200.;};platform.warn=[](const char*,const char*){};
 Session s(platform);s.info.rate=48000;s.info.channels=1;
 auto h=s.makeStream(16,1);std::vector<float> a(32);for(int i=0;i<32;i++)a[i]=i/32.f;
 s.refill(h,view(a,8),false);auto voice=s.play(h,100,0,0,1,1);
 float data[32];float *out[]={data};s.mixer.render(out,1,5,100,48000);
 for(int i=0;i<5;i++)assert(data[i]==a[i]);
 auto status=s.streamStatus(h);assert(status.queued==3&&status.free==13);
 auto bad=a;bad[8]=NAN;bool rejected=false;try{s.refill(h,view(bad,9),false);}catch(...){rejected=true;}
 assert(rejected&&s.streamStatus(h).written==8);
 s.refill(h,view(a,9),true);s.mixer.render(out,1,20,100+5./48000,48000);
 for(int i=0;i<3;i++)assert(data[i]==a[5+i]);for(int i=0;i<9;i++)assert(data[3+i]==a[i]);
 for(int i=12;i<20;i++)assert(data[i]==0);
 status=s.streamStatus(h);assert(status.consumed==17&&status.underflowFrames==0&&status.sealed);
 auto timing=s.timing(voice);assert(timing.finished&&std::abs(timing.end-(100+17./48000))<1e-9);
 rejected=false;try{s.play(h,NAN,0,0,1,1);}catch(...){rejected=true;}assert(rejected);
 // Running dry inserts silence and the sample clock continues. A later refill
 // remains playable, with the missing sample interval explicitly counted.
 h=s.makeStream(16,1);s.refill(h,view(a,4),false);voice=s.play(h,100+25./48000,0,0,1,1);
 s.mixer.render(out,1,8,100+25./48000,48000);assert(s.streamStatus(h).underflowFrames==4);
 s.refill(h,view(a,2),true);s.mixer.render(out,1,8,100+33./48000,48000);
 assert(data[0]==a[0]&&data[1]==a[1]);assert(s.timing(voice).finished);
 // One host producer and the actual callback mixer concurrently wrap the ring.
 Session c(platform);c.info.rate=48000;c.info.channels=1;h=c.makeStream(128,1);
 std::vector<float> block(8,.25f);c.refill(h,view(block,8),false);c.play(h,300,0,0,1,1);
 std::atomic<bool> done{false};
 std::thread consumer([&]{float b[16];float *p[]={b};double time=300;
  while(!done.load()){c.mixer.render(p,1,16,time,48000);time+=16./48000;std::this_thread::yield();}
 });
 for(int i=0;i<2000;i++){while(c.streamStatus(h).free<8)std::this_thread::yield();c.refill(h,view(block,8),false);}
 c.refill(h,view(block,0),true);
 while(c.streamStatus(h).queued)std::this_thread::yield();done=true;consumer.join();
 assert(c.streamStatus(h).written==16008&&c.streamStatus(h).consumed==16008);
 std::cout<<"PASS: streamed PCM wraparound, atomic refusal, EOS, underflow and concurrent host/callback refill.\n";
}
