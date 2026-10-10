#include "PsychMetalReadback.h"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <vector>
#include <array>
#include <cstdlib>
using namespace pm;
static void check(size_t H,size_t W,bool deep,ptrdiff_t sy,ptrdiff_t sx,ptrdiff_t sc) {
    size_t bytes=deep?2:1;
    size_t span=(H-1)*std::abs(sy)+(W-1)*std::abs(sx)+2*std::abs(sc)+bytes;
    ptrdiff_t offset=(sy<0?(H-1)*-sy:0)+(sx<0?(W-1)*-sx:0)+(sc<0?2*-sc:0);
    std::vector<uint8_t> got(span+32,0xa5),expected=got;
    size_t pitch=((W+9)*4+255)&~size_t(255);
    std::vector<uint8_t> source(pitch*(H+4),0xee);
    uint8_t *src=source.data()+pitch*2+12;
    for(size_t y=0;y<H;y++)for(size_t x=0;x<W;x++) {
        uint16_t rgb[3];for(int c=0;c<3;c++)rgb[c]=(y*117+x*23+c*59)&(deep?1023:255);
        if(deep){uint32_t p=(uint32_t(rgb[0])<<20)|(uint32_t(rgb[1])<<10)|rgb[2]|0xc0000000;std::memcpy(src+y*pitch+x*4,&p,4);}
        else {src[y*pitch+x*4]=rgb[2];src[y*pitch+x*4+1]=rgb[1];src[y*pitch+x*4+2]=rgb[0];src[y*pitch+x*4+3]=17;}
        for(int c=0;c<3;c++)std::memcpy(expected.data()+16+offset+(ptrdiff_t)y*sy+(ptrdiff_t)x*sx+c*sc,&rgb[c],bytes);
    }
    if(deep){MutableWordView v;v.data=(uint16_t*)(got.data()+16+offset);v.ndim=3;v.shape={H,W,3};v.strides={sy,sx,sc};internal::unpackReadback10(src,pitch,v);}
    else {MutableByteView v;v.data=got.data()+16+offset;v.ndim=3;v.shape={H,W,3};v.strides={sy,sx,sc};internal::unpackReadback8(src,pitch,v);}
    assert(got==expected);
}
__attribute__((noinline)) static void old8(const uint8_t *src,size_t pitch,const MutableByteView &o) {
    for(size_t y=0;y<o.shape[0];y++)for(size_t x=0;x<o.shape[1];x++) {
        const auto *s=src+y*pitch+x*4;auto *d=o.data+y*o.strides[0]+x*o.strides[1];
        d[0]=s[2];d[o.strides[2]]=s[1];d[2*o.strides[2]]=s[0];
    }
}
__attribute__((noinline)) static void new8(const uint8_t *s,size_t p,const MutableByteView &o){internal::unpackReadback8(s,p,o);}
int main(int argc,char**) {
    for(bool deep:{false,true})for(size_t W:{1,15,16,17,31,32,33,53})for(size_t H:{1,7,37}) {
        ptrdiff_t b=deep?2:1,w=W,h=H;
        for(auto v:std::vector<std::array<ptrdiff_t,3>>{{w*3*b,3*b,b},{b,h*b,h*w*b},{-w*3*b,3*b,b},{w*3*b,-3*b,b},{w*6*b,6*b,2*b},{2*b,2*h*b,2*h*w*b},{w*3*b,3*b,-b}})
            check(H,W,deep,v[0],v[1],v[2]);
    }
    puts("PASS: RGB8/RGB10 exact pixels, alpha ignored, padded GPU rows, crops, SIMD tails, MATLAB/Python, reversed/gapped layouts and untouched guards.");
    if(argc>1)for(auto dims:std::vector<std::array<size_t,2>>{{2622,1206},{3384,6016}})for(bool column:{false,true}) {
        size_t H=dims[0],W=dims[1],pitch=(W*4+255)&~size_t(255);
        std::vector<uint8_t> src(pitch*H,123),dst(H*W*3);
        MutableByteView o;o.data=dst.data();o.ndim=3;o.shape={H,W,3};
        o.strides=column?std::array<ptrdiff_t,3>{1,(ptrdiff_t)H,(ptrdiff_t)(H*W)}:std::array<ptrdiff_t,3>{(ptrdiff_t)(W*3),3,1};
        for(auto fn:{old8,new8}) {
            std::vector<double> ms;
            for(int i=0;i<10;i++){auto t=std::chrono::steady_clock::now();fn(src.data(),pitch,o);auto e=std::chrono::steady_clock::now();ms.push_back(std::chrono::duration<double,std::milli>(e-t).count());assert(dst.back()==123);}
            std::sort(ms.begin(),ms.end());printf("%zux%zu %s %s median %.3f ms\n",W,H,column?"MATLAB":"Python",fn==old8?"old":"new",ms[5]);
        }
    }
}
