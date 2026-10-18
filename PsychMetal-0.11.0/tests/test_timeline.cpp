#include <initializer_list>
#include "../PsychMetalTimeline.h"
#include <cassert>
#include <limits>
int main() {
 using namespace pm::timeline;
 for(uint64_t p: {2,4,6,8,16,32,64,128}) {
  double hz=119.98/double(p);
  assert(periodFor(119.98,hz)==p);
  assert(oscillation(0,p)==1 && oscillation(p/2,p)==-1 && oscillation(p,p)==1);
  for(uint64_t f=0;f<p;f++) assert(std::abs(oscillation(f,p)+oscillation(f+p/2,p))<1e-12);
 }
 for(double bad:{0.,-1.,60.,std::numeric_limits<double>::quiet_NaN()}) {
  bool rejected=false;try {periodFor(119.98,bad);} catch(const std::invalid_argument&){rejected=true;} assert(rejected);
 }
 for(uint64_t p:{0,1,3}) {bool rejected=false;try {oscillation(0,p);}catch(const std::invalid_argument&){rejected=true;}assert(rejected);}
 Keyframe keys[]={{10,0},{20,1},{30,-1}};validate(keys,3);
 assert(sample(keys,3,0)==0 && sample(keys,3,15)==.5 && sample(keys,3,25)==0 && sample(keys,3,100)==-1);
 uint64_t start=(uint64_t(1)<<60);Keyframe late[]={{start,0},{start+10,1}};validate(late,2);assert(sample(late,2,start+5)==.5);
 Keyframe invalid[]={{1,0},{1,1}};bool rejected=false;try {validate(invalid,2);}catch(const std::invalid_argument&){rejected=true;}assert(rejected);
}
