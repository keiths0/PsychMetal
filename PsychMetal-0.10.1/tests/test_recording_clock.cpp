#include "PsychMetalRecordingClock.h"
#include "PsychMetalOfflineAudio.h"
#include <cassert>
#include <cmath>
#include <thread>
using pm::recording::Clock;
int main() {
 assert(pm::recording::endingTick(100.1,100,0,1.0/60)==6);
 assert(pm::recording::endingTick(100.1001,100,0,1.0/60)==7);
 assert(pm::recording::endingTick(100.1,100,9,1.0/60)==10);
 assert(pm::recording::endingTick(NAN,100,9,1.0/60)==10);
 for(double period:{1.0/60,1001.0/60000,1.0/120}) {
  pm::recording::Span span;assert(span.end(100,period)==0);
  span.note(100,period);span.note(100+period,period);span.note(100+4*period,period);
  assert(span.last==4 && span.end(100+4*period,period)==5);
  assert(span.end(100+8*period,period)==8);
 }
 Clock clock;clock.begin(100,1.0/60);
 assert(clock.beginFlip(100,0)==0);assert(clock.now(105)==100);
 assert(clock.finishFlip(105)==100);assert(clock.now(105.1)>100.099);
 clock.beginFlip(105.1,0);double second=clock.now(200);clock.finishFlip(200);
 assert(std::abs(second-100.1)<1e-8); // encoder time vanished, caller's 0.1 s remained
 const double physical=clock.beginFlip(200,101);
 assert(std::abs(physical-200.9)<1e-8);
 assert(clock.finishFlip(220)==101);
 assert(std::abs(clock.deadline(102,220)-221)<1e-8);
 clock.end();assert(clock.now(220)==220);
 // Standalone export ignores CPU work, nests playback scopes, and advances waits without sleeping.
 Clock standalone;standalone.begin(100,1.0/60);assert(standalone.beginSequence(100));
 standalone.beginFlip(200,0);standalone.finishFlip(300);assert(standalone.now(400)==100);
 assert(standalone.beginSequence(400));standalone.endSequence(500);assert(standalone.now(600)==100);
 assert(standalone.advanceWait(100.5,700)==100.5);standalone.beginFlip(800,0);
 assert(standalone.finishFlip(900)==100.5);standalone.end();
 // Frame tokens are bounded, exact, and cannot escape their recording session.
 Clock tokens;tokens.begin(100,1.0/60);tokens.beginQueue(100,101);tokens.rememberQueued(1);tokens.finishFlip(100);
 assert(tokens.queuedTime(1)==101 && std::isnan(tokens.queuedTime(2)));
 tokens.beginQueue(100,102);tokens.rememberQueued(16385);tokens.finishFlip(100);
 assert(std::isnan(tokens.queuedTime(1)) && tokens.queuedTime(16385)==102);
 tokens.end();assert(std::isnan(tokens.queuedTime(16385)));
 tokens.begin(110,1.0/60);assert(std::isnan(tokens.queuedTime(16385)));tokens.end();
 // A fixed amount of caller work gives identical stimuli despite encoder delays.
 for(double delay:{0.001,0.1,2.0}) {
  Clock c;c.begin(10,1.0/60);double real=10;
  for(int i=0;i<120;i++) {
   c.beginFlip(real,0);real+=delay;double t=c.finishFlip(real);
   assert(std::abs(t-(10+i/60.0))<1e-7);real+=.001;
  }
 }
 // Queue targets stay ordered physically even when export delays exceed a refresh.
 for(double delay:{.001,.2,3.0}) {
  Clock c;c.begin(100,1.0/60);double real=100,previous=0;
  for(int i=0;i<120;i++) {
   const double target=101+i/60.0;
   const double physical=c.beginQueue(real,target);
   assert(physical>previous);assert(std::abs(physical-target)<1e-8);previous=physical;
   real+=delay;assert(std::abs(c.finishFlip(real)-target)<1e-8);
  }
  bool rejected=false;try{c.beginQueue(real,101);}catch(const std::runtime_error &){rejected=true;}
  assert(rejected);assert(std::isfinite(c.now(real)));
 }
 // Native playback excludes arbitrarily slow decode/sample work between Flips.
 for(double delay:{.001,.2,3.0}) {
  Clock c;c.begin(100,1/59.94);double wall=100;
  assert(c.beginSequence(wall));
  const double start=c.align(100+3/59.94);
  wall+=delay;c.beginFlip(wall,start);wall+=delay;c.finishFlip(wall);
  for(int i=1;i<60;i++) {
   wall+=delay;c.beginFlip(wall,0);wall+=delay;
   assert(std::abs(c.finishFlip(wall)-(start+i/59.94))<1e-8);
  }
  const double ended=c.now(wall);c.endSequence(wall);
  assert(std::abs(c.now(wall+.1)-ended-.1)<1e-8);
 }
 // Scope cleanup works after errors; caller time resumes even with no frames.
 static double wall=100;
 auto wallNow=+[](){return wall;};
 Clock scoped;scoped.begin(wall,1.0/60);
 try {pm::recording::Sequence seq(scoped,wallNow);wall=150;throw 1;} catch(int) {}
 assert(std::abs(scoped.now(150.1)-100.1)<1e-8);
 auto sound=std::make_shared<pm::audio::Sound>();sound->channels=1;sound->frames=4;sound->samples={1,.5f,-.5f,-1};
 auto render=[&](bool split) {
  auto audio=std::make_unique<pm::audio::OfflineAudio>(100,48000,2);
  pm::audio::Command cmd;cmd.kind=pm::audio::Command::Play;cmd.voice=1;cmd.sound=sound.get();cmd.when=100.01;
  audio->capture(cmd,sound,100);
  std::vector<float> samples;
  auto sink=[&](double,const float *p,uint32_t n){samples.insert(samples.end(),p,p+2*n);};
  if(split) for(int i=1;i<=12;i++)audio->renderUntil(100+i*.001,sink);
  else audio->renderUntil(100.012,sink);
  assert(samples.size()==576*2);
  for(int i=0;i<480;i++)assert(samples[2*i]==0);
  for(int i=0;i<4;i++)assert(samples[2*(480+i)]==sound->samples[i]&&samples[2*(480+i)+1]==sound->samples[i]);
  return samples;
 };
 assert(render(false)==render(true));
 // Frame-keyed commands may be inserted before later, unrendered requests.
 auto keyed=std::make_unique<pm::audio::OfflineAudio>(0,48000,1);
 pm::audio::Command later;later.kind=pm::audio::Command::Stop;later.voice=17;later.when=.06;
 keyed->capture(later,{},.05);
 pm::audio::Command hit;hit.voice=17;hit.sound=sound.get();hit.when=.02;
 keyed->capture(hit,sound,.05,true);
 std::vector<float> keyedSamples;
 keyed->renderUntil(.1,[&](double,const float*p,uint32_t n){keyedSamples.insert(keyedSamples.end(),p,p+2*n);});
 assert(!keyed->failed());
 for(int i=0;i<4800;i++)assert(keyedSamples[2*i]==(i>=960&&i<964?sound->samples[i-960]:0));
 // PCM claimed by an in-flight sink cannot be retroactively rewritten.
 auto racing=std::make_unique<pm::audio::OfflineAudio>(0,48000,1);
 std::atomic<bool> entered{false},release{false},refused{false};
 std::thread worker([&]{try{racing->renderUntil(.1,[&](double,const float*,uint32_t){entered.store(true);while(!release.load())std::this_thread::yield();});}catch(const std::runtime_error&){refused.store(true);}});
 while(!entered.load())std::this_thread::yield();
 hit.when=.001;racing->capture(hit,sound,.05,true);assert(racing->failed());
 release.store(true);worker.join();assert(refused.load());
 // Closed sound handles cannot invalidate the samples retained for export.
 auto audio=std::make_unique<pm::audio::OfflineAudio>(0,48000,1);
 pm::audio::Command c;c.voice=2;c.sound=sound.get();audio->capture(c,sound,0);
 sound.reset();std::vector<float> samples;
 audio->renderUntil(.001,[&](double,const float *p,uint32_t n){samples.insert(samples.end(),p,p+2*n);});
 assert(samples[0]==1&&samples[1]==1);
 // Timed stop and modulation remain on their exact samples across render batches.
 auto tone=std::make_shared<pm::audio::Sound>();tone->channels=1;tone->frames=1;tone->samples={.25f};
 auto scheduled=std::make_unique<pm::audio::OfflineAudio>(0,48000,1);
 pm::audio::Command play;play.voice=9;play.sound=tone.get();play.repeats=0;play.when=.01;
 scheduled->capture(play,tone,0);
 pm::audio::Command modulation;modulation.kind=pm::audio::Command::Modulate;modulation.voice=9;
 modulation.when=.02;modulation.modulation.phase=3.141592653589793;modulation.modulation.depth=.5f;
 scheduled->capture(modulation,{},.015);
 pm::audio::Command stop;stop.kind=pm::audio::Command::Stop;stop.voice=9;stop.when=.03;
 scheduled->capture(stop,{},.025);
 std::vector<float> result;
 scheduled->renderUntil(.04,[&](double,const float *p,uint32_t n){result.insert(result.end(),p,p+2*n);});
 for(int i=0;i<1920;i++) {
  const float expected=i<480||i>=1440?0:i<960?.25f:.125f;
  assert(std::abs(result[2*i]-expected)<1e-6);
 }
 // A command issued after its interval was written must fail, never silently rewrite PCM.
 scheduled->capture(stop,{},.01);assert(scheduled->failed());

 Clock concurrent;concurrent.begin(10,1.0/60);std::atomic<bool> done{false};
 std::thread reader([&]{while(!done.load()){double t=concurrent.now(10);assert(std::isfinite(t)&&t>=10);}});
 for(int i=0;i<100;i++){concurrent.beginFlip(10+i,10+i/60.0);concurrent.finishFlip(11+i);}
 done.store(true);reader.join();concurrent.end();

}
