// PsychMetalInternal.h — engine internals shared between PsychMetalEngine.mm
// and PsychMetalShared.cpp. Not part of the public boundary; front ends include
// PsychMetalEngine.h only.
// SPDX-License-Identifier: MIT
#ifndef PSYCHMETAL_INTERNAL_H
#define PSYCHMETAL_INTERNAL_H

#include "PsychMetalEngine.h"

#include <cstddef>
#include <vector>

namespace pm {
namespace internal {

struct ImageShape { size_t height, width, channels; };

// Validate an image view and convert it to half floats in upload order: row y,
// column x, channel c at (y * width + x) * outChannels + c, where outChannels
// is 1 for grey and 4 otherwise (RGB gains alpha 1). Values clamp to 0..1;
// UInt8 scales by 1/255. Throws pm::Error. __fp16 is
// clang's half-precision storage type, which is what Metal's RGBA16Float and
// R16Float textures hold.
ImageShape packImage(const ArrayView &image, std::vector<__fp16> &out);

}  // namespace internal
}  // namespace pm

#endif
