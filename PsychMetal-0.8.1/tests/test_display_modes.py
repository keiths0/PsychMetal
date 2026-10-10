"""Run the actual mode-selection helper without needing a connected display."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=r'''
#include "PsychMetalInternal.h"
#include <cassert>
#include <limits>
int main() {
 using pm::DisplayMode; using pm::internal::selectDisplayMode;
 std::vector<DisplayMode> m={{1920,1080,1920,1080,60},
 {1920,1080,3840,2160,59.94},{1920,1080,3840,2160,60},
 {1920,1080,3840,2160,120},{1920,1080,3840,2160,0}};
 assert(selectDisplayMode(m,2,1920,1080,0)==2); // preserve current HiDPI refresh
 assert(selectDisplayMode(m,0,1920,1080,0)==3); // prefer full pixel backing, then faster
 assert(selectDisplayMode(m,4,1920,1080,0)==4); // preserve current variable-rate mode
 assert(selectDisplayMode(m,2,1920,1080,59.94)==1); // distinguish 59.94 and 60
 assert(selectDisplayMode(m,1,1920,1080,60)==2);
 assert(selectDisplayMode(m,2,1920,1080,90)==m.size()); // never substitute a wrong refresh
 assert(selectDisplayMode(m,2,1024,768,60)==m.size());
 for(double hz : {-1.,1001.,std::numeric_limits<double>::quiet_NaN()}) {
  bool rejected=false;try {selectDisplayMode(m,0,1920,1080,hz);}catch(const pm::Error &){rejected=true;}
  assert(rejected);
 }
 for(double w : {0.,-1.,1920.5,std::numeric_limits<double>::infinity()}) {
  bool rejected=false;try {selectDisplayMode(m,0,w,1080,60);}catch(const pm::Error &){rejected=true;}
  assert(rejected);
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp);(p/'test.cpp').write_text(source)
 subprocess.run(['clang++','-std=c++17','-Wall','-Wextra','-Werror','-iquote',str(root),str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('PASS: real mode selection preserves HiDPI/current refresh, distinguishes fractional rates, rejects unavailable and invalid modes.')
