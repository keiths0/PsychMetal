#include "../PsychMetalLiveTimeline.h"
#include <atomic>
#include <cassert>
#include <thread>
#include <iostream>
pm::ArrayView view(double *p,size_t n){pm::ArrayView v;v.data=p;v.type=pm::ScalarType::Float64;v.ndim=2;v.shape={n,3,0};v.strides={24,8,0};return v;}
int main(){
 pm::timeline::LiveState state;double p[]={0,0,.5,0,2,25};auto v=view(p,2);
 auto reject=[&](auto f){bool bad=false;try{f();}catch(const pm::Error&){bad=true;}assert(bad);};
 reject([&]{state.update(v);});
 state.start({{10,20,100,200},{}},{true,false});state.update(v);
 std::vector<pm::timeline::LiveValues> snapshot(2);uint64_t version=0;state.snapshot(snapshot,version);
 assert(snapshot[0].set[0] && snapshot[0].values[0]==.5 && snapshot[0].values[2]==25);
 p[4]=0;reject([&]{state.update(v);});p[4]=2; // duplicate batch refused
 p[0]=1;reject([&]{state.update(v);});p[0]=0; // static item
 p[2]=2;reject([&]{state.update(v);});p[2]=.5;
 p[5]=1000000;reject([&]{state.update(v);});p[5]=25;
 state.snapshot(snapshot,version);assert(snapshot[0].values[2]==25);
 // Concurrent paired controls must never expose half an update.
 std::atomic<bool> done{false};
 std::thread writer([&]{for(int i=0;i<10000;i++){double values[]={0,2,double(i%100),0,3,double(i%100)};state.update(view(values,2));}done=true;});
 // Install a pair before observing to distinguish the earlier x-only control.
 double pair[]={0,2,0,0,3,0};state.update(view(pair,2));
 while(!done){state.snapshot(snapshot,version);assert(!snapshot[0].set[3] || snapshot[0].values[2]==snapshot[0].values[3]);}
 writer.join();state.stop();reject([&]{state.update(v);});
 std::cout<<"PASS: timeline update transactions, bounds, active-session checks, persistent overrides and concurrent snapshots.\n";
}
