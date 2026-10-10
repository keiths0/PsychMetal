#!/usr/bin/env python3
"""Exercise the actual native playback loop with CPU-only presentation stubs.
No GPU timing/pixel claims. Sanitizers check snapshots and cleanup paths.
"""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text()
def function(signature):
 a=s.index(signature);return s[a:s.index('\n}',a)+2]
code=r''' 
#include "PsychMetalEngine.h"
#include "PsychMetalTimeline.h"
#include "PsychMetalLiveTimeline.h"
#include "PsychMetalKeyframes.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <cassert>
#include <cmath>
#include <pthread.h>
#include <iostream>
#include <map>
[[noreturn]] void fail(const char*s){throw pm::Error(pm::kErrGeneral,s);}
constexpr int PM_MAX_SHAPES=4,PM_ITEM_STIMULUS=2;
int device=1;bool closing=false,haveLastShape=false;
size_t drawCount=0,targetHandle=0,preparedToken=0,targetBase=0;
std::atomic<bool> timelineCancellation{false};
struct Uniform {float dst[4],wave[4],maskA[4],maskB[4];};
struct PMDrawItem {int type;Uniform stimulus;};
using PMTextureRef=std::shared_ptr<int>;
using PMShaderRef=PMTextureRef;PMShaderRef drawShaderRefs[4];
pm::timeline::LiveState liveTimeline;
PMDrawItem drawList[4];PMTextureRef drawTextureRefs[4],drawCoverageRefs[4];
pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
double gridPeriod(){return 1/119.98;}
double CACurrentMediaTime(){return 0;}
bool waitQueueIdleLocked(){return true;}
// When the display showed each frame: one refresh apart, except that the frame
// at lateAt is a refresh late (and so are those after it), and the one at
// missingAt is never shown. reportsLag frames are still unreported at the end.
int lateAt=-1,missingAt=-1;std::map<uint64_t,double> presentedAt;
static bool reportedPresentation(uint64_t token,double &presented){
 auto it=presentedAt.find(token);if(it==presentedAt.end())return false;presented=it->second;return true;
}
static void awaitPresentation(uint64_t,double){}
int escapeAt=-1,cancelAt=-1,failAt=-1;
bool injectLive=false;
std::vector<PMDrawItem> seen;
std::weak_ptr<int> retained,retainedMask;
static void readKeyboardState(bool *keys,const bool*){keys[40]=int(seen.size())==escapeAt;}
pm::FlipResult pm::flip(double){
 assert(!retained.expired() && !retainedMask.expired());
 assert(drawCount==2 && drawList[1].type==0); // static scene item is replayed too
 if(int(seen.size())==failAt) fail("injected presentation failure");
 seen.push_back(drawList[0]);
 {int i=int(seen.size())-1;presentedAt[100+seen.size()]=i==missingAt ? 0 : 10+(i+(lateAt>=0&&i>=lateAt))*gridPeriod();}
 if(injectLive && seen.size()==2) {
  double data[]={0,0,.25,0,2,17};pm::ArrayView v;v.data=data;v.type=pm::ScalarType::Float64;v.ndim=2;v.shape={2,3,0};v.strides={24,8,0};liveTimeline.update(v);
 }
 for(auto &ref:drawTextureRefs) ref.reset();for(auto &ref:drawCoverageRefs)ref.reset();for(auto &ref:drawShaderRefs)ref.reset();drawCount=0;
 if(int(seen.size())==cancelAt) pm::cancelTimeline();
 pm::FlipResult f{};f.token=100+seen.size();f.confirmed=true;
 f.slipRefreshes=seen.size()==3 ? 1 : 0;return f;
}
'''+function('static inline double viewAt(')+'\n'+s[s.index('void pm::cancelTimeline(bool'):s.index('\n',s.index('void pm::cancelTimeline(bool'))]+'\n'+function('pm::TimelineResult pm::playTimeline(')+r'''
pm::ArrayView view(double*p,size_t n,bool column=false){pm::ArrayView v;v.data=p;v.type=pm::ScalarType::Float64;v.ndim=2;v.shape={n,6,0};v.strides=column ? std::array<ptrdiff_t,3>{8,ptrdiff_t(n*8),0} : std::array<ptrdiff_t,3>{48,8,0};return v;}
void reset(){
 seen.clear();escapeAt=cancelAt=failAt=lateAt=missingAt=-1;presentedAt.clear();drawCount=2;
 drawList[0]={PM_ITEM_STIMULUS,{{10,20,110,120},{0,0,0,1}}};drawList[1]={};drawList[0].stimulus.maskA[0]=2;drawList[0].stimulus.maskB[0]=.1;
 drawTextureRefs[0]=std::make_shared<int>(1);retained=drawTextureRefs[0];
 drawCoverageRefs[1]=std::make_shared<int>(2);retainedMask=drawCoverageRefs[1];
}
int main(){
 double t[]={0,1,1,4,360,0, 0,0,0,4,.5,.5, 0,2,0,4,5,0};
 reset();auto result=pm::playTimeline(8,view(t,3));
 assert(result.submitted==8 && !result.cancelled && result.firstToken==101 && result.lastToken==108);
 assert(fabs(result.expectedRefreshHz-119.98)<1e-9);
 assert(result.shown==8 && result.late==0 && result.lateRefreshes==0 && std::isnan(result.firstLateSample));
 assert(fabs(result.meanSampleMs-1000/119.98)<1e-6 && fabs(result.longestIntervalMs-1000/119.98)<1e-6);
 for(size_t i=0;i<8;i++){
   assert(seen[i].stimulus.maskA[0]==2 && fabs(seen[i].stimulus.maskB[0]-.1)<1e-6);
   assert(fabs(seen[i].stimulus.wave[2]-double(i%4)*M_PI/2)<1e-6);
   assert(fabs(seen[i].stimulus.wave[3]-(.5+.5*cos(double(i%4)*M_PI/2)))<1e-6);
   assert(fabs(seen[i].stimulus.dst[0]-(10+5*cos(double(i%4)*M_PI/2)))<1e-6);
   assert(fabs(seen[i].stimulus.dst[2]-seen[i].stimulus.dst[0]-100)<1e-6);
 }
 assert(drawCount==0 && retained.expired() && retainedMask.expired());
 // Column-major MATLAB input, same phases, and exact extrema at period 2.
 double column[]={0,0, 1,0, 1,0, 2,2, 360,.5, 0,.5};
 reset();pm::playTimeline(4,view(column,2,true));
 assert(seen[0].stimulus.wave[3]==1 && seen[1].stimulus.wave[3]==0);
 assert(fabs(seen[1].stimulus.wave[2]-M_PI)<1e-6);
 // Noncontiguous/reversed and unaligned Python buffer views are valid doubles.
 char unaligned[sizeof(t)+1];memcpy(unaligned+1,t,sizeof(t));
 reset();auto uv=view(nullptr,3);uv.data=unaligned+1;pm::playTimeline(2,uv);
 assert(fabs(seen[1].stimulus.wave[2]-M_PI/2)<1e-6);
 reset();auto reversed=view(t+12,3);reversed.strides[0]=-48;pm::playTimeline(2,reversed);
 assert(fabs(seen[1].stimulus.wave[2]-M_PI/2)<1e-6);
 auto rejects=[&](auto invoke){reset();bool bad=false;try{invoke();}catch(const pm::Error&){bad=true;}assert(bad && drawCount==2 && !retained.expired());};
 rejects([&]{pm::playTimeline(0,view(t,3));});
 for(int field: {0,1,2,3}){double old=t[field];t[field]=.5;rejects([&]{pm::playTimeline(2,view(t,3));});t[field]=old;}
 double old=t[3];t[3]=3;rejects([&]{pm::playTimeline(2,view(t,3));});t[3]=old;
 old=t[4];t[4]=NAN;rejects([&]{pm::playTimeline(2,view(t,3));});t[4]=old;
 old=t[6];t[6]=1;rejects([&]{pm::playTimeline(2,view(t,3));});t[6]=old; // static draw
 old=t[7];t[7]=1;rejects([&]{pm::playTimeline(2,view(t,3));});t[7]=old; // duplicate
 old=t[10];t[10]=2;rejects([&]{pm::playTimeline(2,view(t,3));});t[10]=old; // contrast range
 old=t[16];t[16]=1000000;rejects([&]{pm::playTimeline(2,view(t,3));});t[16]=old;
 reset();cancelAt=3;result=pm::playTimeline(50,view(t,3));assert(result.cancelled && result.submitted==3 && drawCount==0 && retained.expired());
 // The request is spent by the playback it ended: the next one plays.
 reset();result=pm::playTimeline(4,view(t,3));assert(!result.cancelled && result.submitted==4);
 // A request made before playback begins is not lost: it ends that playback at once.
 reset();pm::cancelTimeline();result=pm::playTimeline(50,view(t,3));assert(result.cancelled && result.submitted==0 && drawCount==0);
 reset();result=pm::playTimeline(2,view(t,3));assert(!result.cancelled && result.submitted==2);
 pm::cancelTimeline();pm::cancelTimeline(false);reset();result=pm::playTimeline(2,view(t,3));assert(!result.cancelled);
 // A frame shown a refresh late is found, however the Flips themselves went.
 reset();lateAt=3;result=pm::playTimeline(8,view(t,3));
 assert(result.shown==8 && result.late==1 && result.lateRefreshes==1 && result.firstLateSample==3);
 assert(fabs(result.longestIntervalMs-2000/119.98)<1e-6 && fabs(result.meanSampleMs-1000/119.98*8/7)<1e-6);
 // A frame never shown is missing from shown; the next is on time, since the display kept its refresh.
 reset();missingAt=5;result=pm::playTimeline(8,view(t,3));
 assert(result.submitted==8 && result.shown==7 && result.late==0 && std::isnan(result.firstLateSample));
 assert(fabs(result.longestIntervalMs-2000/119.98)<1e-6);
 // A display running at half the expected rate makes every frame late.
 reset();result=pm::playTimeline(1,view(t,3));
 {pm::timeline::Presentations half;half.period=1/120.;for(int i=0;i<10;i++)half.note(i,5+i/60.);
  assert(half.shown==10 && half.late==9 && half.lateRefreshes==9 && half.firstLate==1 && fabs(half.meanSampleSeconds()-1/60.)<1e-12);}
 reset();escapeAt=2;result=pm::playTimeline(50,view(t,3));assert(result.cancelled && result.submitted==2 && retained.expired());
 reset();failAt=2;bool bad=false;try{pm::playTimeline(50,view(t,3));}catch(const pm::Error&){bad=true;}assert(bad && drawCount==0 && retained.expired());
 reset();result=pm::playTimeline(2,view(nullptr,0));assert(result.submitted==2 && seen[1].stimulus.wave[3]==1);
 reset();injectLive=true;pm::playTimeline(5,view(t,3));
 assert(seen[2].stimulus.wave[3]==.25 && seen[4].stimulus.wave[3]==.25 && seen[2].stimulus.dst[0]==27);
 injectLive=false;
 double k[]={0,0,0,0, 0,0,4,1, 0,2,0,0, 0,2,4,20};
 auto kv=view(k,4);kv.shape[1]=4;kv.strides[0]=32;
 reset();pm::playTimeline(6,view(nullptr,0),&kv);
 assert(seen[0].stimulus.wave[3]==0 && seen[2].stimulus.wave[3]==.5 && seen[4].stimulus.wave[3]==1 && seen[5].stimulus.wave[3]==1);
 assert(seen[2].stimulus.dst[0]==20 && seen[4].stimulus.dst[0]==30);
 rejects([&]{pm::playTimeline(6,view(t,3),&kv);}); // periodic/keyframe collision
 k[6]=0;rejects([&]{pm::playTimeline(6,view(nullptr,0),&kv);});k[6]=4;
 k[7]=2;rejects([&]{pm::playTimeline(6,view(nullptr,0),&kv);});k[7]=1;
 std::cout<<"PASS: actual native playback, uniform phases/extrema, translation, column-major input, validation, cancellation that is never lost, late and missing frames found from the display's reports, and resource cleanup.\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(code)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',str(root),str(p/'test.cpp'),str(root/'PsychMetalShared.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
