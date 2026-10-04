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

// What one source element becomes in the texture: clamped to 0..1, then stored
// as a half float.
inline double unit(double v) {
    if (!std::isfinite(v)) fail("Texture pixels must be finite.");
    return std::max(0.0, std::min(1.0, v));
}
// The same conversion for every possible byte, done once: uint8 images are the
// common case and the large ones, and a table lookup is several times faster
// than converting each element through a double.
const __fp16 *byteTable() {
    static __fp16 table[256];
    static bool ready = false;      // one caller thread at a time (engine boundary rule 5)
    if (!ready) {
        for (int i = 0; i < 256; i++) table[i] = (__fp16)unit(i * (1.0 / 255));
        ready = true;
    }
    return table;
}

// Visit every pixel in destination order; convert(source element, destination)
// stores one channel. RGB gains alpha 1.
template <class Convert> void pack(const Source &src, size_t h, size_t w, size_t channels,
                                   std::vector<__fp16> &out, Convert convert) {
    const size_t outChannels = channels == 1 ? 1 : 4;
    out.resize(h * w * outChannels);
    __fp16 *dest = out.data();
    auto pixel = [&](size_t y, size_t x) {
        const unsigned char *p = src.base + (ptrdiff_t)y * src.sy + (ptrdiff_t)x * src.sx;
        __fp16 *d = dest + (y * w + x) * outChannels;
        for (size_t c = 0; c < channels; c++) convert(p + (ptrdiff_t)c * src.sc, d[c]);
        if (channels == 3) d[3] = (__fp16)1;
    };
    // Row-major sources (x varies fastest in memory) are read in the order they
    // are written, and small images fit in cache either way.
    bool rowMajor = std::llabs((long long)src.sx) < std::llabs((long long)src.sy);
    if (h * w < 2048 * 1024 || rowMajor) {
        for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) pixel(y, x);
        return;
    }
    // A large column-major image is transposed in tiles, which bounds the source
    // and destination working sets.
    constexpr size_t tile = 32;
    for (size_t by = 0; by < h; by += tile) for (size_t bx = 0; bx < w; bx += tile) {
        size_t endY = std::min(h, by + tile), endX = std::min(w, bx + tile);
        for (size_t y = by; y < endY; y++) for (size_t x = bx; x < endX; x++) pixel(y, x);
    }
}
template <class T> void packFloats(const Source &src, size_t h, size_t w, size_t channels,
                                   std::vector<__fp16> &out) {
    pack(src, h, w, channels, out,
         [](const unsigned char *p, __fp16 &d) { d = (__fp16)unit((double)*(const T *)p); });
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
    uint32_t seed = (uint32_t)q.seed;
    unsigned char *base = (unsigned char *)out.data;
    const ptrdiff_t sc = out.ndim == 3 ? out.strides[2] : 0;
    auto at = [&](size_t y, size_t x, size_t c) -> double & {
        return *(double *)(base + (ptrdiff_t)y * out.strides[0] + (ptrdiff_t)x * out.strides[1] + (ptrdiff_t)c * sc);
    };
    for (size_t ix = 0; ix < W; ix++) {
        for (size_t iy = 0; iy < H; iy++) {
            uint32_t b = noiseBase(seed, (uint32_t)ix, (uint32_t)iy);
            if (q.colour) {
                for (uint32_t c = 0; c < 3; c++) {
                    double v = q.mean[c] + q.spread * noiseDeviate(b, c, q.normal);
                    at(iy, ix, c) = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
                }
            } else {
                double v = q.mean[0] + q.spread * noiseDeviate(b, 0, q.normal);
                at(iy, ix, 0) = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
            }
        }
    }
}

// ---- images --------------------------------------------------------------------

pm::internal::ImageShape pm::internal::packImage(const pm::ArrayView &image, std::vector<__fp16> &out) {
    if (image.type == pm::ScalarType::Other || image.ndim < 2 || image.ndim > 3)
        fail("Image must be dense real uint8, single, double, or logical HxWxC.");
    size_t h = image.shape[0], w = image.shape[1], c = image.ndim == 3 ? image.shape[2] : 1;
    if (!h || !w || h > 16384 || w > 16384 || !(c == 1 || c == 3 || c == 4))
        fail("Image dimensions must be 1..16384 and have 1, 3, or 4 channels.");
    Source src{(const unsigned char *)image.data, image.strides[0], image.strides[1],
               image.ndim == 3 ? image.strides[2] : 0};
    switch (image.type) {
        case pm::ScalarType::Float64: packFloats<double>(src, h, w, c, out); break;
        case pm::ScalarType::Float32: packFloats<float>(src, h, w, c, out); break;
        case pm::ScalarType::UInt8: {
            const __fp16 *table = byteTable();
            pack(src, h, w, c, out, [table](const unsigned char *p, __fp16 &d) { d = table[*p]; });
            break;
        }
        default: {   // Bool: 0 or 1
            const __fp16 *table = byteTable();
            pack(src, h, w, c, out, [table](const unsigned char *p, __fp16 &d) { d = table[*p ? 255 : 0]; });
            break;
        }
    }
    return {h, w, c};
}
