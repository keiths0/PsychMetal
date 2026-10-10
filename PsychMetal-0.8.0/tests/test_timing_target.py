from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text();a=s.index('struct PMPresentationTarget');b=s.index('// Caller holds lock',a)
body=s[a:b]
source='#include <cmath>\n#include <algorithm>\n#include <cassert>\nusing std::isfinite;\n'+body+r'''
int main(){
 auto p=presentationTarget(100,101,true,NAN,1./60);
 assert(p.target==101 && p.request==101);
 p=presentationTarget(102,101,true,NAN,1./60);assert(p.target==102 && p.request==102);
 p=presentationTarget(100,101,true,101.01,1./60);assert(p.target==101.01 && std::abs(p.request-(101.01-.5/60))<1e-12);
 p=presentationTarget(100,0,false,NAN,1./60);assert(std::isnan(p.target)&&std::isnan(p.request));
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(source)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: first scheduled deadline preserved without grid; elapsed deadline, calibrated grid, immediate mode.')
# The guard that opens every submission: a failed session refuses, and releases the lock it was given.
a=s.index('static uint64_t enqueueDirect(');a=s.index('{',a)+1;b=s.index('    uint64_t t = nextToken++;',a)
guard=s[a:b]
assert 'pthread_mutex_unlock' in guard and 'fail(' in guard
source=r'''
#include <cstdint>
#include <stdexcept>
#include <cassert>
static bool asynchronousGpuFailure=false,locked=false;
static uint64_t nextToken=1,PM_MAX_ID=1000;
static int lock=0;
void pthread_mutex_unlock(int*){locked=false;}
[[noreturn]] void fail(const char*s){throw std::runtime_error(s);}
void guard(){
'''+guard+r'''
}
int main(){
 locked=true;guard();assert(locked);
 for(int broken=0;broken<2;broken++){
  asynchronousGpuFailure=broken==0;nextToken=broken==0?1:PM_MAX_ID;locked=true;bool raised=false;
  try{guard();}catch(...){raised=true;}assert(raised&&!locked);
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(source)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: a healthy session proceeds holding the lock; a GPU failure or exhausted tokens refuse and release it.')
