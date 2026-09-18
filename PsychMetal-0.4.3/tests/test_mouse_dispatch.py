#!/usr/bin/env python3
"""Compile the actual Mouse dispatch against stubbed CoreGraphics/MEX APIs.
No active display, MATLAB, Octave, or injected OS input is needed. This tests
coordinate conversion, button ordering/state, output shape and error cleanup;
it does not substitute for a physical mouse check on macOS.
"""
from pathlib import Path
import subprocess
import re
import tempfile
source = (Path(__file__).resolve().parents[1] / 'PsychMetalCore.mm').read_text()
start = source.index('        if (cmd(prhs[0], "Mouse")) {')
end = start + 1 + re.search(r'\n {8}if\s*\(', source[start + 1:]).start()
block = source[start:end]
preamble = r'''
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
using mxLogical=bool;
struct mxArray { double value=0; bool logical=false; int rows=1,cols=1; bool buttons[3]={}; };
using CGEventRef=void*;
void* metalWindow=(void*)1;
unsigned selectedDisplayID=42, renderWidth=3420, renderHeight=2214;
CGRect bounds={{0,0},{1710,1107}};
CGPoint pointer={0,0}; bool state[3]={}; bool failCreate=false;
int created=0, released=0, polls=0;
void fail(const char* msg) { throw std::runtime_error(msg); }
bool cmd(const mxArray*,const char*) { return true; }
CGRect CGDisplayBounds(unsigned d) { assert(d==selectedDisplayID); return bounds; }
CGEventRef CGEventCreate(void*) { if(failCreate) return nullptr; created++; return (void*)1; }
CGPoint CGEventGetLocation(CGEventRef e) { assert(e); return pointer; }
void CFRelease(CGEventRef e) { assert(e); released++; }
bool CGEventSourceButtonState(int session,CGMouseButton b) {
 assert(session==kCGEventSourceStateCombinedSessionState); assert(b>=0&&b<3); polls++; return state[b];
}
mxArray* mxCreateDoubleScalar(double x) { auto a=new mxArray; a->value=x; return a; }
mxArray* mxCreateLogicalMatrix(int r,int c) {
 auto a=new mxArray; a->logical=true; a->rows=r; a->cols=c; return a;
}
mxLogical* mxGetLogicals(mxArray* a) { return a->buttons; }
void dispatch(int nrhs,int nlhs,mxArray** plhs,const mxArray** prhs) {
'''
postamble = r'''
}
void sample(double x,double y,int mask) {
 for(int i=0;i<3;i++) state[i]=(mask&(1<<i))!=0;
 mxArray* out[3]={}; const mxArray* in[1]={};
 dispatch(1,3,out,in);
 assert(std::abs(out[0]->value-x)<1e-10); assert(std::abs(out[1]->value-y)<1e-10);
 assert(out[2]->logical && out[2]->rows==1 && out[2]->cols==3);
 for(int i=0;i<3;i++) assert(out[2]->buttons[i]==state[i]);
 for(auto a:out) delete a;
 assert(created==released);
}
void expectError(int nrhs,int nlhs) {
 mxArray* out[3]={}; const mxArray* in[1]={}; bool threw=false;
 try { dispatch(nrhs,nlhs,out,in); } catch(const std::runtime_error&) { threw=true; }
 assert(threw); assert(!out[0]&&!out[1]&&!out[2]); assert(created==released);
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
 expectError(2,3); expectError(1,2);
 metalWindow=nullptr; expectError(1,3); metalWindow=(void*)1;
 selectedDisplayID=0; expectError(1,3); selectedDisplayID=42;
 renderWidth=0; expectError(1,3); renderWidth=1280;
 bounds.size.width=0; expectError(1,3); bounds.size.width=1280;
 failCreate=true; expectError(1,3);
 assert(polls==3*created);
 std::cout << "PASS: actual Mouse dispatch, button transitions/order, logical shape, Retina/secondary coordinates, errors and event release.\n";
}
'''
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path/'test.cpp').write_text(preamble+block+postamble)
    subprocess.run(['clang++','-std=c++17','-Wall','-Wextra',str(path/'test.cpp'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
