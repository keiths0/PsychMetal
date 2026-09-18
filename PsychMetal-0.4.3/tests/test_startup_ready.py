from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'PsychMetalCore.mm').read_text()
a=s.index('static void confirmStartup()');b=s.index('static Record waitScheduled',a);body=s[a:b]
a=s.index('typedef struct {');b=s.index('} Record;',a)+len('} Record;');record=s[a:b]
source=r'''
#include <vector>
#include <stdexcept>
#include <cassert>
#include <cstdint>
#include <cerrno>
'''+record+r'''
int device=1,drawCount=0,preparedToken=0,prefetchDrawable=0,heldDrawable=0,lock=0;
bool closing=false,startupReady=false,asynchronousGpuFailure=false,locked=false,timeout=false;
uint64_t firstSessionToken=1,nextToken=1,lastSlipToken=0,lastConfirmedToken=99;
int confirmedCount=9,missingPresentedCount=9,pendingSlipRefreshes=5;
double now=0;Record current{};std::vector<Record> startupRecords;std::vector<int> sequence;
[[noreturn]]void fail(const char*s){throw std::runtime_error(s);}
double CACurrentMediaTime(){return now+=.001;}
void pthread_mutex_lock(int*){assert(!locked);locked=true;}
void pthread_mutex_unlock(int*){assert(locked);locked=false;}
int waitRelative(double){now=3;return ETIMEDOUT;}
uint64_t enqueue(double,bool){
 int status=sequence.empty()?1:sequence[(nextToken-1)%sequence.size()];
 current=Record{};current.token=nextToken++;current.status=status;
 current.done=current.gpuDone=!timeout;current.presented=status==0?now:0;
 return current.token;
}
Record*recordFor(uint64_t){return &current;}
'''+body+r'''
void reset(){now=0;startupRecords.clear();startupReady=false;nextToken=1;timeout=false;sequence.clear();assert(!locked);}
int main(){
 reset();sequence={1,0,1,0,0};confirmStartup();assert(startupReady&&startupRecords.size()==5&&firstSessionToken==6);
 assert(confirmedCount==0&&missingPresentedCount==0&&pendingSlipRefreshes==0&&lastSlipToken==99);
 confirmStartup();assert(startupRecords.size()==5&&nextToken==6);
 reset();bool failed=false;try{confirmStartup();}catch(...){failed=true;}assert(failed&&startupRecords.size()==12&&!locked&&!startupReady);
 reset();timeout=true;failed=false;try{confirmStartup();}catch(...){failed=true;}assert(failed&&startupRecords.size()==1&&!locked);
 reset();sequence={3};failed=false;try{confirmStartup();}catch(...){failed=true;}assert(failed&&startupRecords.size()==1&&!locked);
 reset();drawCount=1;failed=false;try{confirmStartup();}catch(...){failed=true;}assert(failed&&startupRecords.empty());
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(source)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: consecutive confirmations, retained dropped attempts, user-history boundary, idempotency, attempt limit, timeout/GPU failure unlock and queued-draw rejection.')
