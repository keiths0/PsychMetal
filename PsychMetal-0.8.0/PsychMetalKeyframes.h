#ifndef PSYCHMETAL_KEYFRAMES_H
#define PSYCHMETAL_KEYFRAMES_H
#include "PsychMetalEngine.h"
#include "PsychMetalTimeline.h"
#include <array>
#include <cstring>
#include <map>
#include <vector>
namespace pm { namespace timeline {
struct KeyTrack {size_t draw,parameter;std::vector<Keyframe> keys;};
inline std::vector<KeyTrack> keyTracks(const ArrayView *input,
 const std::vector<std::array<double,4>> &bounds,const std::vector<bool> &eligible,
 std::vector<std::array<bool,4>> &used) {
 std::vector<KeyTrack> result;if(!input)return result;
 const auto &v=*input;
 if(v.type!=ScalarType::Float64 || v.ndim!=2 || v.shape[1]!=4 || v.shape[0]>1000000 || (v.shape[0] && !v.data))throw Error("Keyframes must be N x 4 doubles.");
 std::map<std::pair<size_t,size_t>,size_t> groups;
 for(size_t i=0;i<v.shape[0];i++) {
  double p[4];for(int j=0;j<4;j++)memcpy(p+j,(const char*)v.data+(ptrdiff_t)i*v.strides[0]+j*v.strides[1],8);
  auto draw=checkUnsigned(p[0],"keyframe draw",8191),parameter=checkUnsigned(p[1],"keyframe parameter",3),frame=checkUnsigned(p[2],"keyframe sample",1000000);
  if(draw>=bounds.size() || !eligible[draw])throw Error("Keyframes must target procedural stimulus draws.");
  if(!std::isfinite(p[3]) || std::fabs(p[3])>1e6 || (parameter==0 && (p[3]<0 || p[3]>1)))throw Error("Keyframe value outside parameter range.");
  if(parameter>=2){size_t axis=parameter-2;if(bounds[draw][axis]+p[3]<-1e6 || bounds[draw][axis+2]+p[3]>1e6)throw Error("Keyframe translation outside coordinate range.");}
  auto id=std::make_pair(size_t(draw),size_t(parameter));auto group=groups.find(id);
  if(group==groups.end()) {
   if(used[draw][parameter])throw Error("A parameter cannot have both periodic and keyframe tracks.");
   used[draw][parameter]=true;groups[id]=result.size();result.push_back({size_t(draw),size_t(parameter),{}});group=groups.find(id);
  }
  auto &keys=result[group->second].keys;
  if(!keys.empty() && frame<=keys.back().frame)throw Error("Keyframe samples must be strictly increasing per parameter.");
  keys.push_back({frame,p[3]});
 }
 return result;
}
}}
#endif
