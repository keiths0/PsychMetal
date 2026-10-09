// RGB readback conversion from a GPU-written, padded BGRA/BGR10A2 buffer.
// SPDX-License-Identifier: MIT
#ifndef PSYCHMETAL_READBACK_H
#define PSYCHMETAL_READBACK_H
#include "PsychMetalEngine.h"
#include <algorithm>
#include <cstring>
#if defined(__aarch64__) && !defined(PM_READBACK_SCALAR)
#include <arm_neon.h>
#endif
namespace pm { namespace internal {
inline void unpackReadback8(const uint8_t *src, size_t pitch, const MutableByteView &out) {
    const size_t H=out.shape[0], W=out.shape[1];
    if(out.strides[2]==1 && out.strides[1]==3) {
        for(size_t y=0;y<H;y++) {
            const uint8_t *s=src+y*pitch;
            uint8_t *d=out.data+(ptrdiff_t)y*out.strides[0]; size_t x=0;
#if defined(__aarch64__) && !defined(PM_READBACK_SCALAR)
            for(;x+16<=W;x+=16) {
                uint8x16x4_t bgra=vld4q_u8(s+x*4);
                uint8x16x3_t rgb={{bgra.val[2],bgra.val[1],bgra.val[0]}};
                vst3q_u8(d+x*3,rgb);
            }
#endif
            for(;x<W;x++) {d[x*3]=s[x*4+2];d[x*3+1]=s[x*4+1];d[x*3+2]=s[x*4];}
        }
        return;
    }
    // Tile the transpose into MATLAB's column-major planes. Both source and
    // destination working sets stay small; support arbitrary byte strides too.
    for(size_t by=0;by<H;by+=32) for(size_t bx=0;bx<W;bx+=32)
        for(size_t x=bx;x<std::min(W,bx+32);x++) for(size_t y=by;y<std::min(H,by+32);y++) {
            const uint8_t *s=src+y*pitch+x*4;
            uint8_t *d=out.data+(ptrdiff_t)y*out.strides[0]+(ptrdiff_t)x*out.strides[1];
            d[0]=s[2];d[out.strides[2]]=s[1];d[2*out.strides[2]]=s[0];
        }
}
inline void unpackReadback10(const uint8_t *src, size_t pitch, const MutableWordView &out) {
    const size_t H=out.shape[0], W=out.shape[1];
    auto *dest=reinterpret_cast<uint8_t *>(out.data);
    if(out.strides[2]==2 && out.strides[1]==6) {
        for(size_t y=0;y<H;y++) {
            const uint8_t *s=src+y*pitch;
            uint8_t *d=dest+(ptrdiff_t)y*out.strides[0];size_t x=0;
#if defined(__aarch64__) && !defined(PM_READBACK_SCALAR)
            // Host outputs have at least uint16 alignment, including row strides.
            if(reinterpret_cast<uintptr_t>(d)%2==0) for(;x+4<=W;x+=4) {
                uint32x4_t p;std::memcpy(&p,s+x*4,16);
                uint32x4_t mask=vdupq_n_u32(1023);
                uint16x4x3_t rgb={{vmovn_u32(vandq_u32(vshrq_n_u32(p,20),mask)),
                                  vmovn_u32(vandq_u32(vshrq_n_u32(p,10),mask)),
                                  vmovn_u32(vandq_u32(p,mask))}};
                vst3_u16(reinterpret_cast<uint16_t *>(d+x*6),rgb);
            }
#endif
            for(;x<W;x++) {
                uint32_t p;std::memcpy(&p,s+x*4,4);
                const uint16_t rgb[3]={(uint16_t)((p>>20)&1023),(uint16_t)((p>>10)&1023),(uint16_t)(p&1023)};
                std::memcpy(d+x*6,rgb,6);
            }
        }
        return;
    }
    for(size_t by=0;by<H;by+=32) for(size_t bx=0;bx<W;bx+=32)
        for(size_t x=bx;x<std::min(W,bx+32);x++) for(size_t y=by;y<std::min(H,by+32);y++) {
            uint32_t p;std::memcpy(&p,src+y*pitch+x*4,4);
            uint8_t *d=dest+(ptrdiff_t)y*out.strides[0]+(ptrdiff_t)x*out.strides[1];
            const uint16_t rgb[3]={(uint16_t)((p>>20)&1023),(uint16_t)((p>>10)&1023),(uint16_t)(p&1023)};
            for(int c=0;c<3;c++)std::memcpy(d+(ptrdiff_t)c*out.strides[2],rgb+c,2);
        }
}
}}
#endif
