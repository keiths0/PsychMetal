// PsychMetalInternal.h — engine internals shared between PsychMetalEngine.mm
// and PsychMetalShared.cpp. Not part of the public boundary; front ends include
// PsychMetalEngine.h only.
// SPDX-License-Identifier: MIT
#ifndef PSYCHMETAL_INTERNAL_H
#define PSYCHMETAL_INTERNAL_H

#include "PsychMetalEngine.h"

#include <cstddef>
#include <cmath>
#include <vector>

namespace pm {
namespace internal {

// Select an actual reported mode; never invent a refresh rate for a variable mode.
// Prefer full backing resolution, then the current mode, then the faster fixed rate.
inline size_t selectDisplayMode(const std::vector<DisplayMode> &modes, size_t current,
                                double width, double height, double hz) {
    if (!std::isfinite(width) || !std::isfinite(height) || width<=0 || height<=0 ||
        width!=std::floor(width) || height!=std::floor(height) ||
        !std::isfinite(hz) || hz<0 || hz>1000)
        throw Error(kErrMode, "Mode dimensions must be positive integers; refreshHz must be 0..1000.");
    size_t best=modes.size();
    for (size_t i=0;i<modes.size();i++) {
        const auto &m=modes[i];
        if (m.pointWidth!=width || m.pointHeight!=height ||
            (hz>0 && (!(m.refreshHz>0) || std::fabs(m.refreshHz-hz)>0.01))) continue;
        if (best==modes.size()) { best=i; continue; }
        const auto &b=modes[best];
        double area=m.pixelWidth*m.pixelHeight, bestArea=b.pixelWidth*b.pixelHeight;
        if (area>bestArea || (area==bestArea &&
            ((i==current && best!=current) ||
             (best!=current && i!=current && m.refreshHz>b.refreshHz)))) best=i;
    }
    return best;
}

struct ImageShape { size_t height, width, channels; };

// Images are uploaded in one layout: row y, column x, channel c at
// (y * width + x) * outChannels + c, where outChannels is 1 for grey and 4
// otherwise (RGB gains an opaque alpha). Both functions validate the view and
// throw pm::Error.

// UInt8 and Bool images are stored as they are, in 8-bit normalised textures
// (R8Unorm, RGBA8Unorm): a byte v is the value v / 255, and true is 255.
inline bool isByteImage(const ArrayView &image) {
    return image.type == ScalarType::UInt8 || image.type == ScalarType::Bool;
}
// The image's bytes in upload layout. A uint8 image already in that layout is
// returned in place, with no copy; anything else is packed into `scratch`.
const uint8_t *packBytes(const ArrayView &image, std::vector<uint8_t> &scratch, ImageShape &shape);

// Float32 and Float64 images become half floats, clamped to 0..1. __fp16 is
// clang's half-precision storage type, which is what Metal's RGBA16Float and
// R16Float textures hold.
ImageShape packImage(const ArrayView &image, std::vector<__fp16> &out);

// ---- blending -------------------------------------------------------------------
// The colour of a shape or an image is not multiplied by its alpha. What an
// offscreen window holds is: each pixel is (colour x alpha, alpha), which is
// what drawing leaves in a target that began transparent, and the one form in
// which drawing the window somewhere gives what the draws made into it would
// have given there. So how a draw blends depends on its blend mode, on whether
// its source is an offscreen window and on whether its target is one.
//   result = source x sourceFactor + destination x destinationFactor,
// for colour and for alpha apart. The factors are numbered as MTLBlendFactor.
// The engine gives them to Metal, and the tests' scripted engine and GPU test
// use the same function.
enum BlendFactor { kBlendZero = 0, kBlendOne = 1, kBlendSourceAlpha = 4, kBlendOneMinusSourceAlpha = 5 };
struct Blend { bool enabled; BlendFactor sourceRGB, destinationRGB, sourceAlpha, destinationAlpha; };
// mode: 0 source-over; 1 additive, which keeps the destination's alpha; anything
// else copy, where the source replaces the destination, alpha included. Only a
// copy of a straight colour into an offscreen window needs anything of the
// blender: the colour is multiplied by its alpha, to be stored as that window
// stores colour.
constexpr Blend blendFor(int mode, bool premultipliedSource, bool premultipliedTarget) {
    return mode == 0 ? Blend{true, premultipliedSource ? kBlendOne : kBlendSourceAlpha, kBlendOneMinusSourceAlpha,
                             kBlendOne, kBlendOneMinusSourceAlpha}
         : mode == 1 ? Blend{true, premultipliedSource ? kBlendOne : kBlendSourceAlpha, kBlendOne, kBlendZero, kBlendOne}
         : premultipliedTarget && !premultipliedSource ? Blend{true, kBlendSourceAlpha, kBlendZero, kBlendOne, kBlendZero}
         : Blend{false, kBlendOne, kBlendZero, kBlendOne, kBlendZero};
}

}  // namespace internal
}  // namespace pm

#endif
