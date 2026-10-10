// PsychMetalShared.cpp — the plain C++ parts of the engine: shared scalar
// conventions, CPU noise, and image validation and packing. Compiled into every
// front end, and into the tests, which run it without a Mac or a GPU.
// SPDX-License-Identifier: MIT
#include "PsychMetalInternal.h"

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

[[noreturn]] void fail(const char *s) { throw pm::Error(pm::kErrGeneral, s); }

[[noreturn]] void failf(const char *fmt, ...) {
    char text[160];
    va_list args;
    va_start(args, fmt);
    vsnprintf(text, sizeof(text), fmt, args);
    va_end(args);
    throw pm::Error(pm::kErrGeneral, text);
}

// ---- noise: identical arithmetic to the GPU noise shape (PsychMetalShaders.metal)
inline uint32_t pmHash(uint32_t v) {
    uint32_t s = v * 747796405u + 2891336453u;
    uint32_t w = ((s >> ((s >> 28) + 4)) ^ s) * 277803737u;
    return (w >> 22) ^ w;
}
inline float pmUnit(uint32_t k) {
    return (float)k * 2.3283064365386963e-10f;   // [0, 1)
}
inline float noiseDeviate(uint32_t base, uint32_t channel, bool normal) {
    uint32_t k = pmHash(base + channel * 0x9E3779B9u);
    if (!normal)
        return pmUnit(k) * 2.0f - 1.0f;
    float u1 = pmUnit(k) * 0.9999998f + 1.0e-7f;
    float u2 = pmUnit(pmHash(k + 1u));
    return sqrtf(-2.0f * logf(u1)) * cosf(6.28318530718f * u2);
}
inline uint32_t noiseBase(uint32_t seed, uint32_t ix, uint32_t iy) {
    return pmHash(pmHash(pmHash(seed) + ix) + iy);
}

// ---- image packing, reading through strides ----------------------------------
struct Source { const unsigned char *base; ptrdiff_t sy, sx, sc; };

pm::internal::ImageShape checkImage(const pm::ArrayView &image) {
    if (image.type == pm::ScalarType::Other || image.ndim < 2 || image.ndim > 3)
        fail("Image must be dense real uint8, single, double, or logical HxWxC.");
    size_t h = image.shape[0], w = image.shape[1], c = image.ndim == 3 ? image.shape[2] : 1;
    if (!h || !w || h > 16384 || w > 16384 || !(c == 1 || c == 3 || c == 4))
        fail("Image dimensions must be 1..16384 and have 1, 3, or 4 channels.");
    return {h, w, c};
}
Source sourceOf(const pm::ArrayView &image) {
    return {(const unsigned char *)image.data, image.strides[0], image.strides[1],
            image.ndim == 3 ? image.strides[2] : 0};
}

// Visit every pixel in destination order; convert(source element, destination)
// stores one channel. RGB gains the opaque alpha.
template <class Out, class Convert> void pack(const Source &src, const pm::internal::ImageShape &shape,
                                              std::vector<Out> &out, const Out &opaque, Convert convert) {
    const size_t h = shape.height, w = shape.width, channels = shape.channels;
    const size_t outChannels = channels == 1 ? 1 : 4;
    out.resize(h * w * outChannels);
    Out *dest = out.data();
    auto pixel = [&](size_t y, size_t x) {
        const unsigned char *p = src.base + (ptrdiff_t)y * src.sy + (ptrdiff_t)x * src.sx;
        Out *d = dest + (y * w + x) * outChannels;
        for (size_t c = 0; c < channels; c++) convert(p + (ptrdiff_t)c * src.sc, d[c]);
        if (channels == 3) d[3] = opaque;
    };
    // Row-major sources (x varies fastest in memory, as numpy's) are read in the
    // order they are written.
    bool rowMajor = std::llabs((long long)src.sx) < std::llabs((long long)src.sy);
    if (rowMajor) {
        for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) pixel(y, x);
        return;
    }
    // A column-major image (MATLAB's) is transposed in tiles, which bounds the
    // source and destination working sets: at any size, since a 1024 x 1024
    // colour image of doubles is already 24 MB.
    constexpr size_t tile = 32;
    for (size_t by = 0; by < h; by += tile) for (size_t bx = 0; bx < w; bx += tile) {
        size_t endY = std::min(h, by + tile), endX = std::min(w, bx + tile);
        for (size_t y = by; y < endY; y++) for (size_t x = bx; x < endX; x++) pixel(y, x);
    }
}
template <class T> void packFloats(const Source &src, const pm::internal::ImageShape &shape,
                                   std::vector<__fp16> &out) {
    const __fp16 one = (__fp16)1;
    pack(src, shape, out, one, [](const unsigned char *p, __fp16 &d) {
        double v = (double)*(const T *)p;
        if (!std::isfinite(v)) fail("Texture pixels must be finite.");
        d = (__fp16)std::max(0.0, std::min(1.0, v));
    });
}

}  // namespace

