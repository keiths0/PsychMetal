from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text();a=s.index('pm::KeyState pm::keys() {');b=s.index('\n}\n',a)+3;block=s[a:b]
assert 'CGSessionCopyCurrentDictionary' not in block and 'onMainSync' not in block
source=r'''
#include "PsychMetalEngine.h"
#include <algorithm>
#include <cassert>
#include <stdexcept>
#include <mutex>
std::mutex secureInputStateLock;
[[noreturn]]void fail(const char*s){throw std::runtime_error(s);}
bool secure=false;int secureCalls=0;
bool IsSecureEventInputEnabled(){++secureCalls;return secure;}
void readKeyboardState(bool*out,const bool*){for(int i=0;i<256;i++)out[i]=false;out[40]=!secure;}
double CACurrentMediaTime(){static double t=1;return t+=.000001;}
double keyScanMaxMs=0,secureQueryMaxMs=0,keyScanTotalMs=0,secureQueryTotalMs=0;unsigned keyReadCount=0;
'''+block+r'''
int main(){
 for(bool active:{false,true,false}){secure=active;pm::KeyState k=pm::keys();
 assert(k.securePid==(active?-1:0));assert(k.anyDown==!active);assert(k.down[40]==!active);
 }
 assert(secureCalls==3&&keyReadCount==3);
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(source)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',str(root),str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: engine keys() detects secure input transitions without GUI dispatch, preserves state output, avoids owner dictionary.')
