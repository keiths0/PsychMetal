#!/usr/bin/env python3
"""The engine's actual image packer and DrawTexture validation, without a GPU.

1. pm::internal::packImage and packBytes (PsychMetalShared.cpp, linked as is):
   grey, RGB, RGBA, clamping, NaN rejection, uint8 and logical bytes, and identical output for
   MATLAB column-major, numpy row-major, transposed, strided and reversed
   views, on both the linear path and the tiled path used for large
   column-major images.
2. pm::drawTextures (extracted from PsychMetalEngine.mm): each entry becomes
   the draw item it describes, read through MATLAB's 4xN layout; a queued draw
   keeps its texture snapshot; one bad entry anywhere in a batch queues nothing
   and leaves the mutex free.
"""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]

packing = r'''
#include "PsychMetalInternal.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
using pm::ArrayView; using pm::ScalarType;
template<class T> ArrayView view(const std::vector<T> &d, ScalarType t, size_t h, size_t w, size_t c,
                                 ptrdiff_t sy, ptrdiff_t sx, ptrdiff_t sc, ptrdiff_t offset = 0) {
    ArrayView v; v.data = d.data() + offset; v.type = t; v.ndim = c > 1 ? 3 : 2;
    v.shape = {h, w, c}; v.strides = {sy * (ptrdiff_t)sizeof(T), sx * (ptrdiff_t)sizeof(T), sc * (ptrdiff_t)sizeof(T)};
    return v;
}
bool rejects(const ArrayView &v) { std::vector<__fp16> o; try { pm::internal::packImage(v, o); } catch (const pm::Error &) { return true; } return false; }
int main() {
    std::vector<__fp16> out;
    // Column-major, as MATLAB passes them.
    std::vector<double> gray = {0, .25, .5, .75, 1, 2};
    auto s = pm::internal::packImage(view(gray, ScalarType::Float64, 2, 3, 1, 1, 2, 0), out);
    assert(s.height == 2 && s.width == 3 && s.channels == 1);
    double expected[] = {0, .5, 1, .25, .75, 1};
    for (int i = 0; i < 6; i++) assert(double(out[i]) == expected[i]);
    std::vector<double> rgb = {1, 0, 0, 1, 0, 0};
    pm::internal::packImage(view(rgb, ScalarType::Float64, 1, 2, 3, 1, 1, 2), out);
    double color[] = {1, 0, 0, 1, 0, 1, 0, 1};
    assert(out.size() == 8);
    for (int i = 0; i < 8; i++) assert(double(out[i]) == color[i]);
    std::vector<uint8_t> someBytes = {1, 2, 3};
    assert(rejects(view(someBytes, ScalarType::UInt8, 1, 3, 1, 1, 1, 0)));   // byte images go to packBytes
    std::vector<float> rgba = {.25, .5, .75, 1};
    pm::internal::packImage(view(rgba, ScalarType::Float32, 1, 1, 4, 1, 1, 1), out);
    for (int i = 0; i < 4; i++) assert(float(out[i]) == rgba[i]);
    std::vector<double> nan = {NAN};
    assert(rejects(view(nan, ScalarType::Float64, 1, 1, 1, 1, 1, 0)));
    assert(rejects(view(gray, ScalarType::Other, 2, 3, 1, 1, 2, 0)));
    assert(rejects(view(gray, ScalarType::Float64, 1, 3, 2, 1, 1, 3)));   // two channels
    // Every layout of the same logical image packs identically: small (linear
    // path) and large (tiled path, used for column-major images of 2048x1024+).
    for (size_t H : {3, 1100}) {
        size_t W = H == 3 ? 5 : 2000, C = 3;
        auto value = [&](size_t y, size_t x, size_t c) { return double((y * 7 + x * 3 + c * 11) % 256) / 255; };
        std::vector<double> colMajor(H * W * C), rowMajor(H * W * C), reversed(H * W * C);
        for (size_t y = 0; y < H; y++) for (size_t x = 0; x < W; x++) for (size_t c = 0; c < C; c++) {
            colMajor[y + x * H + c * H * W] = value(y, x, c);
            rowMajor[(y * W + x) * C + c] = value(y, x, c);
            reversed[((H - 1 - y) * W + (W - 1 - x)) * C + c] = value(y, x, c);
        }
        std::vector<__fp16> a, b, c2, d;
        pm::internal::packImage(view(colMajor, ScalarType::Float64, H, W, C, 1, H, H * W), a);
        pm::internal::packImage(view(rowMajor, ScalarType::Float64, H, W, C, W * C, C, 1), b);
        // (x, y, c) row-major array read as its transpose: y strides by C, x by H*C.
        std::vector<double> xyc(H * W * C);
        for (size_t y = 0; y < H; y++) for (size_t x = 0; x < W; x++) for (size_t c = 0; c < C; c++)
            xyc[(x * H + y) * C + c] = value(y, x, c);
        pm::internal::packImage(view(xyc, ScalarType::Float64, H, W, C, C, H * C, 1), c2);
        pm::internal::packImage(view(reversed, ScalarType::Float64, H, W, C, -(ptrdiff_t)(W * C), -(ptrdiff_t)C, 1,
                                     (ptrdiff_t)((H - 1) * W * C + (W - 1) * C)), d);
        assert(a.size() == H * W * 4 && a == b && a == c2 && a == d);
        for (size_t y = 0; y < H; y += H / 3 + 1) for (size_t x = 0; x < W; x += W / 4 + 1)
            for (size_t c = 0; c < 4; c++)
                assert(std::abs(double(a[(y * W + x) * 4 + c]) - (c < 3 ? value(y, x, c) : 1.0)) < 1e-3);
        if (H > 3) assert(H * W >= 2048 * 1024 / 1.05);
    }
    // A strided slice: every other row and column of a 6x10 row-major grey image.
    std::vector<double> big(6 * 10);
    for (size_t i = 0; i < big.size(); i++) big[i] = double(i) / 64;
    pm::internal::packImage(view(big, ScalarType::Float64, 3, 5, 1, 20, 2, 0), out);
    for (size_t y = 0; y < 3; y++) for (size_t x = 0; x < 5; x++)
        assert(std::abs(double(out[y * 5 + x]) - big[y * 20 + x * 2]) < 1e-3);
    printf("PASS: packImage grey/RGB/RGBA, clamping, NaN and type rejection; column-major, row-major, "
           "transposed, reversed and strided views pack identically on the linear and tiled paths.\n");

    // ---- packBytes: uint8 and logical images, stored as they are ----
    using pm::internal::ImageShape; using pm::internal::packBytes; using pm::internal::isByteImage;
    std::vector<uint8_t> scratch; ImageShape shape;
    assert(isByteImage(view(someBytes, ScalarType::UInt8, 1, 3, 1, 1, 1, 0)) && isByteImage(view(someBytes, ScalarType::Bool, 1, 3, 1, 1, 1, 0)));
    assert(!isByteImage(view(gray, ScalarType::Float64, 2, 3, 1, 1, 2, 0)));
    // RGB gains an opaque alpha; column-major (MATLAB) layout.
    std::vector<uint8_t> rgb8 = {255, 0, 0, 200, 7, 0};      // 1x2x3: pixel 0 = (255, 0, 7), pixel 1 = (0, 200, 0)
    const uint8_t *b = packBytes(view(rgb8, ScalarType::UInt8, 1, 2, 3, 1, 1, 2), scratch, shape);
    uint8_t want[] = {255, 0, 7, 255, 0, 200, 0, 255};
    assert(shape.height == 1 && shape.width == 2 && shape.channels == 3 && b == scratch.data());
    for (int i = 0; i < 8; i++) assert(b[i] == want[i]);
    // Logical: true is 255.
    std::vector<uint8_t> flags = {0, 1, 1, 0};
    b = packBytes(view(flags, ScalarType::Bool, 2, 2, 1, 2, 1, 0), scratch, shape);
    assert(b == scratch.data() && b[0] == 0 && b[1] == 255 && b[2] == 255 && b[3] == 0);
    // Already in upload layout: returned in place, nothing copied.
    std::vector<uint8_t> rgba8(3 * 5 * 4), grey8(3 * 5);
    for (size_t i = 0; i < rgba8.size(); i++) rgba8[i] = (uint8_t)(i * 13);
    for (size_t i = 0; i < grey8.size(); i++) grey8[i] = (uint8_t)(i * 17);
    assert(packBytes(view(rgba8, ScalarType::UInt8, 3, 5, 4, 20, 4, 1), scratch, shape) == rgba8.data());
    assert(packBytes(view(grey8, ScalarType::UInt8, 3, 5, 1, 5, 1, 0), scratch, shape) == grey8.data());
    // Not in upload layout: a strided grey slice, and row-major RGB, are packed.
    b = packBytes(view(grey8, ScalarType::UInt8, 2, 2, 1, 10, 2, 0), scratch, shape);
    assert(b == scratch.data() && b[0] == grey8[0] && b[1] == grey8[2] && b[2] == grey8[10] && b[3] == grey8[12]);
    // Every layout of one logical image packs identically, small and large (tiled).
    for (size_t H : {3, 1100}) {
        size_t W = H == 3 ? 5 : 2000;
        for (size_t C : {1, 3, 4}) {
            auto value = [&](size_t y, size_t x, size_t c) { return (uint8_t)((y * 7 + x * 3 + c * 11) % 256); };
            std::vector<uint8_t> colMajor(H * W * C), rowMajor(H * W * C);
            for (size_t y = 0; y < H; y++) for (size_t x = 0; x < W; x++) for (size_t c = 0; c < C; c++) {
                colMajor[y + x * H + c * H * W] = value(y, x, c);
                rowMajor[(y * W + x) * C + c] = value(y, x, c);
            }
            std::vector<uint8_t> sa, sb; ImageShape s1, s2;
            const uint8_t *pa = packBytes(view(colMajor, ScalarType::UInt8, H, W, C, 1, H, H * W), sa, s1);
            const uint8_t *pb = packBytes(view(rowMajor, ScalarType::UInt8, H, W, C, W * C, C, 1), sb, s2);
            size_t oc = C == 1 ? 1 : 4;
            assert((pb == rowMajor.data()) == (C != 3));
            for (size_t y = 0; y < H; y++) for (size_t x = 0; x < W; x++) for (size_t c = 0; c < oc; c++) {
                uint8_t expect = c < C ? value(y, x, c) : 255;
                assert(pa[(y * W + x) * oc + c] == expect && pb[(y * W + x) * oc + c] == expect);
            }
        }
    }
    std::vector<uint8_t> two = {1, 2, 3, 4};
    bool threw = false;
    try { packBytes(view(two, ScalarType::UInt8, 1, 2, 2, 1, 1, 2), scratch, shape); } catch (const pm::Error &) { threw = true; }
    assert(threw);                                              // two channels
    threw = false;
    try { packBytes(view(gray, ScalarType::Float64, 2, 3, 1, 1, 2, 0), scratch, shape); } catch (const pm::Error &) { threw = true; }
    assert(threw);                                              // float images go to packImage
    printf("PASS: packBytes uint8 and logical: RGB gains opaque alpha, true is 255, images already in upload layout "
           "are used in place, every other layout packs to the same bytes.\n");
}
'''

