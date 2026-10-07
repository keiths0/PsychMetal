#!/usr/bin/env python3
"""Compile the actual native draw function and shared validation with GPU-free stubs.
Tests draw-time snapshots, mask lifetime, and atomic rejection. No pixel claims.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text()
def function(signature):
 a=s.index(signature);return s[a:s.index('\n}',a)+2]
code=r'''
#include "PsychMetalEngine.h"
#include <cmath>
#include <cfloat>
#include <cstring>
#include <memory>
#include <cassert>
#include <pthread.h>
#include <iostream>
using std::isfinite;
[[noreturn]] void fail(const char*s){throw pm::Error(pm::kErrGeneral,s);}
constexpr int PM_MAX_SHAPES=4,PM_ITEM_STIMULUS=2;
int device=1;bool closing=false;size_t drawCount=0;unsigned blendMode=1;int clipRect[4]={1,2,30,40};
struct PMStimulusUniform {float dst[4],mean[4],wave[4],noise[4],aperture[4],viewport[4];};
struct PMDrawItem {int type;unsigned blend;int clip[4];PMStimulusUniform stimulus;};
struct Resource {int channels=1;bool offscreen=false;};
using PMTextureRef=std::shared_ptr<Resource>;
PMTextureRef userTextures[2]={std::make_shared<Resource>(),std::make_shared<Resource>()},drawTextureRefs[4];
PMDrawItem drawList[4];pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
int textureSlot(uint64_t h){if(h<1 || h>2 || !userTextures[h-1])fail("handle");return int(h-1);}
'''+function('static inline double viewAt(')+'\n'+function('void pm::drawStimulus(')+r'''
pm::ArrayView view(double*p,size_t n){pm::ArrayView v;v.data=p;v.type=pm::ScalarType::Float64;v.ndim=1;v.shape={n,0,0};v.strides={8,0,0};return v;}
int main(){
 double p[15]={0,.5,.5,.5,1,.02,90,180,1,1,0,0,1,0,.35},r[4]={10,20,310,220};
 auto pv=view(p,15),rv=view(r,4);
 pm::drawStimulus(pv,rv,1);assert(drawCount==1 && drawList[0].blend==1 && drawList[0].clip[0]==1);
 assert(fabs(drawList[0].stimulus.wave[1]-M_PI/2)<1e-6);
 auto weak=std::weak_ptr<Resource>(userTextures[0]);userTextures[0].reset();assert(!weak.expired());
 p[7]=0;assert(fabs(drawList[0].stimulus.wave[2]-M_PI)<1e-6);
 auto reject=[&](auto f){size_t n=drawCount;bool bad=false;try{f();}catch(const pm::Error&){bad=true;}assert(bad && drawCount==n);};
 reject([&]{pm::drawStimulus(pv,rv,1);});
 userTextures[1]->channels=3;reject([&]{pm::drawStimulus(pv,rv,2);});
 for(int i=0;i<15;i++){double old=p[i];p[i]=NAN;reject([&]{pm::drawStimulus(pv,rv,0);});p[i]=old;}
 p[5]=.6;reject([&]{pm::drawStimulus(pv,rv,0);});p[5]=.02;
 p[9]=0;reject([&]{pm::drawStimulus(pv,rv,0);});p[9]=1;
 r[2]=r[0];reject([&]{pm::drawStimulus(pv,rv,0);});r[2]=310;
 drawCount=4;reject([&]{pm::drawStimulus(pv,rv,0);});
 drawTextureRefs[0].reset();assert(weak.expired());
 std::cout<<"PASS: native stimulus validation, snapshots, mask lifetime, blend/clip, and rejection.\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(code)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',str(root),str(p/'test.cpp'),str(root/'PsychMetalShared.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
