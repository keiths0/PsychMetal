#!/usr/bin/env python3
"""Exercise production DrawTexture validation and packing without a GPU."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
src=(root/'PsychMetalCore.mm').read_text()
a=src.index('        if (cmd(prhs[0], "DrawTexture")) {');b=src.index('\n        if (cmd(prhs[0], ',a+1);block=src[a:b]
a=src.index('template<class T> [[clang::noinline]] static void packImageLinear');b=src.index('static void uploadTexture',a);pack=src[a:b]
pre=r'''
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cfloat>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
#include <pthread.h>
using std::isfinite;
struct mxArray { double v[4]={}; int count=4; bool sparse=false,complex=false; };
bool cmd(const mxArray*,const char*) {return true;}
bool mxIsDouble(const mxArray*) {return true;}
bool mxIsComplex(const mxArray* a){return a->complex;}
bool mxIsSparse(const mxArray* a){return a->sparse;}
int mxGetNumberOfElements(const mxArray* a){return a->count;}
const double* mxGetPr(const mxArray* a){return a->v;}
[[noreturn]] void fail(const char* s){throw std::runtime_error(s);}
double scalar(const mxArray* a,const char* s){if(a->count!=1 || a->sparse || a->complex || !isfinite(a->v[0]))fail(s);return a->v[0];}
uint64_t unsignedScalar(const mxArray* a,const char* s,uint64_t max){double v=scalar(a,s);if(v<0||v!=floor(v)||v>max)fail(s);return v;}
int textureSlot(const mxArray* a){if(unsignedScalar(a,"handle",100)!=1)fail("handle");return 0;}
constexpr int PM_MAX_TEXTURES=256,PM_MAX_SHAPES=8192,PM_ITEM_TEXTURE=1;
int device=1,drawCount=0;
struct Resource{int identity;};
std::shared_ptr<Resource> userTextures[256]={std::make_shared<Resource>(Resource{7})};
std::shared_ptr<Resource> drawTextures[8192];
struct PMDrawItem{int type,texIndex;float src[4],dst[4],tint[4],angle;int filterMode;};
PMDrawItem drawList[8192];pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
std::vector<__fp16> uploadScratch;
void dispatch(int nrhs,int nlhs,const mxArray** prhs) {
'''
post=r'''
}
int main(){
 mxArray args[7];args[1].count=args[4].count=args[6].count=1;args[1].v[0]=1;
 for(double &v:args[5].v)v=1;
 const mxArray* in[7];for(int i=0;i<7;i++)in[i]=&args[i];
 auto reject=[&](){bool failed=false;try{dispatch(7,0,in);}catch(...){failed=true;}assert(failed&&drawCount==0);assert(pthread_mutex_trylock(&lock)==0);pthread_mutex_unlock(&lock);};
 args[4].v[0]=NAN;reject();args[4].v[0]=0;
 args[6].v[0]=2;reject();args[6].v[0]=0;
 args[2].sparse=true;reject();args[2].sparse=false;
 args[2].v[0]=INFINITY;reject();args[2].v[0]=0;
 dispatch(7,0,in);assert(drawCount==1&&drawTextures[0]->identity==7);
 userTextures[0]=std::make_shared<Resource>(Resource{9});assert(drawTextures[0]->identity==7);
 double gray[]={0,.25,.5,.75,1,2};packImage(gray,2,3,1,1);
 double expected[]={0,.5,1,.25,.75,1};for(int i=0;i<6;i++)assert(double(uploadScratch[i])==expected[i]);
 uint8_t rgb[]={255,0,0,255,0,0};packImage(rgb,1,2,3,1.0/255);
 assert(uploadScratch.size()==8);double color[]={1,0,0,1,0,1,0,1};for(int i=0;i<8;i++)assert(double(uploadScratch[i])==color[i]);
 float rgba[]={.25,.5,.75,1};packImage(rgba,1,1,4,1);for(int i=0;i<4;i++)assert(float(uploadScratch[i])==rgba[i]);
 bool bad=false;double nan=NAN;try{packImage(&nan,1,1,1,1);}catch(...){bad=true;}assert(bad);
 std::cout<<"PASS: native validation leaves mutex/state intact; queued resource snapshot; native planar packing, grayscale/RGB/RGBA, uint8 scaling, clamping and NaN rejection.\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
 f=Path(tmp)/'dispatch.cpp';f.write_text(pre+block+'\n}\n'+pack+post[2:])
 exe=Path(tmp)/'dispatch'
 subprocess.run(['c++','-std=c++17','-pthread','-fsanitize=address,undefined','-fno-omit-frame-pointer',str(f),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
