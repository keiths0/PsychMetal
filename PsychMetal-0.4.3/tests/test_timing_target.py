from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalCore.mm').read_text();a=s.index('struct PMPresentationTarget');b=s.index('// Caller holds lock',a)
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
# Exercise the actual pacing guard with deterministic condition-wait callbacks.
a=s.index('static uint64_t enqueueDirect(');a=s.index('{',a)+1;b=s.index('    uint64_t t = nextToken++;',a)
guard=s[a:b]
source=r'''
#include <cstdint>
#include <stdexcept>
#include <cassert>
#include <cerrno>
static bool asynchronousGpuFailure=false,displaySync=true,closing=false,locked=false,timeout=false;
static uint64_t nextToken=1,PM_MAX_ID=1000;
static int timingPolicy=0,inFlightCount=0,gridSamples=0,lock=0,waits=0;
double CACurrentMediaTime(){return 100;}
void pthread_mutex_unlock(int*){locked=false;}
[[noreturn]] void fail(const char*s){throw std::runtime_error(s);}
int waitRelative(double){++waits;if(timeout)return ETIMEDOUT;--inFlightCount;return 0;}
void pacing(){
'''+guard+r'''
}
int main(){
 locked=true;inFlightCount=2;pacing();assert(waits==0&&locked);
 timingPolicy=1;gridSamples=0;inFlightCount=1;pacing();assert(waits==1&&inFlightCount==0&&locked);
 waits=0;gridSamples=10;inFlightCount=2;pacing();assert(waits==1&&inFlightCount==1&&locked);
 waits=0;displaySync=false;inFlightCount=3;pacing();assert(waits==0&&locked);
 displaySync=true;timeout=true;bool raised=false;
 try{pacing();}catch(...){raised=true;}assert(raised&&!locked);
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(source)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: baseline bypass, startup/steady queue limits, unsynchronized bypass, timeout unlock.')
