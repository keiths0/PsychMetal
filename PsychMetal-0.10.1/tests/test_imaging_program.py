"""Actual native pipeline preparation/validation, without claiming GPU pixels."""
from pathlib import Path
import sys,subprocess,tempfile
if sys.platform!='darwin':
 print('SKIP: imaging program fixture requires Foundation.');raise SystemExit(0)
r=Path(__file__).resolve().parents[1];s=(r/'PsychMetalImaging.h').read_text()
helpers=s[:s.index('void pm::closeImagePipeline(')]
code=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "PsychMetalInternal.h"
#include <map>
#include <memory>
#include <vector>
#include <cstring>
#include <cassert>
#include <cstdarg>
using PMTextureRef=std::shared_ptr<int>;
static bool device=true,closing=false;
constexpr int PM_BLEND_COPY=0;
constexpr uint64_t PM_MAX_ID=pm::kMaxId;
[[noreturn]] void fail(const char*s){throw pm::Error(s);}
[[noreturn]] void failWith(const char*,const char*,...){throw pm::Error("pipeline");}
static double viewAt(const pm::ArrayView &v,size_t i,size_t c){double x;memcpy(&x,(const char*)v.data+i*v.strides[0]+c*v.strides[1],8);return x;}
static id<MTLRenderPipelineState> makePipeline(NSString*,NSString*,MTLPixelFormat,pm::internal::Blend,NSError**){return nil;}
'''+helpers+r'''
int main(){@autoreleasepool {
 imageProcessingPipeline=(id<MTLRenderPipelineState>)[NSObject new]; // GPU compilation intentionally not exercised
 double data[32]={1,2,0};pm::ArrayView v;v.type=pm::ScalarType::Float64;v.ndim=2;v.data=data;v.shape={1,32,0};v.strides={256,8,0};
 auto h=pm::createImagePipeline(v);auto p=imagePipelines[h];assert(p->passes.size()==2&&p->passes[0].kind==1&&p->passes[1].kind==2);
 double sum=p->passes[0].v[0];for(unsigned i=1;i<=p->passes[0].radius;i++)sum+=2*p->passes[0].v[i];assert(std::abs(sum-1)<1e-6);
 auto rejects=[&]{size_t before=imagePipelines.size();bool bad=false;try{pm::createImagePipeline(v);}catch(const pm::Error&){bad=true;}assert(bad&&imagePipelines.size()==before);};
 data[1]=0;rejects();data[1]=11;rejects();data[1]=2;data[2]=1.5;rejects();data[2]=32;rejects();data[2]=0;
 data[0]=3;data[1]=3;h=pm::createImagePipeline(v);assert(imagePipelines[h]->passes[0].v[0]==8);data[1]=17;rejects();
 data[0]=5;data[1]=4;rejects();data[1]=3;data[2]=1;h=pm::createImagePipeline(v);assert(imagePipelines[h]->passes[0].radius==3);
 data[0]=4;data[1]=NAN;rejects();data[1]=0;data[31]=INFINITY;rejects();data[31]=0;data[0]=2;rejects();
 closeImagePipelines();assert(imagePipelines.empty());
} }
'''
with tempfile.TemporaryDirectory() as temp:
 p=Path(temp);(p/'program.mm').write_text(code)
 subprocess.run(['clang++','-std=c++17','-fobjc-arc','-fsanitize=address,undefined','-iquote',r,p/'program.mm',r/'PsychMetalShared.cpp','-framework','Foundation','-framework','Metal','-o',p/'program'],check=True)
 subprocess.run([p/'program'],check=True)
print('PASS: actual pipeline preparation, normalized Gaussian passes, exposure, kernels, finite/bounds checks and transactional rejection.')
