"""Actual half-float HDR unpack preserves extended values and output strides."""
from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[1];s=(r/'PsychMetalEngine.mm').read_text()
a=s.index('void pm::getImageFloat(');body=s[a:s.index('\nvoid pm::getImage(',a)]
code=r'''
#include "PsychMetalEngine.h"
#include <cstring>
#include <cassert>
#include <stdexcept>
static int outputBits=16;static size_t capturePitch=64;
struct {void *contents;} captureBuffer;
static void readCapture(const pm::ImageRegion &){}
[[noreturn]] static void fail(const char*s){throw pm::Error(s);}
'''+body+r'''
int main(){alignas(8) unsigned char bytes[128]={};
 for(int y=0;y<2;y++)for(int x=0;x<2;x++)for(int c=0;c<4;c++){__fp16 h=(__fp16)(2+y*8+x*4+c);memcpy(bytes+y*64+x*8+c*2,&h,2);}
 captureBuffer.contents=bytes;
 float out[12]={};pm::MutableFloatView v;v.data=out;v.ndim=3;v.shape={2,2,3};v.strides={4,8,16};
 pm::getImageFloat({0,0,2,2,16},v);
 for(int y=0;y<2;y++)for(int x=0;x<2;x++)for(int c=0;c<3;c++)assert(out[y+x*2+c*4]==2+y*8+x*4+c);
 v.shape={1,1,3};v.strides={12,12,4};pm::getImageFloat({1,1,1,1,16},v);assert(out[0]==14&&out[2]==16);
 outputBits=8;bool rejected=false;try{pm::getImageFloat({0,0,1,1,8},v);}catch(...){rejected=true;}assert(rejected);
}
'''
with tempfile.TemporaryDirectory() as temp:
 p=Path(temp);(p/'hdr.cpp').write_text(code)
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined','-iquote',r,p/'hdr.cpp','-o',p/'hdr'],check=True)
 subprocess.run([p/'hdr'],check=True)
print('PASS: actual HDR float readback, extended values, padded rows, column-major strides, crops and mode refusal.')
