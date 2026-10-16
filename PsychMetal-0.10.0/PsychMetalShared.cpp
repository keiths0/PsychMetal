// PsychMetalShared.cpp — the plain C++ parts of the engine: shared scalar
// conventions, CPU noise, image validation and packing, and what every front end
// would otherwise do for itself: recipes from named options, text layout, key
// names and simple sounds. Compiled into every
// front end, and into the tests, which run it without a Mac or a GPU.
// SPDX-License-Identifier: MIT
#include "PsychMetalInternal.h"

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iterator>
#include <mutex>
#include <random>

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
    if (!image.data || image.type == pm::ScalarType::Other || image.ndim < 2 || image.ndim > 3)
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
        T value;
        std::memcpy(&value, p, sizeof(value)); // buffer-protocol arrays need not be aligned
        double v = (double)value;
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

const void *pm::internal::packSingles(const pm::ArrayView &image, std::vector<float> &scratch, ImageShape &shape) {
    shape=checkImage(image);
    if(image.type!=pm::ScalarType::Float32 && image.type!=pm::ScalarType::Float64) fail("Direct float images must be single or double precision.");
    const auto src=sourceOf(image);const size_t c=shape.channels;
    if(image.type==pm::ScalarType::Float64) {
        pack(src,shape,scratch,1.f,[](const unsigned char *p,float &out) {
            double v;std::memcpy(&v,p,8);if(!std::isfinite(v))fail("Texture pixels must be finite.");
            out=(float)std::max(0.0,std::min(1.0,v));
        });return scratch.data();
    }
    bool direct=c!=3 && src.sx==(ptrdiff_t)(c*4) && src.sy==(ptrdiff_t)(shape.width*c*4) && (c==1||src.sc==4);
    if(direct) {
        for(size_t i=0;i<shape.height*shape.width*c;i++) {
            float value;std::memcpy(&value,src.base+i*4,4);
            if(!std::isfinite(value)) fail("Texture pixels must be finite.");
            if(value<0||value>1) { direct=false; break; } // packing validates the remaining pixels
        }
        if(direct) return src.base; // replaceRegion accepts unaligned source bytes
    }
    pack(src,shape,scratch,1.f,[](const unsigned char *p,float &out) {
        float value;std::memcpy(&value,p,4);
        if(!std::isfinite(value)) fail("Texture pixels must be finite.");
        out=std::max(0.f,std::min(1.f,value));
    });
    return scratch.data();
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

// ---- recipes from named options ---------------------------------------------------

namespace {
// Every option is one of `allowed`.
void only(const std::vector<pm::Option> &options, const char *const *allowed, size_t count, const std::string &what) {
    for (const pm::Option &o : options) {
        bool known = false;
        for (size_t i = 0; i < count; i++) known = known || o.name == allowed[i];
        if (!known) throw pm::Error(pm::kErrGeneral, "Unknown " + what + " option: " + o.name);
    }
}
double number(const pm::Option &o, size_t count = 1) {
    if (o.isText || o.numbers.size() != count)
        throw pm::Error(pm::kErrGeneral, "Invalid option: " + o.name + (count == 1 ? " must be one number." : " must be numbers."));
    return o.numbers[0];
}
pm::ArrayView viewOf(const double *p, size_t n) {
    pm::ArrayView v{};
    v.data = p; v.type = pm::ScalarType::Float64; v.ndim = 1; v.shape[0] = n; v.strides[0] = sizeof(double);
    return v;
}
std::array<double,15> applyStimulus(std::array<double,15> p, const std::vector<pm::Option> &options) {
    static const char *const names[] = {"mean", "contrast", "frequency", "orientation", "phase", "seed", "grain",
                                        "colour", "normal", "opacity", "aperture", "sigma"};
    only(options, names, 12, "stimulus");
    for (const pm::Option &o : options) {
        if (o.name == "mean") {
            if (o.isText || (o.numbers.size() != 1 && o.numbers.size() != 3))
                throw pm::Error(pm::kErrGeneral, "Invalid option: mean must be one number or three.");
            for (int c = 0; c < 3; c++) p[1 + c] = o.numbers[o.numbers.size() == 3 ? c : 0];
        } else if (o.name == "aperture") {
            static const char *const kinds[] = {"rect", "ellipse", "gaussian"};
            int k = -1;
            for (int i = 0; i < 3; i++) if (o.isText && o.text == kinds[i]) k = i;
            if (k < 0) throw pm::Error(pm::kErrGeneral, "Invalid option: aperture must be rect, ellipse or gaussian.");
            p[13] = k;
        } else {
            for (int i = 1; i < 12; i++)
                if (o.name == names[i]) p[i == 11 ? 14 : 3 + i] = number(o);
        }
    }
    return pm::checkStimulus(viewOf(p.data(), p.size()));
}
}  // namespace

std::array<double,15> pm::makeStimulus(const std::string &kind, const std::vector<pm::Option> &options) {
    if (kind != "grating" && kind != "noise") fail("kind must be grating or noise.");
    std::array<double,15> p = {kind == "noise" ? 1.0 : 0.0, .5, .5, .5, 1, .02, 0, 0, 1, 1, 0, 0, 1, 0, .35};
    return applyStimulus(p, options);
}

std::array<double,15> pm::stimulusWith(const pm::ArrayView &recipe, const std::vector<pm::Option> &options) {
    return applyStimulus(pm::checkStimulus(recipe), options);
}

std::array<double,8> pm::makeMask(const std::string &kind, const std::vector<pm::Option> &options) {
    static const char *const kinds[] = {"ellipse", "gaussian", "annulus", "raised_cosine"};
    int k = -1;
    for (int i = 0; i < 4; i++) if (kind == kinds[i]) k = i;
    if (k < 0) fail("Unknown mask kind; it is ellipse, gaussian, annulus or raised_cosine.");
    std::array<double,8> p = {(double)k, .35, k == 2 ? .5 : 0, 1, k == 2 ? .05 : k == 3 ? .1 : 0, 0, 0, 0};
    static const char *const ring[] = {"inner", "radius", "edge", "center", "invert"};
    static const char *const gauss[] = {"sigma", "center", "invert"};
    if (k == 1) only(options, gauss, 3, kind + " mask");
    else only(options, k == 2 ? ring : ring + 1, k == 2 ? 5 : 4, kind + " mask");
    for (const pm::Option &o : options) {
        if (o.name == "center") { number(o, 2); p[5] = o.numbers[0]; p[6] = o.numbers[1]; }
        else if (o.name == "sigma") p[1] = number(o);
        else if (o.name == "inner") p[2] = number(o);
        else if (o.name == "radius") p[3] = number(o);
        else if (o.name == "edge") p[4] = number(o);
        else if (o.name == "invert") p[7] = number(o);
    }
    return pm::checkMask(viewOf(p.data(), p.size()));
}

// ---- text layout --------------------------------------------------------------------

pm::TextLayout pm::internal::layoutText(const std::string &utf8, const std::string &font, double size, double wrap,
                                        pm::TextBounds (*measure)(const std::string &, const std::string &, double)) {
    struct Kept { std::string key; pm::TextLayout layout; };
    static std::deque<Kept> kept;
    static std::mutex guard;
    char numbers[64];
    snprintf(numbers, sizeof(numbers), "%.3f %.17g", size, wrap);
    const std::string key = font + '\n' + numbers + '\n' + utf8;
    {
        std::lock_guard<std::mutex> held(guard);
        for (const Kept &k : kept) if (k.key == key) return k.layout;
    }
    std::string text;
    for (size_t i = 0; i < utf8.size(); i++) {          // \r\n and \r are newlines too
        if (utf8[i] == '\r') { text += '\n'; if (i + 1 < utf8.size() && utf8[i + 1] == '\n') i++; }
        else text += utf8[i];
    }
    std::vector<std::string> paragraphs;
    for (size_t start = 0;;) {
        size_t end = text.find('\n', start);
        paragraphs.push_back(text.substr(start, end == std::string::npos ? std::string::npos : end - start));
        if (end == std::string::npos) break;
        start = end + 1;
    }
    pm::TextLayout out{};
    if (std::isfinite(wrap)) {
        // A space, without the margin of a pixel each measured piece has at either end.
        const double space = measure("x x", font, size).width - 2 * measure("x", font, size).width + 2;
        for (const std::string &paragraph : paragraphs) {
            std::string line;
            double width = 0;
            for (size_t start = 0; start <= paragraph.size();) {
                size_t end = paragraph.find(' ', start);
                if (end == std::string::npos) end = paragraph.size();
                const std::string word = paragraph.substr(start, end - start);
                start = end + 1;
                if (word.empty()) continue;
                const double w = measure(word, font, size).width - 2;
                if (!line.empty() && width + space + w > wrap - 2) { out.lines.push_back(line); line.clear(); width = 0; }
                if (line.empty()) { line = word; width = w; }
                else { line += ' ' + word; width += space + w; }
            }
            out.lines.push_back(line);
        }
    } else {
        out.lines = paragraphs;
    }
    out.ascent = NAN;
    for (const std::string &line : out.lines) {
        if (line.empty()) { out.sizes.push_back({0, 0}); continue; }
        const pm::TextBounds b = measure(line, font, size);
        out.sizes.push_back({b.width, b.height});
        if (std::isnan(out.ascent)) out.ascent = b.ascent;
    }
    if (std::isnan(out.ascent)) fail("The text must not be empty.");
    std::lock_guard<std::mutex> held(guard);
    kept.push_front({key, out});
    if (kept.size() > 16) kept.pop_back();
    return out;
}

// ---- key names ----------------------------------------------------------------------

const std::vector<pm::KeyName> &pm::keyNames() {
    static const std::vector<pm::KeyName> table = [] {
        static const char *const letters[] = {"a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r",
                                              "s","t","u","v","w","x","y","z"};
        static const char *const digits[] = {"1!","2@","3#","4$","5%","6^","7&","8*","9(","0)"};
        static const char *const functions[] = {"F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12",
                                                "F13","F14","F15","F16","F17","F18","F19","F20","F21","F22","F23","F24"};
        static const char *const keypad[] = {"Keypad1","Keypad2","Keypad3","Keypad4","Keypad5","Keypad6","Keypad7",
                                             "Keypad8","Keypad9"};
        std::vector<pm::KeyName> t;
        for (int k = 0; k < 26; k++) t.push_back({4 + k, letters[k]});
        for (int k = 0; k < 10; k++) t.push_back({30 + k, digits[k]});
        const pm::KeyName middle[] = {{40,"Return"},{41,"ESCAPE"},{42,"DELETE"},{43,"tab"},{44,"space"},{45,"-_"},
            {46,"=+"},{47,"[{"},{48,"]}"},{49,"\\|"},{51,";:"},{52,"'\""},{53,"`~"},{54,",<"},{55,".>"},{56,"/?"},
            {57,"CapsLock"}};
        t.insert(t.end(), std::begin(middle), std::end(middle));
        for (int k = 0; k < 12; k++) t.push_back({58 + k, functions[k]});
        const pm::KeyName navigation[] = {{70,"PrintScreen"},{71,"ScrollLock"},{72,"Pause"},{73,"Insert"},{74,"Home"},
            {75,"PageUp"},{76,"Delete"},{77,"End"},{78,"PageDown"},{79,"RightArrow"},{80,"LeftArrow"},
            {81,"DownArrow"},{82,"UpArrow"},{83,"NumLockClear"},{84,"Divide"},{85,"Multiply"},{86,"Subtract"},
            {87,"Add"},{88,"ENTER"}};
        t.insert(t.end(), std::begin(navigation), std::end(navigation));
        for (int k = 0; k < 9; k++) t.push_back({89 + k, keypad[k]});
        const pm::KeyName more[] = {{98,"Keypad0"},{99,"KeypadDecimal"},{100,"NonUSBackslash"},{101,"Application"},
            {103,"KeypadEqual"}};
        t.insert(t.end(), std::begin(more), std::end(more));
        for (int k = 12; k < 24; k++) t.push_back({92 + k, functions[k]});
        const pm::KeyName last[] = {{117,"Help"},{133,"KeypadComma"},{135,"International1"},{137,"International3"},
            {144,"Lang1"},{145,"Lang2"},{224,"LeftControl"},{225,"LeftShift"},{226,"LeftAlt"},{227,"LeftGUI"},
            {228,"RightControl"},{229,"RightShift"},{230,"RightAlt"},{231,"RightGUI"}};
        t.insert(t.end(), std::begin(last), std::end(last));
        return t;
    }();
    return table;
}

// ---- sounds -------------------------------------------------------------------------

namespace {
std::vector<double> &ramped(std::vector<double> &x, double rate, double ramp) {
    if (!(ramp >= 0) || !std::isfinite(ramp)) fail("The ramp must be a nonnegative number of seconds.");
    const size_t n = std::min((size_t)std::llround(ramp * rate), x.size() / 2);
    for (size_t i = 0; i < n; i++) {
        const double r = 0.5 - 0.5 * std::cos(M_PI * (double)i / (double)n);
        x[i] *= r;
        x[x.size() - 1 - i] *= r;
    }
    return x;
}
size_t samples(double seconds, double rate, const char *what) {
    if (!(rate > 0) || !std::isfinite(rate) || rate > 1e6) fail("The rate must be a positive number of samples per second.");
    if (!(seconds >= 0) || !std::isfinite(seconds) || seconds * rate > 1e9) failf("%s length must be 0 to 1e9 samples.", what);
    return (size_t)std::llround(seconds * rate);
}
}  // namespace

std::vector<double> pm::tone(double frequency, double seconds, double rate, double amplitude, double ramp) {
    const size_t n = samples(seconds, rate, "A tone's");
    if (n < 1) fail("A tone needs at least one sample.");
    if (!std::isfinite(frequency) || !std::isfinite(amplitude)) fail("Frequency and amplitude must be finite.");
    std::vector<double> x(n);
    for (size_t i = 0; i < n; i++) x[i] = amplitude * std::sin(2 * M_PI * frequency * (double)i / rate);
    return ramped(x, rate, ramp);
}

std::vector<double> pm::click(double rate, double seconds, double amplitude) {
    if (!std::isfinite(amplitude)) fail("The amplitude must be finite.");
    return std::vector<double>(std::max<size_t>(1, samples(seconds, rate, "A click's")), amplitude);
}

std::vector<double> pm::whiteNoise(double seconds, double rate, double amplitude, double seed, double ramp) {
    const size_t n = samples(seconds, rate, "A noise's");
    if (!std::isfinite(amplitude) || amplitude < 0) fail("Noise amplitude must be finite and nonnegative.");
    if (!std::isnan(seed) && (!(seed >= 0) || seed != std::floor(seed) || seed > 9007199254740992.0))
        fail("The seed must be a nonnegative integer, or NaN.");
    std::mt19937_64 engine(std::isnan(seed) ? std::random_device{}() : (uint64_t)seed);
    std::vector<double> x(n, 0.0);
    if (amplitude == 0) return ramped(x, rate, ramp);
    std::normal_distribution<double> deviate(0, 1);
    const double scale = amplitude / 3;
    for (double &v : x) v = std::max(-1.0, std::min(1.0, deviate(engine) * scale));
    return ramped(x, rate, ramp);
}