// ---- shared scalar conventions --------------------------------------------

void pm::failNotScalar(const char *name) {
    failf("%s must be a real numeric scalar.", name);
}

double pm::checkFinite(double v, const char *name) {
    if (!std::isfinite(v))
        failf("%s must be finite.", name);
    return v;
}

uint64_t pm::checkUnsigned(double v, const char *name, uint64_t maximum) {
    pm::checkFinite(v, name);
    if (v < 0 || std::floor(v) != v || v > (double)maximum)
        failf("%s must be a nonnegative integer in range.", name);
    return (uint64_t)v;
}

// ---- noise -------------------------------------------------------------------

void pm::checkNoiseRequest(const pm::NoiseRequest &q) {
    if (q.width < 1 || q.height < 1 || q.width > 16384 || q.height > 16384 ||
        q.width != std::floor(q.width) || q.height != std::floor(q.height))
        fail("Noise width and height must be positive integers.");
    if (q.seed < 0 || q.seed > 16777215.0 || q.seed != std::floor(q.seed))
        fail("Seed must be an integer from 0 to 16777215.");
    if (q.spread < 0 || !std::isfinite(q.mean[0]) || !std::isfinite(q.mean[1]) || !std::isfinite(q.mean[2]))
        fail("Invalid noise mean/spread.");
}

void pm::noiseValues(const pm::NoiseRequest &q, const pm::MutableArrayView &out) {
    pm::checkNoiseRequest(q);
    size_t W = (size_t)q.width, H = (size_t)q.height;
    if (!out.data || out.ndim != (q.colour ? 3 : 2) || out.shape[0] != H || out.shape[1] != W ||
        (q.colour && out.shape[2] != 3))
        fail("Noise output buffer does not match the request.");
    const uint32_t seed = (uint32_t)q.seed;
    const double spread = q.spread, mean[3] = {q.mean[0], q.mean[1], q.mean[2]};
    const bool normal = q.normal;
    const size_t channels = q.colour ? 3 : 1;
    const ptrdiff_t sc = q.colour ? out.strides[2] : 0;
    // A pixel's value depends only on the seed and where it is, so the order of
    // visiting is free: the inner loop runs along whichever of rows and columns
    // is closer together in the caller's memory (columns for MATLAB's layout,
    // rows for numpy's), so that the writes are sequential.
    const bool alongRows = std::abs(out.strides[1]) < std::abs(out.strides[0]);
    const size_t outerCount = alongRows ? H : W, innerCount = alongRows ? W : H;
    const ptrdiff_t outerStride = out.strides[alongRows ? 0 : 1], innerStride = out.strides[alongRows ? 1 : 0];
    for (size_t o = 0; o < outerCount; o++) {
        unsigned char *p = (unsigned char *)out.data + (ptrdiff_t)o * outerStride;
        for (size_t i = 0; i < innerCount; i++, p += innerStride) {
            const uint32_t b = alongRows ? noiseBase(seed, (uint32_t)i, (uint32_t)o) : noiseBase(seed, (uint32_t)o, (uint32_t)i);
            for (size_t c = 0; c < channels; c++) {
                double v = mean[c] + spread * noiseDeviate(b, (uint32_t)c, normal);
                *(double *)(p + (ptrdiff_t)c * sc) = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
            }
        }
    }
}

// ---- images --------------------------------------------------------------------

pm::internal::ImageShape pm::internal::packImage(const pm::ArrayView &image, std::vector<__fp16> &out) {
    ImageShape shape = checkImage(image);
    if (image.type == pm::ScalarType::Float64) packFloats<double>(sourceOf(image), shape, out);
    else if (image.type == pm::ScalarType::Float32) packFloats<float>(sourceOf(image), shape, out);
    else fail("Image must be dense real uint8, single, double, or logical HxWxC.");
    return shape;
}

