from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text()
def block(start):
    a=s.index(start);return s[a:s.index('\n}\n',a)+3]
probe=block('static bool secureInputActive() {');keys=block('pm::KeyState pm::keys() {')
# Only the documented Carbon call: no owner lookup in an undocumented session dictionary, no GUI dispatch.
for b in (probe,keys):
    assert 'CGSessionCopyCurrentDictionary' not in b and 'kCGSSessionSecureInputPID' not in b and 'onMainSync' not in b
assert 'CGSessionCopyCurrentDictionary' not in s and 'kCGSSessionSecureInputPID' not in s
source=r"""
#define PM_IOS 0
#include "PsychMetalEngine.h"
#include <cassert>
#include <mutex>
bool secure=false;int secureCalls=0;
bool IsSecureEventInputEnabled(){++secureCalls;return secure;}
void readKeyboardState(bool*out,const bool*){for(int i=0;i<256;i++)out[i]=false;out[40]=!secure;}
double CACurrentMediaTime(){static double t=1;return t+=.000001;}
"""+probe+keys+r"""
int main(){
 for(bool active:{false,true,false}){secure=active;pm::KeyState k=pm::keys();
 assert(k.securePid==(active?-1:0));assert(k.anyDown==!active);assert(k.down[40]==!active);
 }
 assert(secureCalls==3);
}
"""
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.cpp').write_text(source)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',str(root),str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: keys() reports secure input from the documented call alone, without GUI dispatch or an owner lookup.')
