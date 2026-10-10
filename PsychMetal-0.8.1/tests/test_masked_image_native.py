#!/usr/bin/env python3
"""Actual masked-image queue function with CPU resource doubles, ASan/UBSan."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text()
def function(signature):
 a=s.index(signature);return s[a:s.index('\n}',a)+2]
code=r'''
#include "PsychMetalEngine.h"
#include <cmath>
#include <cstring>
#include <memory>
#include <cassert>
#include <pthread.h>
#include <iostream>
using std::isfinite;
[[noreturn]] void fail(const char*s){throw pm::Error(pm::kErrGeneral,s);}
constexpr int PM_MAX_SHAPES=4,PM_ITEM_MASKED_TEXTURE=3;
int device=1;bool closing=false;size_t drawCount=0;unsigned blendMode=1;int clipRect[4]={1,2,30,40};
struct Uniform {float maskA[4],maskB[4];};
struct PMDrawItem {int type;unsigned blend;int clip[4];float src[4],dst[4],tint[4],angle;int filterMode;Uniform stimulus;};
struct Resource {int channels=1;bool offscreen=false;};
using PMTextureRef=std::shared_ptr<Resource>;
PMTextureRef userTextures[3],drawTextureRefs[4],drawCoverageRefs[4],targetTexture;
PMDrawItem drawList[4];pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
int textureSlot(uint64_t h){if(h<1 || h>3 || !userTextures[h-1])fail("handle");return int(h-1);}
'''+function('static inline double viewAt(')+'\n'+function('void pm::drawMaskedTexture(')+r'''
pm::ArrayView view(double*p,size_t n){pm::ArrayView v;v.data=p;v.type=pm::ScalarType::Float64;v.ndim=1;v.shape={n,0,0};v.strides={8,0,0};return v;}
int main(){
 for(auto &t:userTextures)t=std::make_shared<Resource>();userTextures[0]->channels=4;
 double p[14]={.1,.2,.9,.8,10,20,310,220,1,.5,.25,.8,.5,1},c[8]={2,.35,.4,1,.1,0,0,0};
 auto pv=view(p,14),cv=view(c,8);
 pm::drawMaskedTexture(1,pv,2,&cv);
 assert(drawCount==1 && drawList[0].blend==1 && drawList[0].clip[0]==1);
 assert(drawList[0].type==PM_ITEM_MASKED_TEXTURE && drawList[0].angle==.5 && drawList[0].filterMode==1);
 assert(fabs(drawList[0].src[0]-.1)<1e-6 && drawList[0].dst[3]==220);
 assert(drawList[0].stimulus.maskA[0]==2 && fabs(drawList[0].stimulus.maskB[0]-.1)<1e-6);
 auto source=std::weak_ptr<Resource>(userTextures[0]),mask=std::weak_ptr<Resource>(userTextures[1]);
 userTextures[0]=std::make_shared<Resource>();userTextures[1].reset(); // update/close retain queued versions
 assert(!source.expired() && !mask.expired());
 p[0]=.3;c[4]=.2;assert(fabs(drawList[0].src[0]-.1)<1e-6 && fabs(drawList[0].stimulus.maskB[0]-.1)<1e-6);
 auto reject=[&](auto f){size_t n=drawCount;auto old=drawTextureRefs[0];bool bad=false;try{f();}catch(const pm::Error&){bad=true;}assert(bad && drawCount==n && drawTextureRefs[0]==old);};
 for(int i=0;i<14;i++){double old=p[i];p[i]=NAN;reject([&]{pm::drawMaskedTexture(1,pv,0);});p[i]=old;}
 for(int i=0;i<8;i++){double old=c[i];c[i]=NAN;reject([&]{pm::drawMaskedTexture(1,pv,0,&cv);});c[i]=old;}
 p[0]=-.1;reject([&]{pm::drawMaskedTexture(1,pv,0);});p[0]=.1;
 p[2]=1.1;reject([&]{pm::drawMaskedTexture(1,pv,0);});p[2]=.9;
 p[6]=p[4];reject([&]{pm::drawMaskedTexture(1,pv,0);});p[6]=310;
 p[13]=2;reject([&]{pm::drawMaskedTexture(1,pv,0);});p[13]=0;
 reject([&]{pm::drawMaskedTexture(1,pv,2);}); // closed image mask
 userTextures[2]->channels=3;reject([&]{pm::drawMaskedTexture(1,pv,3);});
 userTextures[2]->channels=1;userTextures[2]->offscreen=true;reject([&]{pm::drawMaskedTexture(1,pv,3);});
 targetTexture=userTextures[0];reject([&]{pm::drawMaskedTexture(1,pv,0);});targetTexture.reset();
 char raw[113];memcpy(raw+1,p,112);auto unaligned=pv;unaligned.data=raw+1;pm::drawMaskedTexture(1,unaligned,0);
 assert(drawList[1].stimulus.maskA[0]==-1);
 double reverse[14];for(int i=0;i<14;i++)reverse[13-i]=p[i];auto reversed=pv;reversed.data=reverse+13;reversed.strides[0]=-8;
 pm::drawMaskedTexture(1,reversed,0);assert(drawCount==3 && drawList[2].dst[3]==220);
 drawCount=4;reject([&]{pm::drawMaskedTexture(1,pv,0);});
 drawTextureRefs[0].reset();drawCoverageRefs[0].reset();assert(source.expired() && mask.expired());
 std::cout<<"PASS: actual masked-image validation, queued source/mask versions, snapshot, strides and atomic rejection.\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(code)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',str(root),str(p/'test.cpp'),str(root/'PsychMetalShared.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