const uint8_t *pm::internal::packBytes(const pm::ArrayView &image, std::vector<uint8_t> &scratch,
                                       ImageShape &shape) {
    shape = checkImage(image);
    const Source src = sourceOf(image);
    const ptrdiff_t c = (ptrdiff_t)shape.channels, w = (ptrdiff_t)shape.width;
    if (image.type == pm::ScalarType::UInt8) {
        // Grey or RGBA, rows one after another with no gaps: already what the texture holds.
        if (c != 3 && src.sx == c && src.sy == w * c && (c == 1 || src.sc == 1))
            return src.base;
        pack(src, shape, scratch, (uint8_t)255, [](const unsigned char *p, uint8_t &d) { d = *p; });
    } else if (image.type == pm::ScalarType::Bool) {
        pack(src, shape, scratch, (uint8_t)255, [](const unsigned char *p, uint8_t &d) { d = *p ? 255 : 0; });
    } else {
        fail("Image must be dense real uint8, single, double, or logical HxWxC.");
    }
    return scratch.data();
}

std::array<double,15> pm::checkStimulus(const pm::ArrayView &v) {
    if(v.type!=pm::ScalarType::Float64 || v.ndim!=1 || v.shape[0]!=15 || !v.data)
        fail("Stimulus parameters must be 15 real doubles.");
    std::array<double,15> p{};
    for(size_t i=0;i<15;i++) {
        // memcpy also handles unaligned buffer-protocol inputs.
        std::memcpy(&p[i], (const unsigned char*)v.data+(ptrdiff_t)i*v.strides[0], sizeof(double));
        if(!std::isfinite(p[i])) fail("Stimulus parameters must be finite.");
    }
    auto integer=[&](int i,double hi){if(p[i]<0 || p[i]>hi || p[i]!=floor(p[i])) fail("Invalid stimulus integer option.");};
    integer(0,1); integer(8,16777215); integer(10,1); integer(11,1); integer(13,2);
    for(int i: {1,2,3,4,12}) if(p[i]<0 || p[i]>1) fail("Stimulus mean, contrast and opacity must be 0..1.");
    if(p[5]<0 || p[5]>.5) fail("Stimulus frequency must be 0..0.5 cycles/pixel.");
    if(p[9]<1 || p[9]>16384) fail("Stimulus grain must be 1..16384 pixels.");
    if(p[14]<.001 || p[14]>10) fail("Stimulus sigma must be .001..10 half-aperture units.");
    p[6]=std::remainder(p[6],360.0); p[7]=std::remainder(p[7],360.0);
    return p;
}


std::array<double,8> pm::checkMask(const pm::ArrayView &v) {
    if(v.type!=pm::ScalarType::Float64 || v.ndim!=1 || v.shape[0]!=8 || !v.data)
        fail("Mask parameters must be 8 real doubles.");
    std::array<double,8> p{};
    for(size_t i=0;i<p.size();i++) {
        std::memcpy(&p[i],(const unsigned char*)v.data+(ptrdiff_t)i*v.strides[0],sizeof(double));
        if(!std::isfinite(p[i])) fail("Mask parameters must be finite.");
    }
    if(p[0]<0 || p[0]>3 || p[0]!=std::floor(p[0]) || (p[7]!=0 && p[7]!=1)) fail("Invalid mask kind or invert flag.");
    if(p[1]<.001 || p[1]>10) fail("Mask sigma must be .001..10 half-aperture units.");
    if(p[2]<0 || p[2]>=p[3] || p[3]>10) fail("Mask requires 0 <= inner < radius <= 10.");
    if(p[4]<0 || p[4]>p[3] || (p[0]==2 && 2*p[4]>p[3]-p[2]+1e-12) || (p[0]==3 && p[4]==0))
        fail("Mask edge must fit inside its radius or annulus width; raised cosine requires a positive edge.");
    if(std::fabs(p[5])>10 || std::fabs(p[6])>10) fail("Mask center must be within +/-10 half-aperture units.");
    return p;
}

std::array<double,16> pm::checkShaderParameters(const ArrayView &v) {
    if(v.type!=ScalarType::Float64 || v.ndim!=1 || v.shape[0]!=16 || !v.data)
        throw Error("Shader parameters must be sixteen real doubles.");
    std::array<double,16> result{};
    for(int i=0;i<16;i++) {
        memcpy(&result[i],(const char*)v.data+(ptrdiff_t)i*v.strides[0],8);
        if(!std::isfinite(result[i]) || std::fabs(result[i])>1e6)throw Error("Shader parameters must be finite and bounded to +/-1000000.");
    }
    return result;
}
