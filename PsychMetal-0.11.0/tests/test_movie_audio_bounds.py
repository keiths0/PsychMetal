"""Native decoded movie audio limits, including leading silence before allocation."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalMovie.h').read_text()
a=s.index('static size_t movieSoundLimit(')
helpers=s[a:s.index('\nstd::vector<float> pm::movieSound(',a)]
code=r'''
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cassert>
#include <stdexcept>
#include <limits>
[[noreturn]] void fail(const char *s) { throw std::runtime_error(s); }
'''+helpers+r'''
int main() {
 const size_t maximum=256u*1024u*1024u/sizeof(float);
 assert(movieSoundLimit(8000,1)==8000u*1800);
 assert(movieSoundLimit(48000,2)==maximum);
 assert(movieSoundLimit(1536000,2)==maximum);
 assert(movieLeadingSilence(-1,48000,2,maximum)==0);
 assert(movieLeadingSilence(.1,48000,2,maximum)==9600);
 assert(movieLeadingSilence(10.0/48000,48000,2,20)==20);
 for(double seconds : {1801.0,1e100,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}) {
  bool failed=false;
  try { (void)movieLeadingSilence(seconds,48000,2,maximum); } catch(const std::runtime_error &) { failed=true; }
  assert(failed);
 }
}
'''
with tempfile.TemporaryDirectory() as temp:
 source=Path(temp)/'audio.cpp';source.write_text(code);binary=Path(temp)/'audio'
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined',source,'-o',binary],check=True)
 subprocess.run([binary],check=True)
print('PASS: native movie audio duration/memory limits and leading-silence checks before allocation.')
