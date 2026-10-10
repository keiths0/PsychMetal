// Concurrent, bounded latest-value controls for a captured native timeline.
#ifndef PSYCHMETAL_LIVE_TIMELINE_H
#define PSYCHMETAL_LIVE_TIMELINE_H
#include "PsychMetalEngine.h"
#include <array>
#include <cmath>
#include <cstring>
#include <mutex>
#include <set>
#include <vector>
namespace pm { namespace timeline {
struct LiveValues {std::array<double,4> values{};std::array<bool,4> set{};};
class LiveState {
 std::mutex mutex;
 bool active=false;
 uint64_t version=0;
 std::vector<std::array<double,4>> bounds;
 std::vector<bool> enabled;
 std::vector<LiveValues> values;
public:
 void start(const std::vector<std::array<double,4>> &rects,const std::vector<bool> &eligible) {
  std::lock_guard<std::mutex> guard(mutex);
  bounds=rects;enabled=eligible;values.assign(rects.size(),{});version=1;active=true;
 }
 void stop() {std::lock_guard<std::mutex> guard(mutex);active=false;}
 void update(const ArrayView &input) {
  if(input.type!=ScalarType::Float64 || input.ndim!=2 || input.shape[1]!=3 || input.shape[0]>32768 || (input.shape[0] && !input.data))throw Error("Timeline updates must be N x 3 doubles.");
  struct Update {size_t draw,param;double value;};std::vector<Update> pending;pending.reserve(input.shape[0]);
  std::set<std::pair<size_t,size_t>> used;
  for(size_t i=0;i<input.shape[0];i++) {
   double p[3];for(int j=0;j<3;j++)memcpy(p+j,(const char*)input.data+(ptrdiff_t)i*input.strides[0]+j*input.strides[1],8);
   auto draw=checkUnsigned(p[0],"timeline draw index",8191),param=checkUnsigned(p[1],"timeline parameter",3);
   if(!std::isfinite(p[2]) || std::fabs(p[2])>1e6 || (param==0 && (p[2]<0 || p[2]>1)) || !used.emplace(draw,param).second)throw Error("Invalid or duplicate timeline update.");
   pending.push_back({(size_t)draw,(size_t)param,p[2]});
  }
  std::lock_guard<std::mutex> guard(mutex);
  if(!active)throw Error("No native timeline is active.");
  for(auto &u:pending) {
   if(u.draw>=values.size() || !enabled[u.draw])throw Error("Timeline updates must target procedural stimulus draws.");
   if(u.param>=2) {size_t a=u.param-2;if(bounds[u.draw][a]+u.value < -1e6 || bounds[u.draw][a+2]+u.value>1e6)throw Error("Timeline update moves the stimulus outside the coordinate range.");}
  }
  for(auto &u:pending){values[u.draw].values[u.param]=u.value;values[u.draw].set[u.param]=true;}
  ++version;
 }
 // The render worker never waits for the controlling thread. If it is updating,
 // retain the previous complete snapshot for this frame and try again next time.
 void snapshot(std::vector<LiveValues> &out,uint64_t &seen) {
  std::unique_lock<std::mutex> guard(mutex,std::try_to_lock);
  if(guard.owns_lock() && active && version!=seen) {
   if(out.size()!=values.size())throw Error("Internal timeline snapshot size mismatch.");
   std::copy(values.begin(),values.end(),out.begin());seen=version;
  }
 }
};
}}
#endif
