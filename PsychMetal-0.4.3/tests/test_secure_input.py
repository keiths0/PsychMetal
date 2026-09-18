from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalCore.mm').read_text();a=s.index('        if (cmd(prhs[0], "Keys"))');b=s.index('        if (cmd(prhs[0], "SetBackgroundColor"))',a);block=s[a:b]
assert 'CGSessionCopyCurrentDictionary' not in block
source=r'''
#include <algorithm>
#include <cassert>
#include <stdexcept>
#include <mutex>
std::mutex secureInputStateLock;
using mxLogical=bool;
struct mxArray { double scalar=0; bool keys[256]={}; };
mxArray *mxCreateLogicalMatrix(int,int){return new mxArray;}
bool *mxGetLogicals(mxArray*a){return a->keys;}
mxArray *mxCreateLogicalScalar(bool v){auto a=new mxArray;a->scalar=v;return a;}
mxArray *mxCreateDoubleScalar(double v){auto a=new mxArray;a->scalar=v;return a;}
bool cmd(const mxArray*,const char*){return true;}
[[noreturn]]void fail(const char*s){throw std::runtime_error(s);}
bool secure=false;int mainCalls=0,secureCalls=0;
void onMainSync(void (^fn)(void)){++mainCalls;fn();}
bool IsSecureEventInputEnabled(){++secureCalls;return secure;}
void readKeyboardState(bool*out,const bool*){for(int i=0;i<256;i++)out[i]=false;out[40]=!secure;}
double CACurrentMediaTime(){static double t=1;return t+=.000001;}
double keyScanMaxMs=0,secureQueryMaxMs=0,keyScanTotalMs=0,secureQueryTotalMs=0;unsigned keyReadCount=0;
void call(mxArray**plhs){int nrhs=1,nlhs=4;const mxArray*prhs[]={nullptr};
'''+block+r'''
}
int main(){
 for(bool active:{false,true,false}){secure=active;mxArray*o[4]={};call(o);
 assert(o[3]->scalar==(active?-1:0));assert(o[0]->scalar==!active);assert(o[2]->keys[40]==!active);
 for(auto p:o)delete p;
 }
 assert(mainCalls==0&&secureCalls==3&&keyReadCount==3);
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.mm').write_text(source)
 subprocess.run(['clang++','-std=c++17','-fblocks','-fsanitize=address,undefined',str(p/'test.mm'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: actual Keys dispatch detects secure input transitions without GUI dispatch, preserves state output, avoids owner dictionary.')
