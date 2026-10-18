"""Native movie reporting advances past terminal missing frames, not pending ones."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'PsychMetalMovie.h').read_text()
a=s.index('static void collectMoviePresentations(');helper=s[a:s.index('\n}\n',a)+3]
code=r'''
#include "PsychMetalTimeline.h"
#include <cassert>
#include <map>
struct Record {int status;bool done;double presented;};
static std::map<uint64_t,Record> records;
static int lock=0;static bool locked=false;
void pthread_mutex_lock(int*){assert(!locked);locked=true;}
void pthread_mutex_unlock(int*){assert(locked);locked=false;}
Record *recordFor(uint64_t token){auto at=records.find(token);return at==records.end()?nullptr:&at->second;}
bool reportedPresentation(uint64_t token,double &time){auto r=recordFor(token);if(!r||r->status!=0||!r->done)return false;time=r->presented;return time>0;}
''' +helper+r'''
int main(){
 records={{10,{1,true,0}},{11,{2,false,0}},{12,{0,true,100.02}},{13,{1,false,0}},{14,{0,true,100.04}}};
 uint64_t reported=0;pm::timeline::Presentations shown;shown.period=.01;
 collectMoviePresentations(10,5,reported,shown);assert(reported==1&&shown.shown==0&&!locked);
 records[11]={0,true,100.01};collectMoviePresentations(10,5,reported,shown);
 assert(reported==5&&shown.shown==3&&!locked);
 collectMoviePresentations(10,6,reported,shown);assert(reported==6&&shown.shown==3); // expired token
 collectMoviePresentations(10,6,reported,shown);assert(shown.shown==3); // idempotent
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'test.cpp';p.write_text(code);binary=Path(d)/'test'
 subprocess.run(['clang++','-std=c++17','-iquote',str(root),'-fsanitize=address,undefined',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
print('PASS: movie reporting waits for pending callbacks, advances past terminal/expired frames, retains later confirmations and never invents timestamps.')
