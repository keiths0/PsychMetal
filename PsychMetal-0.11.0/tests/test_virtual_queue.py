#!/usr/bin/env python3
"""Actual queue API wrappers with delayed CPU-only admission/presentation stubs."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalEngine.mm').read_text()
a=s.index('pm::QueueResult pm::queueFlip(')
b=s.index('\nuint64_t pm::queueCancel()',a)
body=s[a:b].replace('@autoreleasepool {','{')
source=r'''
#include "PsychMetalRecordingClock.h"
#include <cassert>
#include <vector>
namespace pm {
struct QueueResult {unsigned long token; double pending,capacity;};
struct QueuedFrame {unsigned long token;double requested,presented;int status;};
QueueResult queueFlip(double);
std::vector<QueuedFrame> queueResults(bool);
}
static pm::recording::Clock recordingClock;
static bool exportSession=false;
static double wall=100,delay=0,previous=0;
static bool failAdmission=false;
static std::vector<double> captured;
static double CACurrentMediaTime(){return wall;}
[[noreturn]] static void fail(const char *s){throw std::runtime_error(s); }
static pm::QueueResult queueFrame(double when){
 if(failAdmission)throw std::runtime_error("injected queue failure");
 assert(when>previous);previous=when;
 wall+=delay;captured.push_back(recordingClock.now(wall));
 return {captured.size(),1,6};
}
static std::vector<pm::QueuedFrame> queueResults(bool wait){if(wait)wall+=50;return {};}
''' + body + r'''
int main(){
 for(double d:{.001,.2,3.0}){
  wall=100;delay=d;previous=0;captured.clear();recordingClock.begin(wall,1/59.94);
  for(int i=0;i<60;i++)pm::queueFlip(101+i/59.94);
  for(int i=0;i<60;i++)assert(std::abs(captured[i]-captured[0]-i/59.94)<1e-8);
  const double before=recordingClock.now(wall);pm::queueResults(true);
  assert(std::abs(recordingClock.now(wall)-before)<1e-8);
  failAdmission=true;try{pm::queueFlip(110);}catch(const std::runtime_error&){}
  const double failed=recordingClock.now(wall);wall+=.1;
  assert(std::abs(recordingClock.now(wall)-failed-.1)<1e-8);
  failAdmission=false;recordingClock.end();
 }
}
'''
with tempfile.TemporaryDirectory(prefix='pm-virtual-queue-') as temp:
 path=Path(temp)/'queue.cpp';path.write_text(source)
 for sanitizer in ('address,undefined','thread'):
  binary=Path(temp)/sanitizer
  subprocess.run(['clang++','-std=c++17','-pthread','-iquote',str(root),'-fsanitize='+sanitizer,str(path),'-o',str(binary)],check=True)
  subprocess.run([str(binary)],check=True)
print('PASS: actual virtual queue wrappers retain exact cadence/order through slow admission, exclude result waits, and restore the clock after errors.')
