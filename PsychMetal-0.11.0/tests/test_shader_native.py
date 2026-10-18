from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'PsychMetalEngine.mm').read_text()
def function(sig):
 a=s.index(sig);return s[a:s.index('\n}',a)+2]
code=r'''
#include "PsychMetalEngine.h"
#include <cmath>
#include <cstring>
#include <memory>
#include <map>
#include <cassert>
#include <pthread.h>
#include <iostream>
using std::isfinite;
[[noreturn]] void fail(const char*s){throw pm::Error(s);}
constexpr int PM_MAX_SHAPES=4,PM_ITEM_CUSTOM=4;
int device=1;bool closing=false;size_t drawCount=0;unsigned blendMode=1;int clipRect[4]={1,2,30,40};float currentXf[6]={};
struct Uniform {float dst[4],mean[4],wave[4],noise[4],aperture[4],viewport[4],maskA[4],maskB[4];};
struct PMDrawItem {int type;unsigned blend;int clip[4];float xf[6];Uniform stimulus;};
struct Resource {int channels=1;bool offscreen=false;};
using PMTextureRef=std::shared_ptr<Resource>;using PMShaderRef=std::shared_ptr<int>;
std::map<uint64_t,PMShaderRef> userShaders;PMShaderRef drawShaderRefs[4];
PMTextureRef userTextures[2]={std::make_shared<Resource>(),std::make_shared<Resource>()},drawTextureRefs[4];
PMDrawItem drawList[4];pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
int textureSlot(uint64_t h){if(h<1 || h>2 || !userTextures[h-1])fail("handle");return int(h-1);}
'''+function('static inline double viewAt(')+'\n'+function('void pm::drawShader(')+function('void pm::closeShader(')+r'''
pm::ArrayView view(double*p,size_t n){pm::ArrayView v;v.data=p;v.type=pm::ScalarType::Float64;v.ndim=1;v.shape={n,0,0};v.strides={8,0,0};return v;}
int main(){
 userShaders[1]=std::make_shared<int>(9);auto weak=std::weak_ptr<int>(userShaders[1]);
 double params[16],rect[]={0,0,100,100};for(int i=0;i<16;i++)params[i]=i;
 auto p=view(params,16),r=view(rect,4);pm::drawShader(1,p,r,1);
 assert(drawCount==1 && drawList[0].type==4 && drawList[0].blend==1 && drawList[0].clip[0]==1);
 assert(drawList[0].stimulus.mean[3]==3 && drawList[0].stimulus.aperture[3]==15);
 params[0]=.75;assert(drawList[0].stimulus.mean[0]==0);
 auto reject=[&](auto f){size_t before=drawCount;bool bad=false;try{f();}catch(const pm::Error&){bad=true;}assert(bad && drawCount==before);};
 for(int i=0;i<16;i++){double old=params[i];params[i]=NAN;reject([&]{pm::drawShader(1,p,r,0);});params[i]=old;}
 params[0]=1e7;reject([&]{pm::drawShader(1,p,r,0);});params[0]=0;
 userTextures[1]->channels=4;reject([&]{pm::drawShader(1,p,r,2);});
 rect[2]=0;reject([&]{pm::drawShader(1,p,r,0);});rect[2]=100;
 double m[]={1,.35,0,1,0,0,0,0};auto mv=view(m,8);pm::drawShader(1,p,r,0,&mv);assert(drawList[1].stimulus.maskA[0]==1);
 pm::closeShader(1);assert(!weak.expired());reject([&]{pm::drawShader(1,p,r,0);});
 drawShaderRefs[0].reset();drawShaderRefs[1].reset();assert(weak.expired());
 std::cout<<"PASS: actual custom shader queue snapshots, sixteen-parameter ABI, coverage/clip/blend, rejection and close-after-draw lifetime.\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(code)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',str(root),str(p/'test.cpp'),str(root/'PsychMetalShared.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

# Source order and compiler-message filtering, without a Metal compiler.
wrapper=r'''
#include "PsychMetalCustomShader.h"
#include <cassert>
#include <iostream>
using pm::internal::customShaderSource;using pm::internal::customShaderErrors;
int main(){
 std::string full=customShaderSource("BASE","#define saturate(x) (x)\nUSER");
 size_t wrap=full.find("fragment float4 cfmain"),user=full.find("#line 1 \"psychmetal-user.metal\"\n#define saturate");
 assert(full.rfind("BASE",0)==0 && wrap!=std::string::npos && user!=std::string::npos && wrap<user);
 assert(full.find("clamp(color.rgb,0.0,max(1.0,u.viewport.z))")<user);   // the wrapper's clamp precedes any user macro
 assert(full.find("float4 psychmetal_main(float2 pixel,float2 uv,constant float4 *parameters);")<wrap);
 std::string log="Compilation failed: \n\npsychmetal-wrapper.metal:4:1: warning: engine note\nint a;\n^\n"
                 "psychmetal-user.metal:3:5: error: use of undeclared identifier 'q'\n return q;\n        ^\n"
                 "psychmetal-wrapper.metal:9:2: note: unrelated\n";
 std::string kept=customShaderErrors(log);
 assert(kept=="psychmetal-user.metal:3:5: error: use of undeclared identifier 'q'\n return q;\n        ^");
 assert(customShaderErrors("Compilation failed: something else")=="Compilation failed: something else");
 assert(customShaderErrors(std::string(20000,'x')).size()==16388);
 std::cout<<"PASS: custom shader wrapper precedes user source; compiler messages are the user's own, untruncated.\n";
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'wrapper.cpp').write_text(wrapper)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',str(root),str(p/'wrapper.cpp'),'-o',str(p/'wrapper')],check=True)
 subprocess.run([str(p/'wrapper')],check=True)
