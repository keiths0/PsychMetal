#!/usr/bin/env python3
"""Compile the engine's actual pm::mouse() against stubbed CoreGraphics APIs.
No active display, MATLAB, Octave, or injected OS input is needed. This tests
coordinate conversion, button ordering/state, error cleanup and event release;
it does not substitute for a physical mouse check on macOS. (Argument and
output counts are the front ends' job: see test_frontends.py.)
"""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'PsychMetalEngine.mm').read_text()
start = source.index('pm::MouseState pm::mouse() {')
block = source[start:source.index('\n}\n', start) + 3]
preamble = r'''
#include "PsychMetalEngine.h"
#include <cassert>
#include <cmath>
#include <stdexcept>
#include <iostream>
struct CGPoint { double x,y; };
struct CGSize { double width,height; };
struct CGRect { CGPoint origin; CGSize size; };
using CGMouseButton=int;
constexpr int kCGMouseButtonLeft=0, kCGMouseButtonRight=1, kCGMouseButtonCenter=2;
constexpr int kCGEventSourceStateCombinedSessionState=0;
using CGEventRef=void*;
void* metalWindow=(void*)1;
unsigned selectedDisplayID=42, renderWidth=3420, renderHeight=2214;
CGRect bounds={{0,0},{1710,1107}};
CGPoint pointer={0,0}; bool state[3]={}; bool failCreate=false;
int created=0, released=0, polls=0;
[[noreturn]] void fail(const char* msg) { throw std::runtime_error(msg); }
CGRect CGDisplayBounds(unsigned d) { assert(d==selectedDisplayID); return bounds; }
CGEventRef CGEventCreate(void*) { if(failCreate) return nullptr; created++; return (void*)1; }
CGPoint CGEventGetLocation(CGEventRef e) { assert(e); return pointer; }
void CFRelease(CGEventRef e) { assert(e); released++; }
bool CGEventSourceButtonState(int session,CGMouseButton b) {
 assert(session==kCGEventSourceStateCombinedSessionState); assert(b>=0&&b<3); polls++; return state[b];
}
'''
postamble = r'''
void sample(double x,double y,int mask) {
 for(int i=0;i<3;i++) state[i]=(mask&(1<<i))!=0;
 pm::MouseState m=pm::mouse();
 assert(std::abs(m.x-x)<1e-10); assert(std::abs(m.y-y)<1e-10);
 for(int i=0;i<3;i++) assert(m.buttons[(size_t)i]==state[i]);
 assert(created==released);
}
void expectError() {
 bool threw=false;
 try { pm::mouse(); } catch(const std::runtime_error&) { threw=true; }
 assert(threw); assert(created==released);
}
int main() {
 // Retina render size is deliberately unlike physical panel resolution.
 pointer={855,553.5}; sample(1710,1107,0);
 // Poll fresh state each time, without dispatching ANY AppKit/UI event.
 for(int mask: {1,1,0,2,0,4,0,7,0}) sample(1710,1107,mask);
 bounds={{-1920,-1080},{1920,1080}}; renderWidth=2880; renderHeight=1620;
 pointer={-1920,-1080}; sample(0,0,0);
 pointer={-960,-540}; sample(1440,810,1);
 pointer={0,0}; sample(2880,1620,0);
 pointer={-1930,-1100}; sample(-15,-30,0); // no clamping
 bounds={{1920,0},{1280,1024}}; renderWidth=1280; renderHeight=1024;
 pointer={1930,20}; sample(10,20,2); // right-side display, 1x
 metalWindow=nullptr; expectError(); metalWindow=(void*)1;
 selectedDisplayID=0; expectError(); selectedDisplayID=42;
 renderWidth=0; expectError(); renderWidth=1280;
 bounds.size.width=0; expectError(); bounds.size.width=1280;
 failCreate=true; expectError();
 assert(polls==3*created);
 std::cout << "PASS: engine mouse(): button transitions/order, Retina/secondary coordinates, errors and event release.\n";
}
'''
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path/'test.cpp').write_text(preamble+block+postamble)
    subprocess.run(['clang++','-std=c++17','-Wall','-Wextra','-iquote',str(root),str(path/'test.cpp'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