engine = (root / 'PsychMetalEngine.mm').read_text()
start = engine.index('void pm::drawTextures(')
draws = engine[start:engine.index('\n}\n', start) + 3]
start = engine.index('static inline double viewAt(')
view_at = engine[start:engine.index('\n}\n', start) + 3]
dispatch = r'''
#include "PsychMetalEngine.h"
#include <cassert>
#include <cfloat>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <cstring>
#include <string>
#include <pthread.h>
using std::isfinite;
[[noreturn]] void fail(const char* s){throw std::runtime_error(s);}
constexpr int PM_MAX_TEXTURES=256,PM_MAX_SHAPES=8192,PM_ITEM_TEXTURE=1;
int device=1; size_t drawCount=0;
struct Resource{int identity;};
std::shared_ptr<Resource> userTextures[256]={std::make_shared<Resource>(Resource{7}),std::make_shared<Resource>(Resource{8})};
std::shared_ptr<Resource> drawTextureRefs[8192];
struct PMDrawItem{int type,texIndex;float src[4],dst[4],tint[4],angle;int filterMode;unsigned blend;int mask;int clip[4];};
unsigned blendMode=0;int clipRect[4]={3,4,50,60};
std::shared_ptr<Resource> targetTexture;
PMDrawItem drawList[8192];pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
int textureSlot(uint64_t handle){if(handle==1)return 0;if(handle==2)return 1;fail("Invalid or expired texture handle.");}
''' + view_at + draws + r'''
int main(){
 // drawTextures: (N) and (N,4) views in MATLAB's 4xN column-major memory.
 using pm::ArrayView; using pm::ScalarType;
 auto row=[](const double*p,size_t n){ArrayView v;v.data=p;v.type=ScalarType::Float64;v.ndim=1;v.shape={n,0,0};v.strides={8,0,0};return v;};
 auto cols=[](const double*p,size_t n){ArrayView v;v.data=p;v.type=ScalarType::Float64;v.ndim=2;v.shape={n,4,0};v.strides={32,8,0};return v;};
 double h[3]={1,2,1}, ang[3]={0,0.5,-1}, fil[3]={0,1,1};
 double src[12]={0,0,1,1, 0,0,.5,.5, .25,0,.75,1};
 double dst[12]={0,0,10,10, 5,5,25,15, -3,4,8,40};
 double tin[12]={1,1,1,1, 1,0,0,.5, .2,.4,.6,.8};
 auto batch=[&](const double*hh,const double*aa,const double*ff,const double*tt){
  pm::drawTextures(row(hh,3),cols(src,3),cols(dst,3),row(aa,3),cols(tt,3),row(ff,3));};
 auto rejectBatch=[&](const double*hh,const double*aa,const double*ff,const double*tt,const char*message){
  size_t before=drawCount;std::string got;
  try{batch(hh,aa,ff,tt);}catch(const std::exception&e){got=e.what();}
  if(got!=message){std::cerr<<"expected '"<<message<<"', got '"<<got<<"'\n";std::abort();}
  assert(drawCount==before);assert(pthread_mutex_trylock(&lock)==0);pthread_mutex_unlock(&lock);};
 double badH[3]={1,2,3}, fracH[3]={1,1.5,1}, badA[3]={0,0,NAN}, badF[3]={0,1,2}, badT[12]={1,1,1,1, 1,1,1,1, 1,1,1,1.5};
 rejectBatch(badH,ang,fil,tin,"Invalid or expired texture handle.");
 rejectBatch(fracH,ang,fil,tin,"texture handle must be a nonnegative integer in range.");
 rejectBatch(h,badA,fil,tin,"Rotation angle out of range.");
 rejectBatch(h,ang,badF,tin,"filter mode must be a nonnegative integer in range.");
 rejectBatch(h,ang,fil,badT,"Invalid texture rectangle or tint.");
 { size_t before=drawCount; bool failed=false;
   try{pm::drawTextures(row(h,3),cols(src,2),cols(dst,3),row(ang,3),cols(tin,3),row(fil,3));}catch(...){failed=true;}
   assert(failed&&drawCount==before); }
 // A good batch queues one item per entry, as given, in order.
 drawCount=0; batch(h,ang,fil,tin); assert(drawCount==3);
 for(int k=0;k<3;k++){
  const PMDrawItem &it=drawList[k];
  assert(it.type==PM_ITEM_TEXTURE && it.texIndex==(int)h[k]-1 && it.angle==(float)ang[k] && it.filterMode==(int)fil[k]);
  assert(it.clip[0]==3 && it.clip[1]==4 && it.clip[2]==50 && it.clip[3]==60);
  for(int c=0;c<4;c++) assert(it.src[c]==(float)src[4*k+c] && it.dst[c]==(float)dst[4*k+c] && it.tint[c]==(float)tin[4*k+c]);
 }
 assert(drawTextureRefs[0]->identity==7 && drawTextureRefs[1]->identity==8 && drawTextureRefs[2]->identity==7);
 userTextures[0]=std::make_shared<Resource>(Resource{9}); assert(drawTextureRefs[0]->identity==7);
 // An offscreen window is never drawn into itself.
 targetTexture=userTextures[1]; drawCount=0; rejectBatch(h,ang,fil,tin,"An offscreen window cannot be drawn into itself."); targetTexture.reset();
 // Capacity: a batch that does not fit queues nothing.
 drawCount=8190; rejectBatch(h,ang,fil,tin,"Frame draw capacity exceeded; split the work across frames.");
 std::cout<<"PASS: engine drawTextures: one item per entry as given; queued draws keep their texture snapshot; a bad "
            "handle, angle, filter, tint, shape, capacity or the drawing target itself anywhere in a batch queues nothing and leaves the mutex free; each item carries the clip rect.\n";
}
'''
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'pack.cpp').write_text(packing)
    (tmp / 'draw.cpp').write_text(dispatch)
    flags = ['clang++', '-std=c++17', '-pthread', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
             '-O1', '-iquote', str(root)]
    subprocess.run(flags + [str(tmp / 'pack.cpp'), str(root / 'PsychMetalShared.cpp'), '-o', str(tmp / 'pack')], check=True)
    subprocess.run([str(tmp / 'pack')], check=True)
    subprocess.run(flags + [str(tmp / 'draw.cpp'), str(root / 'PsychMetalShared.cpp'), '-o', str(tmp / 'draw')], check=True)
    subprocess.run([str(tmp / 'draw')], check=True)
