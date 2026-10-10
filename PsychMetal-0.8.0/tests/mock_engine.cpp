// mock_engine.cpp — a scripted implementation of PsychMetalEngine.h for testing
// the MATLAB/Octave and Python front ends without a Mac or a GPU.
// SPDX-License-Identifier: MIT
//
// Linked with the real PsychMetalShared.cpp (scalar conventions, image packing,
// noise) and the real PMKeyboardQueue. Everything that needs Metal or AppKit is
// simulated: one display, textures kept as packed half floats, and a vsync grid
// on the real monotonic clock, so Flip really waits for the next refresh.
//
// Environment (read at openSession / setMode):
//   PM_MOCK_DISPLAY  "WIDTHxHEIGHT@HZ"   default 800x600@60
//   PM_MOCK_DROP     "N"                every Nth stimulus frame is reported as dropped
//                    (submitted, never shown). Default 0: none.
//   PM_MOCK_MOUSE    "CLICK_AFTER,DX,DY" the mouse moves (DX, DY) per Mouse call
//                    and the left button is down once CLICK_AFTER frames have
//                    been flipped (-1: never). Default -1,0,0. At that frame a
//                    finger also touches the screen there, moves and lifts.
// Readback (OpenOptions::readback): a small software renderer stands in for the
// GPU, so GetImage returns real pixels and the readback checks run here too.
// It draws what those checks use and nothing else: the background, FillRect,
// unrotated textures with nearest sampling and polygons without antialiasing,
// blended source-over, additively or copied as the engine's pipelines are
// configured, inside the clip rect, into the window or an offscreen window.
// Frames queued ahead are rendered when queued and given the presentation times
// a display on schedule would report; there is no presenter thread here. Without linearization
// every draw is rounded to the frame's 8 or 10 bits, as a GPU drawing into the
// drawable rounds it; with it, draws accumulate unrounded and the frame is
// encoded and rounded once. Text is a block per character (see DrawText below).
// Other shapes, rotated textures and bilinear filtering leave the frame untouched.
//   PM_MOCK_LINK     "LANES,GBPS"        the link LinkInfo reports. Default: unknown.
//   PM_MOCK_KEYS     "USAGE:FROM-TO,..." HID usage USAGE reads as down in Keys while FROM <=
//                    frames flipped since open < TO. Read at each Keys. Default: no keys.
// Test-only readbacks through diagnostic(): lastShapeRect holds the packed
// RGBA of texel (row 1, column 0) of the last uploaded image, lastShapeColor
// that of (row 0, column 1), so a transposed upload is visible to the tests.
#include "PsychMetalEngine.h"
#include "PsychMetalTimeline.h"
#include "PsychMetalLiveTimeline.h"
#include "PsychMetalKeyframes.h"
#include <atomic>
#include "PsychMetalInternal.h"
#include "PsychMetalKeyboardQueue.h"

#include <cstring>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <map>
#include <memory>
#include <set>
#include <vector>
#include <thread>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif

namespace {

[[noreturn]] void fail(const char *s) { throw pm::Error(pm::kErrGeneral, s); }
[[noreturn]] void failWith(const char *id, const char *fmt, ...) {
    char text[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(text, sizeof(text), fmt, args);
    va_end(args);
    throw pm::Error(id, text);
}

pm::HostHooks hooks;

double clockNow() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

struct Display { double w = 800, h = 600, hz = 60; } display;
void readDisplay() {
    display = Display{};
    if (const char *e = getenv("PM_MOCK_DISPLAY")) {
        double w, h, hz = 60;
        int n = sscanf(e, "%lfx%lf@%lf", &w, &h, &hz);
        if (n >= 2) { display.w = w; display.h = h; display.hz = hz; }
    }
}

bool prepared = false, open = false, closing = true, pinned = false;
bool prefetch = false, displaySync = true, waitConfirm = true;
double bg[4] = {0, 0, 0, 1};
uint64_t nextToken = 1, session = 0, nextHandle = 1, preparedToken = 0;
size_t drawCount = 0;
double ifi = 1.0 / 60, gridTime = NAN;
uint64_t gridSamples = 0, confirmed = 0, shapesAppended = 0, shapesEncoded = 0, texturesDrawn = 0, texturesMade = 0;
std::vector<pm::StartupRecord> startup;
std::vector<pm::FrameRecord> history;
struct Texture { pm::internal::ImageShape shape; std::vector<__fp16> texels; bool bytes = false; bool offscreen = false; };
std::map<uint64_t, Texture> textures;
std::vector<__fp16> scratch;
// The renderer here works in half floats, so a byte image is widened: v becomes v / 255.
pm::internal::ImageShape packTexels(const pm::ArrayView &image, std::vector<__fp16> &texels) {
    if (!pm::internal::isByteImage(image)) return pm::internal::packImage(image, texels);
    pm::internal::ImageShape shape;
    std::vector<uint8_t> bytes;
    const uint8_t *b = pm::internal::packBytes(image, bytes, shape);
    size_t n = shape.height * shape.width * (shape.channels == 1 ? 1 : 4);
    texels.resize(n);
    for (size_t i = 0; i < n; i++) texels[i] = (__fp16)(b[i] / 255.0);
    return shape;
}
pm::Rect4 probeA{}, probeB{};

// Readback.
struct DrawItem {
    bool procedural = false;
    std::array<double,15> stimulus{};
    bool texture = false;
    int blend = 0;                            // 0 source-over, 1 additive, 2 copy
    int clip[4] = {};                         // [left top right bottom]; all zero: none
    double rect[4] = {}, color[4] = {};       // FillRect and polygons: pixels, RGBA 0..1
    std::shared_ptr<Texture> image;           // texture: a snapshot taken when queued
    double src[4] = {}, dst[4] = {}, tint[4] = {};
    std::vector<double> polygon;              // x, y pairs; rect is then its bounds
    double pen = 0;                           // polygon: 0 filled, else the outline's width
};
bool readable = false, haveFrame = false;
std::vector<DrawItem> drawItems;
std::vector<double> canvas;                   // RGBA 0..1, row-major, while a frame is drawn
std::vector<uint16_t> frame;                  // RGBA in the frame's levels, row-major
uint64_t frameToken = 0;
int bits = 8, blendNow = 0, clipNow[4] = {};
// The offscreen window drawn into (0: the window), and where its waiting draws begin.
uint64_t targetHandle = 0;
size_t targetItemBase = 0, targetCountBase = 0;
std::set<uint64_t> windowDrew;             // offscreen windows the window has draws of waiting
void stamp(DrawItem &it) { it.blend = blendNow; for (int i = 0; i < 4; i++) it.clip[i] = clipNow[i]; }
int gammaMode = 0;                            // 0 off, 1 power, 2 table
double exponent[3] = {1, 1, 1};
std::vector<double> gammaTable;               // N x 3, as the half floats a GPU would hold

double levels() { return bits == 10 ? 1023.0 : 255.0; }
double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
double rounded(double v) { return std::nearbyint(clamp01(v) * levels()) / levels(); }

// The display value of a linear one, as the engine's last pass computes it.
double encoded(double v, int c) {
    v = clamp01(v);
    if (gammaMode == 1) return std::pow(v, exponent[c]);
    if (gammaMode == 2) {
        size_t n = gammaTable.size() / 3;
        double at = v * (double)(n - 1);
        size_t lo = (size_t)std::floor(at), hi = lo + 1 < n ? lo + 1 : n - 1;
        double f = at - (double)lo;
        return gammaTable[lo * 3 + (size_t)c] * (1 - f) + gammaTable[hi * 3 + (size_t)c] * f;
    }
    return v;
}

// One pixel of a surface, blended by the factors the engine gives the GPU.
// `exact` surfaces (half-float targets) keep what is drawn; the others round
// every draw to the frame's levels, as a drawable does.
void blendPixel(double *p, const double rgba[4], const pm::internal::Blend &blend, bool exact) {
    const double a = clamp01(rgba[3]);
    auto factor = [a](pm::internal::BlendFactor f) {
        return f == pm::internal::kBlendZero ? 0.0 : f == pm::internal::kBlendOne ? 1.0
             : f == pm::internal::kBlendSourceAlpha ? a : 1.0 - a;
    };
    for (int c = 0; c < 4; c++) {
        double v = c < 3 ? rgba[c] * factor(blend.sourceRGB) + p[c] * factor(blend.destinationRGB)
                         : rgba[3] * factor(blend.sourceAlpha) + p[3] * factor(blend.destinationAlpha);
        p[c] = exact ? v : rounded(v);
    }
}

// Is the centre of pixel (x, y) inside the polygon (even-odd), or within half the
// pen of its outline?
bool polygonCovers(const DrawItem &it, double px, double py) {
    size_t n = it.polygon.size() / 2;
    if (it.pen > 0) {
        for (size_t i = 0; i < n; i++) {
            double ax = it.polygon[2 * i], ay = it.polygon[2 * i + 1];
            double bx = it.polygon[2 * ((i + 1) % n)], by = it.polygon[2 * ((i + 1) % n) + 1];
            double ux = bx - ax, uy = by - ay, len2 = ux * ux + uy * uy;
            double t = len2 > 0 ? ((px - ax) * ux + (py - ay) * uy) / len2 : 0;
            t = t < 0 ? 0 : t > 1 ? 1 : t;
            double ex = px - (ax + t * ux), ey = py - (ay + t * uy);
            if (ex * ex + ey * ey <= it.pen * it.pen / 4) return true;
        }
        return false;
    }
    bool inside = false;
    for (size_t i = 0, j = n - 1; i < n; j = i++) {
        double xi = it.polygon[2 * i], yi = it.polygon[2 * i + 1], xj = it.polygon[2 * j], yj = it.polygon[2 * j + 1];
        if ((yi > py) != (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
}

// Draw items [first, last) onto a W x H surface of RGBA doubles: the window's
// frame, or an offscreen window (`offscreen`), which holds colour x alpha.
void drawOnto(std::vector<double> &surface, size_t W, size_t H, size_t first, size_t last, bool exact, bool offscreen) {
    for (size_t k = first; k < last; k++) {
        const DrawItem &it = drawItems[k];
        const double *r = it.texture ? it.dst : it.rect;
        long x0 = std::lrint(std::ceil(r[0] - 0.5)), x1 = std::lrint(std::ceil(r[2] - 0.5));
        long y0 = std::lrint(std::ceil(r[1] - 0.5)), y1 = std::lrint(std::ceil(r[3] - 0.5));
        long cx0 = 0, cy0 = 0, cx1 = (long)W, cy1 = (long)H;
        if (it.clip[2] > it.clip[0] && it.clip[3] > it.clip[1]) {
            cx0 = std::max<long>(cx0, it.clip[0]); cy0 = std::max<long>(cy0, it.clip[1]);
            cx1 = std::min<long>(cx1, it.clip[2]); cy1 = std::min<long>(cy1, it.clip[3]);
        }
        for (long y = std::max(y0, cy0); y < y1 && y < cy1; y++)
            for (long x = std::max(x0, cx0); x < x1 && x < cx1; x++) {
                double rgba[4];
                if (!it.polygon.empty()) {
                    if (!polygonCovers(it, x + 0.5, y + 0.5)) continue;
                    for (int c = 0; c < 4; c++) rgba[c] = it.color[c];
                } else if (!it.texture) {
                    for (int c = 0; c < 4; c++) rgba[c] = it.color[c];
                } else {
                    const Texture &t = *it.image;
                    double u = it.src[0] + (x + 0.5 - r[0]) / (r[2] - r[0]) * (it.src[2] - it.src[0]);
                    double v = it.src[1] + (y + 0.5 - r[1]) / (r[3] - r[1]) * (it.src[3] - it.src[1]);
                    long tx = (long)std::floor(u * (double)t.shape.width), ty = (long)std::floor(v * (double)t.shape.height);
                    tx = tx < 0 ? 0 : tx >= (long)t.shape.width ? (long)t.shape.width - 1 : tx;
                    ty = ty < 0 ? 0 : ty >= (long)t.shape.height ? (long)t.shape.height - 1 : ty;
                    size_t oc = t.shape.channels == 1 ? 1 : 4;
                    const __fp16 *texel = &t.texels[((size_t)ty * t.shape.width + (size_t)tx) * oc];
                    for (int c = 0; c < 4; c++)
                        rgba[c] = (oc == 1 ? (c < 3 ? (double)texel[0] : 1.0) : (double)texel[c]) * it.tint[c];
                    // As the shader: the tint's alpha scales all of an offscreen window's colour.
                    if (t.offscreen) for (int c = 0; c < 3; c++) rgba[c] *= it.tint[3];
                }
                blendPixel(&surface[((size_t)y * W + (size_t)x) * 4], rgba,
                           pm::internal::blendFor(it.blend, it.texture && it.image->offscreen, offscreen), exact);
            }
    }
}

// The window's frame: everything queued, which is the window's own draws once an
// offscreen target's have been rendered.
void renderFrame(uint64_t token) {
    size_t W = (size_t)display.w, H = (size_t)display.h;
    canvas.resize(W * H * 4);
    for (size_t i = 0; i < W * H; i++)
        for (int c = 0; c < 4; c++) canvas[i * 4 + (size_t)c] = gammaMode ? bg[c] : rounded(bg[c]);
    drawOnto(canvas, W, H, 0, drawItems.size(), gammaMode != 0, false);
    frame.resize(W * H * 4);
    for (size_t i = 0; i < W * H; i++)
        for (int c = 0; c < 4; c++) {
            double v = canvas[i * 4 + (size_t)c];
            if (gammaMode) v = c < 3 ? encoded(v, c) : 1.0;
            frame[i * 4 + (size_t)c] = (uint16_t)std::lrint(clamp01(v) * levels());
        }
    haveFrame = true;
    frameToken = token;
}

// Render the offscreen target's waiting draws into it and forget them.
void flushTarget() {
    if (!targetHandle) return;
    shapesEncoded += drawCount - targetCountBase;
    drawCount = targetCountBase;
    if (drawItems.size() > targetItemBase) {
        Texture &t = textures[targetHandle];
        std::vector<double> surface(t.texels.begin(), t.texels.end());
        drawOnto(surface, t.shape.width, t.shape.height, targetItemBase, drawItems.size(), true, true);
        for (size_t i = 0; i < surface.size(); i++) t.texels[i] = (__fp16)surface[i];
        drawItems.resize(targetItemBase);
    }
}

int clickAfter = -1; double dx = 0, dy = 0, mouseX = 0, mouseY = 0; uint64_t flips = 0;
int dropEvery = 0; bool lastDropped = false; uint64_t missing = 0, lastFlipToken = 0;

void readKeys(bool *kv, const bool *) { std::memset(kv, 0, 256); }
double keyClock() { return clockNow(); }
PMKeyboardQueue keyboard(readKeys, keyClock);
bool keyboardPinned = false;

void requireOpen() { if (!open || closing) fail("PsychMetal is not open."); }

// Frames queued ahead: each is given the time a display on schedule would show it.
struct Queued { uint64_t token; double when, planned; int status; bool reported; };
std::vector<Queued> queued;
double lastPlanned = 0;
double queueCapacity() {
    double n = std::floor(1073741824.0 / (display.w * display.h * 4));
    return n < 2 ? 2 : n > 64 ? 64 : n;
}
// Mouse-button events, once MouseEvents has been called.
bool mouseListening = false;
std::vector<pm::MouseEvent> mouseEventList;
// A scripted touch: with the scripted click, a finger goes down where the mouse
// is, moves ten pixels to the right over the next refresh, and lifts.
std::vector<pm::TouchEvent> touchEventList;

uint64_t present(double when) {
    double now = clockNow();
    double target = when > now ? when : now;
    double next = std::isfinite(gridTime) ? gridTime + std::ceil((target - gridTime) / ifi - 1e-9) * ifi : target;
    if (next <= now) next += ifi;
    while (clockNow() < next) std::this_thread::sleep_for(std::chrono::microseconds(200));
    gridTime = next;
    gridSamples++;
    confirmed++;
    flushTarget();
    shapesEncoded += drawCount;
    drawCount = 0;
    uint64_t t = nextToken++;
    if (readable) renderFrame(t);
    drawItems.clear();
    targetItemBase = targetCountBase = 0;
    windowDrew.clear();
    lastDropped = dropEvery > 0 && (flips + 1) % (uint64_t)dropEvery == 0;
    missing += lastDropped;
    pm::FrameRecord r{};
    r.token = t; r.projected = next; r.presented = lastDropped ? 0 : next; r.status = lastDropped ? 1 : 0;
    r.scheduledAt = now;
    // The display's report on a frame comes after flip has returned, as on a Mac.
    r.callback = next + 0.75 * ifi; r.requestedTime = when > 0 ? when : NAN; r.presentRequest = NAN; r.committedAt = now;
    history.push_back(r);
    if (history.size() > 16384) history.erase(history.begin());
    flips++;
    if (mouseListening && clickAfter >= 0 && flips == (uint64_t)clickAfter)
        mouseEventList.push_back({next, 1, true, mouseX, mouseY});
    if (clickAfter >= 0 && flips == (uint64_t)clickAfter) {
        touchEventList.push_back({next, 1, 0, mouseX, mouseY});
        touchEventList.push_back({next + ifi / 2, 1, 1, mouseX + 5, mouseY});
        touchEventList.push_back({next + ifi, 1, 2, mouseX + 10, mouseY});
    }
    return t;
}

}  // namespace

// ---- lifecycle ------------------------------------------------------------------

void pm::installHostHooks(const pm::HostHooks &h) { hooks = h; }
void pm::shutdown() noexcept {
    try { pm::closeSession(); keyboard.release(); } catch (...) {}
}
bool pm::onMainThread() noexcept {
#if defined(__linux__)
    return syscall(SYS_gettid) == getpid();
#else
    return true;
#endif
}
void pm::serviceMainRunLoop(double seconds) {
    if (!pm::onMainThread()) fail("serviceMainRunLoop must be called on the main thread.");
    std::this_thread::sleep_for(std::chrono::duration<double>(seconds < 0.01 ? seconds : 0.01));
}
pm::EnvironmentInfo pm::environment() { return {pm::version(),"scripted","test OS","scripted GPU",true}; }
bool pm::defaultDisplayLink() noexcept { return std::getenv("PM_MOCK_DISPLAY_LINK_DEFAULT") != nullptr; }
const char *pm::version() noexcept { return pm::kEngineVersion; }
void pm::prepareApp() { pm::closeSession(); prepared = true; }

static bool mockDisplayLink=false;
pm::OpenResult pm::openSession(const pm::OpenOptions &o) {
    if(o.displayLink && !o.displaySync) fail("Display-link presentation requires displaySync.");
    mockDisplayLink=o.displayLink;
    double screenIndex = o.screenIndex;
    if (screenIndex != std::floor(screenIndex) || screenIndex < -1)
        fail("screen index must be a non-negative integer, or -1 for the last display.");
    if (o.drawableCount > 3) fail("maximum drawable count must be a nonnegative integer in range.");
    if (o.drawableCount < 2) fail("Drawable count must be 2 or 3.");
    if (screenIndex < 0) screenIndex = 0;
    if (screenIndex >= 1)
        failWith(pm::kErrScreen, "Screen index %d is out of range; %u display(s) are active.", (int)screenIndex, 1u);
    if (!prepared) fail("PrepareApp must be called before Open.");
    if (open) fail("PsychMetal native resources are already open.");
    readDisplay();
    texturesDrawn = texturesMade = 0;
    double hz = display.hz;
    if (o.refreshHz) {
        if (*o.refreshHz < 20 || *o.refreshHz > 1000) fail("refreshHz must be 20..1000.");
        hz = *o.refreshHz;
    }
    if (!pinned && hooks.pinModule) { hooks.pinModule(); pinned = true; }
    int click = -1; double mx = 0, my = 0;
    if (const char *e = getenv("PM_MOCK_MOUSE")) sscanf(e, "%d,%lf,%lf", &click, &mx, &my);
    dropEvery = 0;
    if (const char *e = getenv("PM_MOCK_DROP")) dropEvery = atoi(e);
    clickAfter = click; dx = mx; dy = my; mouseX = display.w / 2; mouseY = display.h / 2; flips = 0;
    ifi = 1.0 / hz; gridTime = NAN; gridSamples = 0; confirmed = 0; missing = 0; lastFlipToken = 0;
    startup.clear(); history.clear(); drawCount = 0; preparedToken = 0; windowDrew.clear();
    prefetch = false; displaySync = o.displaySync; waitConfirm = o.waitForConfirm;
    if (o.bitDepth != 8 && o.bitDepth != 10) fail("Bit depth must be 8 or 10.");
    readable = o.readback; haveFrame = false; frameToken = 0; drawItems.clear();
    bits = (int)o.bitDepth; blendNow = 0; gammaMode = 0; gammaTable.clear();
    for (int &c : clipNow) c = 0;
    targetHandle = 0; targetItemBase = targetCountBase = 0;
    queued.clear(); lastPlanned = 0; mouseListening = false; mouseEventList.clear(); touchEventList.clear();
    open = true; closing = false; session++;
    if (nextHandle <= session) nextHandle = session + 1;   // a texture handle is never the window's
    return {display.w, display.h, ifi, display.w, display.h, session};
}

std::vector<pm::StartupRecord> pm::startupHistory() { return startup; }
std::vector<pm::StartupRecord> pm::confirmStartup() {
    requireOpen();
    if (drawCount || preparedToken) fail("Confirm startup before queuing stimulus drawing.");
    if (prefetch) fail("Confirm startup before enabling drawable prefetch.");
    if (startup.empty())
        for (int i = 0; i < 2; i++) {
            uint64_t t = present(0);
            startup.push_back({t, 0, gridTime, gridTime, 1, gridTime});
        }
    history.clear(); confirmed = 0; missing = 0; flips = 0;   // the mouse script counts stimulus frames
    return startup;
}
static void clearMockShaders();
void pm::closeSession() {
    clearMockShaders();
    open = false; closing = true; prepared = false; textures.clear(); drawCount = 0; preparedToken = 0; windowDrew.clear();
    readable = false; haveFrame = false; drawItems.clear(); std::vector<uint16_t>().swap(frame);
    targetHandle = 0; targetItemBase = targetCountBase = 0; queued.clear(); mouseListening = false; mouseEventList.clear();
    std::vector<double>().swap(canvas);
}

// ---- presentation -------------------------------------------------------------------

pm::FlipResult pm::flip(double when) {
    double began = clockNow();
    if (when < 0) fail("Target must be nonnegative.");
    requireOpen();
    if (preparedToken) fail("Present or cancel the prepared frame before Flip.");
    // Frames that are queued come first.
    while (lastPlanned > clockNow()) std::this_thread::sleep_for(std::chrono::microseconds(200));
    if (lastPlanned > 0 && (!std::isfinite(gridTime) || gridTime < lastPlanned)) gridTime = lastPlanned;
    double queued = clockNow();
    uint64_t t = present(when);
    pm::FlipResult r{};
    // As the engine: without waiting for confirmation, flip returns before the
    // display has reported on the frame, and only flipStatus learns what became of it.
    r.time = gridTime; r.confirmed = waitConfirm && !lastDropped; r.slipRefreshes = 0; r.gridPeriod = ifi;
    r.queueMs = (queued - began) * 1000; r.returnTime = clockNow(); r.callMs = (r.returnTime - began) * 1000;
    r.token = lastFlipToken = t;
    return r;
}
// What the display has reported so far: nothing of a frame until its report has
// come, three quarters of a refresh after it was shown or should have been.
pm::FlipStatus pm::flipStatus() {
    requireOpen();
    bool confirmed = false, dropped = false;
    uint64_t reported = missing;
    if (!history.empty()) {
        const pm::FrameRecord &newest = history.back();
        const bool known = clockNow() >= newest.callback;
        if (!known && newest.status == 1) reported--;
        if (newest.token == lastFlipToken) { confirmed = known && newest.status == 0; dropped = known && newest.status == 1; }
    }
    return {confirmed, dropped, reported};
}
uint64_t pm::prepareFlip() {
    if(mockDisplayLink) fail("PrepareFlip requires direct presentation.");
    requireOpen();
    if (preparedToken) fail("A frame is already prepared; call PresentNow before preparing another.");
    if (lastPlanned > clockNow()) fail("Frames are queued; wait for them with QueueResults or QueueCancel them first.");
    flushTarget();
    preparedToken = nextToken++;
    if (readable) renderFrame(preparedToken);
    drawItems.clear();
    drawCount = 0;
    targetItemBase = targetCountBase = 0;
    windowDrew.clear();
    return preparedToken;
}

pm::QueueResult pm::queueFlip(double when) {
    if(mockDisplayLink) fail("QueueFlip requires direct presentation.");
    requireOpen();
    if (preparedToken) fail("Present the prepared frame before queuing frames.");
    if (!std::isfinite(when) || !(when > 0)) fail("A queued frame needs a presentation time.");
    double now = clockNow();
    auto waiting = [&]() { double n = 0; for (auto &q : queued) n += q.status == 0 && q.planned > clockNow(); return n; };
    for (auto &q : queued)
        if (q.status == 0 && q.planned > now && when <= q.when) fail("Queued frames must be given in order of time.");
    while (waiting() >= queueCapacity()) std::this_thread::sleep_for(std::chrono::microseconds(200));
    flushTarget();
    shapesEncoded += drawCount;
    drawCount = 0;
    uint64_t t = nextToken++;
    if (readable) renderFrame(t);
    drawItems.clear();
    targetItemBase = targetCountBase = 0;
    windowDrew.clear();
    now = clockNow();
    double target = when > now ? when : now;
    double planned = std::isfinite(gridTime) ? gridTime + std::ceil((target - gridTime) / ifi - 1e-9) * ifi : target;
    if (planned <= lastPlanned + 0.5 * ifi) planned = lastPlanned + ifi;
    if (planned <= now) planned += ifi;
    lastPlanned = planned;
    queued.push_back({t, when, planned, 0, false});
    pm::FrameRecord r{};
    r.token = t; r.projected = planned; r.presented = planned; r.status = 0; r.scheduledAt = now;
    r.callback = planned; r.requestedTime = when; r.presentRequest = planned - 0.5 * ifi; r.committedAt = now;
    history.push_back(r);
    confirmed++; flips++;
    return {t, waiting(), queueCapacity()};
}
std::vector<pm::QueuedFrame> pm::queueResults(bool wait) {
    requireOpen();
    if (wait)
        while (lastPlanned > clockNow()) std::this_thread::sleep_for(std::chrono::microseconds(200));
    std::vector<pm::QueuedFrame> out;
    double now = clockNow();
    for (auto &q : queued) {
        bool done = q.status != 0 || q.planned <= now;
        if (q.reported || !done) continue;
        q.reported = true;
        out.push_back({q.token, q.when, q.status == 0 ? q.planned : NAN, q.status});
    }
    queued.erase(std::remove_if(queued.begin(), queued.end(), [](const Queued &q) { return q.reported; }), queued.end());
    return out;
}
uint64_t pm::queueCancel() {
    requireOpen();
    // Frames within the presenter's lead of their time have been handed over.
    uint64_t n = 0;
    double now = clockNow(), kept = 0;
    for (auto &q : queued) {
        if (q.status == 0 && q.planned - 3 * ifi > now) {
            q.status = 5; n++;
            for (auto &r : history) if (r.token == q.token) { r.status = 5; r.presented = 0; }
        } else if (q.status == 0 && q.planned > kept) {
            kept = q.planned;
        }
    }
    lastPlanned = kept;
    return n;
}
pm::PresentResult pm::presentNow() {
    if (!preparedToken) fail("No prepared frame; call PrepareFlip first.");
    preparedToken = 0;
    double t = clockNow();
    return {t, 0.01};
}
void pm::setDisplaySync(bool on) { if(mockDisplayLink && !on) fail("Display link requires sync."); if (!open) fail("PsychMetal is not open."); displaySync = on; }
void pm::setPrefetchDrawable(bool on) { if(mockDisplayLink && on) fail("Display link owns prefetch."); if (!open) fail("PsychMetal is not open."); prefetch = on; }

pm::GridAnchor pm::gridAnchor() {
    return {gridSamples ? gridTime : NAN, ifi, (double)gridSamples};
}
double pm::nextPhase(double after, double phase) {
    if (!gridSamples) return NAN;
    double base = gridTime + phase * ifi;
    return base + std::ceil((after - base) / ifi - 1e-9) * ifi;
}
double pm::nextRefresh(double after) {
    if (!gridSamples) return NAN;
    return gridTime + std::ceil((after - gridTime) / ifi - 1e-9) * ifi;
}
pm::WaitToDrawResult pm::waitToDraw(double target, double budget) {
    requireOpen();
    if (budget < 0) fail("Drawing budget must be nonnegative.");
    double lead = 1.7 * ifi + 0.004;
    return {clockNow(), lead, target - lead - budget};
}

// ---- drawing ------------------------------------------------------------------------

void pm::setBackgroundColor(double r, double g, double b, double a) {
    const double v[4] = {r, g, b, a};
    for (int i = 0; i < 4; i++) {
        if (!(v[i] >= 0.0 && v[i] <= 1.0)) fail("Background colour components run 0 to 1.");
        bg[i] = v[i];
    }
}

void pm::addShapes(const pm::ArrayView &kind, const pm::ArrayView &param, const pm::ArrayView &rect,
                   const pm::ArrayView &color, const pm::ArrayView &extra) {
    if (!open) fail("PsychMetal is not open.");
    const pm::ArrayView *all[5] = {&kind, &param, &rect, &color, &extra};
    for (auto v : all) if (v->type != pm::ScalarType::Float64) fail("AddShapes arguments must be real double arrays.");
    size_t n = kind.ndim == 1 ? kind.shape[0] : 0;
    bool ok = kind.ndim == 1 && param.ndim == 1 && param.shape[0] == n;
    for (int i = 2; i < 5; i++) ok = ok && all[i]->ndim == 2 && all[i]->shape[0] == n && all[i]->shape[1] == 4;
    if (!ok) fail("AddShapes expects kind and param as 1xN and rect, color and extra as 4xN.");
    if (n > 8192 - drawCount) fail("Frame draw capacity exceeded; split the work across frames.");
    auto at = [](const pm::ArrayView &v, size_t i, size_t j) {
        return *(const double *)((const unsigned char *)v.data + i * v.strides[0] + j * v.strides[1]);
    };
    for (size_t k = 0; k < n; k++) {
        double kd = at(kind, k, 0);
        if (!std::isfinite(kd) || kd != std::floor(kd) || kd < 0 || kd > 7) fail("Invalid shape kind.");
        if (!std::isfinite(at(param, k, 0)) || at(param, k, 0) < 0) fail("Invalid shape parameter.");
        for (size_t c = 0; c < 4; c++)
            if (!std::isfinite(at(rect, k, c)) || !std::isfinite(at(color, k, c)) || at(color, k, c) < 0 ||
                at(color, k, c) > 1 || !std::isfinite(at(extra, k, c)))
                fail("Shape arrays contain invalid values.");
    }
    if (readable)
        for (size_t k = 0; k < n; k++) {
            if (at(kind, k, 0) != 0) continue;       // FillRect only
            DrawItem it;
            stamp(it);
            for (size_t c = 0; c < 4; c++) { it.rect[c] = at(rect, k, c); it.color[c] = at(color, k, c); }
            drawItems.push_back(it);
        }
    drawCount += n;
    shapesAppended += n;
}

static void probe(const Texture &t) {
    size_t oc = t.shape.channels == 1 ? 1 : 4;
    auto texel = [&](size_t y, size_t x) {
        pm::Rect4 r{};
        if (y >= t.shape.height || x >= t.shape.width) return r;
        for (size_t c = 0; c < 4; c++) r[c] = c < oc ? (double)t.texels[(y * t.shape.width + x) * oc + c] : NAN;
        return r;
    };
    probeA = texel(1, 0);
    probeB = texel(0, 1);
}

uint64_t pm::makeTexture(const pm::ArrayView &image) {
    requireOpen();
    if (textures.size() >= 256) fail("No free texture slots.");
    Texture t;
    t.shape = packTexels(image, t.texels);
    t.bytes = pm::internal::isByteImage(image);
    probe(t);
    uint64_t h = nextHandle++;
    texturesMade++;
    textures[h] = std::move(t);
    return h;
}
void pm::updateTexture(uint64_t handle, const pm::ArrayView &image) {
    requireOpen();
    auto it = textures.find(handle);
    if (it == textures.end()) fail("Invalid or expired texture handle.");
    if (it->second.offscreen) fail("That is an offscreen window; draw into it instead.");
    it->second.shape = packTexels(image, it->second.texels);
    it->second.bytes = pm::internal::isByteImage(image);
    probe(it->second);
}
void pm::drawTextures(const pm::ArrayView &handle, const pm::ArrayView &src, const pm::ArrayView &dst,
                      const pm::ArrayView &angle, const pm::ArrayView &tint, const pm::ArrayView &filter) {
    if (!open) fail("PsychMetal is not open.");
    const pm::ArrayView *all[6] = {&handle, &src, &dst, &angle, &tint, &filter};
    for (auto v : all) if (v->type != pm::ScalarType::Float64) fail("DrawTextures arguments must be real double arrays.");
    size_t n = handle.ndim == 1 ? handle.shape[0] : 0;
    bool ok = handle.ndim == 1 && angle.ndim == 1 && angle.shape[0] == n && filter.ndim == 1 && filter.shape[0] == n;
    for (auto v : {&src, &dst, &tint}) ok = ok && v->ndim == 2 && v->shape[0] == n && v->shape[1] == 4;
    if (!ok) fail("DrawTextures expects handles, angles and filter modes as 1xN and srcRects, dstRects and tints as 4xN.");
    if (n > 8192 - drawCount) fail("Frame draw capacity exceeded; split the work across frames.");
    auto at = [](const pm::ArrayView &v, size_t i, size_t j) {
        return *(const double *)((const unsigned char *)v.data + i * v.strides[0] + j * v.strides[1]);
    };
    for (size_t k = 0; k < n; k++) {
        if (!textures.count(pm::checkUnsigned(at(handle, k, 0), "texture handle", pm::kMaxId)))
            fail("Invalid or expired texture handle.");
        pm::checkUnsigned(at(filter, k, 0), "filter mode", 1);
        for (size_t c = 0; c < 4; c++)
            if (!std::isfinite(at(src, k, c)) || !std::isfinite(at(dst, k, c)) || !std::isfinite(at(tint, k, c)) ||
                at(tint, k, c) < 0 || at(tint, k, c) > 1)
                fail("Invalid texture rectangle or tint.");
        if (!std::isfinite(at(angle, k, 0))) fail("Rotation angle out of range.");
    }
    if (targetHandle)
        for (size_t k = 0; k < n; k++)
            if ((uint64_t)at(handle, k, 0) == targetHandle) fail("An offscreen window cannot be drawn into itself.");
    if (readable)
        for (size_t k = 0; k < n; k++) {
            if (at(angle, k, 0) != 0 || at(filter, k, 0) != 0) continue;   // unrotated, nearest only
            DrawItem it;
            it.texture = true;
            stamp(it);
            it.image = std::make_shared<Texture>(textures[(uint64_t)at(handle, k, 0)]);
            for (size_t c = 0; c < 4; c++) { it.src[c] = at(src, k, c); it.dst[c] = at(dst, k, c); it.tint[c] = at(tint, k, c); }
            drawItems.push_back(it);
        }
    if (!targetHandle)
        for (size_t k = 0; k < n; k++)
            if (textures[(uint64_t)at(handle, k, 0)].offscreen) windowDrew.insert((uint64_t)at(handle, k, 0));
    drawCount += n;
    texturesDrawn += n;
}
void pm::updateTextureRegion(uint64_t handle, const pm::ArrayView &image, double x, double y) {
    requireOpen();
    auto it = textures.find(handle);
    if (it == textures.end()) fail("Invalid or expired texture handle.");
    Texture part, &whole = it->second;
    if (whole.offscreen) fail("That is an offscreen window; draw into it instead.");
    part.shape = packTexels(image, part.texels);
    if (pm::internal::isByteImage(image) != whole.bytes || part.shape.channels != whole.shape.channels)
        fail("A partial update must have the texture's type (uint8 or logical, or float) and channel count.");
    if (!(x >= 0 && y >= 0) || x != std::floor(x) || y != std::floor(y) ||
        x + (double)part.shape.width > (double)whole.shape.width || y + (double)part.shape.height > (double)whole.shape.height)
        fail("A partial update must lie inside the texture, at whole pixels.");
    size_t oc = whole.shape.channels == 1 ? 1 : 4;
    for (size_t row = 0; row < part.shape.height; row++)
        for (size_t i = 0; i < part.shape.width * oc; i++)
            whole.texels[(((size_t)y + row) * whole.shape.width + (size_t)x) * oc + i] =
                part.texels[row * part.shape.width * oc + i];
    probe(whole);
}
void pm::closeTexture(uint64_t handle) {
    if (!textures.count(handle)) fail("Invalid or expired texture handle.");
    if (handle == targetHandle) {
        drawItems.resize(std::min(drawItems.size(), targetItemBase));
        drawCount = targetCountBase;
        targetHandle = 0; targetItemBase = targetCountBase = 0;
    }
    textures.erase(handle);
}
void pm::setClip(const std::optional<pm::Rect4> &rect) {
    requireOpen();
    if (!rect) { for (int &c : clipNow) c = 0; return; }
    const pm::Rect4 &r = *rect;
    for (double v : r)
        if (!std::isfinite(v) || v != std::floor(v) || std::fabs(v) > 1e6)
            fail("The clip rect must be [left top right bottom] in whole pixels.");
    if (!(r[2] > r[0] && r[3] > r[1])) fail("The clip rect must be [left top right bottom] in whole pixels.");
    for (size_t i = 0; i < 4; i++) clipNow[i] = (int)r[i];
}
uint64_t pm::openOffscreen(double width, double height, const pm::Rect4 &rgba) {
    requireOpen();
    if (!(width >= 1 && width <= 16384 && height >= 1 && height <= 16384) ||
        width != std::floor(width) || height != std::floor(height))
        fail("An offscreen window is 1 to 16384 whole pixels each way.");
    for (double v : rgba)
        if (!(v >= 0.0 && v <= 1.0)) fail("Offscreen window colour components run 0 to 1.");
    if (textures.size() >= 256) fail("No free texture slots.");
    Texture t;
    t.shape.width = (size_t)width; t.shape.height = (size_t)height; t.shape.channels = 4;
    t.offscreen = true;
    t.texels.resize(t.shape.width * t.shape.height * 4);
    for (size_t i = 0; i < t.texels.size(); i++) t.texels[i] = (__fp16)(i % 4 < 3 ? rgba[i % 4] * rgba[3] : rgba[3]);
    uint64_t h = nextHandle++;
    texturesMade++;
    textures[h] = std::move(t);
    return h;
}
void pm::setTarget(uint64_t handle) {
    requireOpen();
    if (handle == targetHandle) return;
    if (handle) {
        auto it = textures.find(handle);
        if (it == textures.end()) fail("Invalid or expired texture handle.");
        if (!it->second.offscreen) fail("That texture is not an offscreen window.");
        if (windowDrew.count(handle))
            fail("The window has draws of that offscreen window waiting; Flip before drawing into it again.");
    }
    flushTarget();
    targetHandle = handle;
    targetItemBase = handle ? drawItems.size() : 0;
    targetCountBase = handle ? drawCount : 0;
}
void pm::drawPolygon(const pm::ArrayView &points, const pm::Rect4 &rgba, double pen) {
    requireOpen();
    if (points.type != pm::ScalarType::Float64 || points.ndim != 2 || points.shape[1] != 2 ||
        points.shape[0] < 3 || points.shape[0] > 4096)
        fail("A polygon is 3 to 4096 points, as Nx2 real doubles.");
    if (!(pen >= 0 && pen <= 1024)) fail("The polygon pen width must be 0 (filled) to 1024 pixels.");
    for (double v : rgba)
        if (!(v >= 0.0 && v <= 1.0)) fail("Polygon colour components run 0 to 1.");
    DrawItem it;
    stamp(it);
    it.pen = pen;
    double lo[2] = {INFINITY, INFINITY}, hi[2] = {-INFINITY, -INFINITY};
    for (size_t i = 0; i < points.shape[0]; i++)
        for (size_t c = 0; c < 2; c++) {
            double v = *(const double *)((const unsigned char *)points.data + (ptrdiff_t)i * points.strides[0] +
                                         (ptrdiff_t)c * points.strides[1]);
            if (!std::isfinite(v) || std::fabs(v) > 1e6) fail("Polygon points must be finite, in pixels.");
            it.polygon.push_back(v);
            lo[c] = std::fmin(lo[c], v); hi[c] = std::fmax(hi[c], v);
        }
    double margin = 1 + std::ceil(pen * 5);
    if (!(std::ceil(hi[0]) - std::floor(lo[0]) + 2 * margin <= 16384 && std::ceil(hi[1]) - std::floor(lo[1]) + 2 * margin <= 16384))
        fail("The polygon is too large to draw: 16384 pixels at most.");
    if (drawCount >= 8192) fail("Frame draw capacity exceeded; split the work across frames.");
    it.rect[0] = std::floor(lo[0]) - margin; it.rect[1] = std::floor(lo[1]) - margin;
    it.rect[2] = std::ceil(hi[0]) + margin; it.rect[3] = std::ceil(hi[1]) + margin;
    for (size_t c = 0; c < 4; c++) it.color[c] = rgba[c];
    if (readable) drawItems.push_back(it);
    drawCount++;
    texturesDrawn++;
}
void pm::setBlendMode(uint64_t mode) {
    requireOpen();
    if (mode > 2) fail("Blend mode must be 0 (source-over), 1 (additive) or 2 (copy).");
    blendNow = (int)mode;
}
void pm::setGamma(double r, double g, double b) {
    requireOpen();
    const double v[3] = {r, g, b};
    for (double e : v) if (!(e >= 0.05 && e <= 20.0)) fail("Gamma exponents must be 0.05 to 20.");
    for (int c = 0; c < 3; c++) exponent[c] = (double)(float)v[c];
    gammaMode = (r == 1 && g == 1 && b == 1) ? 0 : 1;
}
void pm::setGammaTable(const pm::ArrayView &table) {
    requireOpen();
    if (table.type != pm::ScalarType::Float64 || table.ndim != 2 || table.shape[1] != 3 ||
        table.shape[0] < 2 || table.shape[0] > 4096)
        fail("The gamma table must be Nx3 real doubles, N from 2 to 4096.");
    std::vector<double> values(table.shape[0] * 3);
    for (size_t i = 0; i < table.shape[0]; i++)
        for (size_t c = 0; c < 3; c++) {
            double v = *(const double *)((const unsigned char *)table.data + (ptrdiff_t)i * table.strides[0] +
                                         (ptrdiff_t)c * table.strides[1]);
            if (!(v >= 0.0 && v <= 1.0)) fail("Gamma table values run 0 to 1.");
            values[i * 3 + c] = (double)(float)v;
        }
    gammaTable = values;
    gammaMode = 2;
}

// Text: no glyphs here. The bounds are those of a monospaced face 0.6 em wide.
// DrawText inks a block in each character's cell: the top of the line for '^',
// the bottom for '_', nothing for a space and the middle for anything else,
// which is enough to read back where text went and which way up it is.
static pm::TextBounds mockText(const std::string &utf8, double size) {
    requireOpen();
    if (!(size >= 4 && size <= 2048)) fail("Text size must be 4 to 2048 pixels.");
    if (utf8.empty()) fail("Text must not be empty.");
    size_t characters = 0;
    for (unsigned char ch : utf8) characters += (ch & 0xC0) != 0x80;
    return {std::ceil(0.6 * size * (double)characters) + 2, std::ceil(1.2 * size) + 2, std::ceil(0.9 * size) + 1};
}
pm::TextBounds pm::textBounds(const std::string &utf8, const std::string &, double size) { return mockText(utf8, size); }
pm::TextBounds pm::drawText(const std::string &utf8, const std::string &, double size, double x, double y,
                            const pm::Rect4 &rgba) {
    if (!std::isfinite(x) || !std::isfinite(y)) fail("Text position must be finite.");
    for (double v : rgba) if (!(v >= 0.0 && v <= 1.0)) fail("Text colour components run 0 to 1.");
    pm::TextBounds b = mockText(utf8, size);
    if (drawCount >= 8192) fail("Frame draw capacity exceeded; split the work across frames.");
    if (readable) {
        double left = std::floor(x + 0.5) + 1, top = std::floor(y + 0.5), cell = 0.6 * size;
        size_t k = 0;
        for (unsigned char ch : utf8) {
            if ((ch & 0xC0) == 0x80) continue;
            double from = ch == '^' ? 0.10 : ch == '_' ? 0.80 : 0.30, to = ch == '^' ? 0.30 : ch == '_' ? 0.95 : 0.70;
            if (ch != ' ') {
                DrawItem it;
                stamp(it);
                it.rect[0] = std::floor(left + cell * (double)k + 1); it.rect[2] = std::floor(left + cell * (double)(k + 1) - 1);
                it.rect[1] = std::floor(top + from * b.height); it.rect[3] = std::floor(top + to * b.height);
                for (int c = 0; c < 4; c++) it.color[c] = rgba[(size_t)c];
                drawItems.push_back(it);
            }
            k++;
        }
    }
    drawCount++;
    texturesDrawn++;
    return b;
}

pm::ImageRegion pm::checkImageRect(const std::optional<pm::Rect4> &rect) {
    requireOpen();
    if (!readable) fail("GetImage requires a window opened with readback.");
    if (!rect) return {0, 0, (size_t)display.w, (size_t)display.h, bits};
    const pm::Rect4 &r = *rect;
    for (double v : r)
        if (!std::isfinite(v) || v != std::floor(v))
            fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    if (r[0] < 0 || r[1] < 0 || r[2] <= r[0] || r[3] <= r[1] || r[2] > display.w || r[3] > display.h)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    return {(size_t)r[0], (size_t)r[1], (size_t)(r[2] - r[0]), (size_t)(r[3] - r[1]), bits};
}

static void checkRead(const pm::ImageRegion &g, bool matches, size_t h, size_t w, size_t c, int ndim, bool data) {
    requireOpen();
    if (!readable) fail("GetImage requires a window opened with readback.");
    if (!matches) fail(bits == 10 ? "This window is 10-bit; its frames are read as 16-bit values."
                                  : "This window is 8-bit; its frames are read as bytes.");
    if (!g.width || !g.height || g.x + g.width > (size_t)display.w || g.y + g.height > (size_t)display.h)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    if (!data || ndim != 3 || h != g.height || w != g.width || c != 3)
        fail("Image output buffer does not match the request.");
    if (!haveFrame) fail("GetImage needs a frame; Flip first.");
    if (frameToken != nextToken - 1) fail("The last frame was not copied; there is nothing to read.");
}
void pm::getImage(const pm::ImageRegion &g, const pm::MutableByteView &out) {
    checkRead(g, bits == 8, out.shape[0], out.shape[1], out.shape[2], out.ndim, out.data != nullptr);
    for (size_t y = 0; y < g.height; y++)
        for (size_t x = 0; x < g.width; x++) {
            const uint16_t *p = &frame[((g.y + y) * (size_t)display.w + g.x + x) * 4];
            uint8_t *q = out.data + (ptrdiff_t)y * out.strides[0] + (ptrdiff_t)x * out.strides[1];
            for (int c = 0; c < 3; c++) q[c * out.strides[2]] = (uint8_t)p[c];
        }
}
void pm::getImage16(const pm::ImageRegion &g, const pm::MutableWordView &out) {
    checkRead(g, bits == 10, out.shape[0], out.shape[1], out.shape[2], out.ndim, out.data != nullptr);
    for (size_t y = 0; y < g.height; y++)
        for (size_t x = 0; x < g.width; x++) {
            const uint16_t *p = &frame[((g.y + y) * (size_t)display.w + g.x + x) * 4];
            unsigned char *q = (unsigned char *)out.data + (ptrdiff_t)y * out.strides[0] + (ptrdiff_t)x * out.strides[1];
            for (int c = 0; c < 3; c++) std::memcpy(q + c * out.strides[2], &p[c], 2);
        }
}

// ---- display modes, cursor, input ------------------------------------------------------

std::vector<pm::DisplayMode> pm::modes(double si) {
    if (si < 0) si = 0;
    if (si != std::floor(si) || si >= 1) fail("Screen index is out of range.");
    readDisplay();
    return {{display.w, display.h, display.w, display.h, display.hz}, {1024, 768, 1024, 768, 60}};
}
void pm::setMode(double si, double w, double h, double hz) {
    if (open) fail("Close the PsychMetal window before changing the display mode.");
    auto m=pm::modes(si);
    if (pm::internal::selectDisplayMode(m,0,w,h,hz)<m.size()) return;
    failWith(pm::kErrMode,"No matching display mode.");
}
void pm::setCursorVisible(bool) {}
pm::LinkInfo pm::linkInfo() {
    if (!open || closing) fail("LinkInfo requires an open PsychMetal window.");
    pm::LinkInfo k{NAN, NAN, NAN, NAN, NAN};
    k.pixelGbps = display.w * display.h * 3.0 * bits / ifi / 1e9;
    double lanes, gbps;
    if (const char *e = getenv("PM_MOCK_LINK"))
        if (sscanf(e, "%lf,%lf", &lanes, &gbps) == 2) {
            k.lanes = lanes; k.laneGbps = gbps; k.payloadGbps = lanes * gbps * 0.8;
            double least = display.w * display.h * 24.0 / ifi / 1e9, ample = display.w * display.h * 37.5 / ifi / 1e9;
            if (k.payloadGbps < least) k.compressed = 1;
            else if (k.payloadGbps >= ample) k.compressed = 0;
        }
    return k;
}

pm::MouseState pm::mouse() {
    if (!open) fail("Mouse requires an open PsychMetal window.");
    mouseX += dx; mouseY += dy;
    pm::MouseState m{};
    m.x = mouseX; m.y = mouseY;
    m.buttons = {clickAfter >= 0 && flips >= (uint64_t)clickAfter, false, false};
    return m;
}
void pm::setMouse(double x, double y) {
    if (!open) fail("SetMouse requires an open PsychMetal window.");
    if (!(x >= 0 && x <= display.w && y >= 0 && y <= display.h))
        fail("SetMouse position must be inside the window, in pixels.");
    mouseX = x - dx; mouseY = y - dy;   // the next read is the position set; the scripted drift goes on from there
}
pm::KeyState pm::keys() {
    if (getenv("PM_MOCK_INPUT_SERIAL")) {
        static std::atomic<int> readers{0};
        if (readers.fetch_add(1)!=0) {readers.fetch_sub(1);fail("Concurrent input readers.");}
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        readers.fetch_sub(1);
    }
    pm::KeyState k{};
    k.anyDown = false; k.secs = clockNow(); k.securePid = 0;
    // "USAGE:FROM-TO,...": key USAGE is down while FROM <= frames flipped since open < TO.
    if (const char *e = getenv("PM_MOCK_KEYS")) {
        int usage, from, to, used;
        while (sscanf(e, "%d:%d-%d%n", &usage, &from, &to, &used) == 3) {
            if (usage >= 1 && usage <= 256 && flips >= (uint64_t)from && flips < (uint64_t)to)
                k.down[(size_t)usage - 1] = k.anyDown = true;
            e += used;
            if (*e == ',') e++;
        }
    }
    return k;
}
pm::KbQueueStatus pm::kbQueueStatus() {
    auto s = keyboard.stats();
    return {s.created, s.running, s.interval, s.lastScanInterval, s.maxScanInterval,
            (uint64_t)s.scans, (uint64_t)s.dropped, 0,
            s.events, (uint64_t)s.eventStamped, (uint64_t)s.pollStamped, s.maxEventDelay * 1000};
}
pm::TouchEvents pm::touchEvents() {
    if (!open) fail("TouchEvents requires an open PsychMetal window.");
    pm::TouchEvents out{};
    out.events.swap(touchEventList);
    return out;
}
pm::MouseEvents pm::mouseEvents() {
    if (!open) fail("MouseEvents requires an open PsychMetal window.");
    pm::MouseEvents out{};
    if (!mouseListening) { mouseListening = true; mouseEventList.clear(); return out; }
    out.events.swap(mouseEventList);
    return out;
}
void pm::kbQueueCreate(const std::array<double, 256> &m, double interval) {
    bool filter[256];
    for (int k = 0; k < 256; k++) { if (!std::isfinite(m[(size_t)k])) fail("Key mask must be finite."); filter[k] = m[(size_t)k] != 0; }
    if (interval < .001 || interval > .1) fail("Poll interval must be between .001 and .1 seconds.");
    keyboard.create(filter, interval);
    if (!keyboardPinned) { if (hooks.pinModule) hooks.pinModule(); keyboardPinned = true; }
}
void pm::kbQueueRelease() {
    keyboard.release();
    if (keyboardPinned) { keyboardPinned = false; if (hooks.unpinModule) hooks.unpinModule(); }
}
void pm::kbQueueStart() {
    if (!keyboard.exists()) fail("Create a keyboard queue first.");
    if (!keyboard.start()) fail("Cannot start keyboard queue worker.");
}
void pm::kbQueueStop() { if (!keyboard.exists()) fail("Create a keyboard queue first."); keyboard.stop(); }
void pm::kbQueueFlush() { if (!keyboard.exists()) fail("Create a keyboard queue first."); keyboard.flush(); }
pm::KbEvents pm::kbQueueGetEvents() {
    if (!keyboard.exists()) fail("Create a keyboard queue first.");
    unsigned long long dropped = 0;
    auto e = keyboard.events(dropped);
    pm::KbEvents out{};
    for (auto &x : e) out.events.push_back({x.time, x.key, x.pressed});
    out.dropped = dropped;
    return out;
}
pm::KbCheck pm::kbQueueCheck() {
    if (!keyboard.exists()) fail("Create a keyboard queue first.");
    double s[4][256];
    keyboard.check(s);
    pm::KbCheck c{};
    c.pressed = false;
    for (int k = 0; k < 256; k++) if (s[0][k] != 0) c.pressed = true;
    std::memcpy(c.firstPress.data(), s[0], sizeof(s[0]));
    std::memcpy(c.firstRelease.data(), s[1], sizeof(s[1]));
    std::memcpy(c.lastPress.data(), s[2], sizeof(s[2]));
    std::memcpy(c.lastRelease.data(), s[3], sizeof(s[3]));
    return c;
}

// ---- time, diagnostics -------------------------------------------------------------------

double pm::now() noexcept { return clockNow(); }
double pm::waitUntil(double deadline) {
    // Sleep, then spin the last 2 ms, as the engine does, so the wait-precision
    // checks in the inventory tests mean the same thing here as on a Mac.
    while (deadline - clockNow() > 0.002) std::this_thread::sleep_for(std::chrono::microseconds(200));
    while (clockNow() < deadline) {}
    return clockNow();
}
pm::DiagnosticReport pm::diagnostic() {
    pm::DiagnosticReport r{};
    r.history = history;
    auto &d = r.summary;
    d.confirmedPresentations = (double)confirmed;
    d.missingPresentedTimes = (double)missing;
    d.renderWidth = display.w; d.renderHeight = display.h;
    d.drawableWidth = display.w; d.drawableHeight = display.h;
    d.hostBundleIdentifier = "mock"; d.macOSVersion = "mock"; d.processName = "mock";
    d.waitForConfirm = waitConfirm; d.displaySyncEnabled = displaySync; d.readbackEnabled = readable;
    d.measuredRefreshHz = 1.0 / ifi; d.gridSamples = (double)gridSamples;
    d.shapesAppended = (double)shapesAppended; d.shapesEncoded = (double)shapesEncoded;
    d.texturesCreated = (double)texturesMade; d.texturesDrawn = (double)texturesDrawn;
    d.lastShapeRect = probeA; d.lastShapeColor = probeB;
    d.backingScaleFactor = 1;
    return r;
}

static std::map<uint64_t,std::string> mockShaders;
static uint64_t mockShaderNext=1;
static void clearMockShaders(){mockShaders.clear();}
uint64_t pm::createShader(const std::string &source) {
    requireOpen();if(source.empty() || source.size()>262144 || source.find('\0')!=std::string::npos || source.find("psychmetal_main")==std::string::npos)fail("Invalid custom shader source (contract stub, not a compiler).");
    if(mockShaders.size()>=64)fail("Shader capacity exceeded.");
    uint64_t h=mockShaderNext++;mockShaders[h]=source;return h;
}
void pm::closeShader(uint64_t handle) {if(!mockShaders.erase(handle))fail("Invalid or expired shader handle.");}
void pm::drawShader(uint64_t handle,const ArrayView &parameters,const ArrayView &dst,uint64_t mask,const ArrayView *coverage) {
    requireOpen();checkShaderParameters(parameters);if(!mockShaders.count(handle))fail("Invalid or expired shader handle.");
    if(dst.type!=ScalarType::Float64 || dst.ndim!=1 || dst.shape[0]!=4 || !dst.data)fail("Invalid shader destination.");
    double r[4];for(int i=0;i<4;i++){memcpy(r+i,(const char*)dst.data+i*dst.strides[0],8);if(!std::isfinite(r[i]) || fabs(r[i])>1e6)fail("Invalid shader destination.");}
    if(r[2]<=r[0] || r[3]<=r[1])fail("Invalid shader destination.");
    if(coverage)checkMask(*coverage);
    if(mask && (!textures.count(mask) || textures.at(mask).shape.channels!=1 || textures.at(mask).offscreen))fail("Invalid shader mask.");
    if(drawCount>=8192)fail("Frame capacity exceeded.");
    DrawItem item;stamp(item);drawItems.push_back(item);++drawCount;
}

// Masked image contract only; shader pixels are checked on a real Metal device.
void pm::drawMaskedTexture(uint64_t source,const pm::ArrayView &parameters,uint64_t mask,const pm::ArrayView *coverage) {
    requireOpen();
    if(parameters.type!=pm::ScalarType::Float64 || parameters.ndim!=1 || parameters.shape[0]!=14 || !parameters.data)fail("Invalid masked texture parameters.");
    double p[14];for(int i=0;i<14;i++){memcpy(p+i,(const char*)parameters.data+(ptrdiff_t)i*parameters.strides[0],8);if(!std::isfinite(p[i]))fail("Nonfinite image parameter.");}
    for(int i=0;i<4;i++)if(p[i]<0 || p[i]>1 || fabs(p[i+4])>1e6 || p[i+8]<0 || p[i+8]>1)fail("Invalid crop, destination or tint.");
    if(p[2]<=p[0] || p[3]<=p[1] || p[6]<=p[4] || p[7]<=p[5] || fabs(p[12])>1e6 || (p[13]!=0 && p[13]!=1))fail("Invalid image geometry.");
    if(coverage)pm::checkMask(*coverage);
    if(!textures.count(source) || source==targetHandle)fail("Invalid source texture.");
    if(mask && (!textures.count(mask) || textures.at(mask).shape.channels!=1 || textures.at(mask).offscreen))fail("Invalid image mask.");
    if(drawCount>=8192)fail("Frame draw capacity exceeded.");
    DrawItem it;stamp(it);it.image=std::make_shared<Texture>(textures.at(source));drawItems.push_back(it);++drawCount;++texturesDrawn;
    if(!targetHandle && textures.at(source).offscreen)windowDrew.insert(source);
}

// Command-contract stub only; procedural pixels are covered by the real GPU test.
void pm::drawStimulus(const pm::ArrayView &parameters,const pm::ArrayView &dst,uint64_t mask,const pm::ArrayView *coverage) {
    requireOpen(); pm::checkStimulus(parameters);if(coverage) pm::checkMask(*coverage);
    if(dst.type!=pm::ScalarType::Float64 || dst.ndim!=1 || dst.shape[0]!=4) fail("Invalid stimulus rect.");
    if(mask && (textures.find(mask)==textures.end() || textures.at(mask).shape.channels!=1)) fail("Invalid stimulus mask.");
    if(drawCount>=8192) fail("Frame draw capacity exceeded.");
    DrawItem item;item.procedural=true;stamp(item);
    for(size_t i=0;i<15;i++) item.stimulus[i]=*(const double*)((const char*)parameters.data+i*parameters.strides[0]);
    for(size_t i=0;i<4;i++) item.rect[i]=*(const double*)((const char*)dst.data+i*dst.strides[0]);
    drawItems.push_back(item);++drawCount;
}

std::vector<pm::FrameRecord> pm::recentFrames(size_t count) {
    requireOpen();
    if(count < 1 || count > 256) fail("History count must be from 1 to 256.");
    auto begin = history.size() > count ? history.end() - count : history.begin();
    return {begin, history.end()};
}

// Contract-only timeline stand-in. Actual native loop/snapshots are tested by
// test_play_timeline.py. This renderer does not synthesize procedural pixels.
static std::atomic<bool> mockTimelineCancelled{false};
static pm::timeline::LiveState mockLiveTimeline;
void pm::updateTimeline(const ArrayView &updates){mockLiveTimeline.update(updates);}
void pm::cancelTimeline(bool cancel) noexcept { mockTimelineCancelled.store(cancel); }
pm::TimelineResult pm::playTimeline(uint64_t frames,const pm::ArrayView &tracks,const pm::ArrayView *keyframes) {
    requireOpen();
    if(frames<1 || frames>1000000) fail("Invalid frame count.");
    if(targetHandle || preparedToken) fail("Timeline requires window target and no prepared frame.");
    if(tracks.type!=pm::ScalarType::Float64 || tracks.ndim!=2 || tracks.shape[1]!=6 || tracks.shape[0]>32768 || (tracks.shape[0] && !tracks.data)) fail("Invalid timeline tracks.");
    auto at=[&](size_t i,size_t j){return *(const double*)((const char*)tracks.data+i*tracks.strides[0]+j*tracks.strides[1]);};
    std::vector<pm::timeline::Track> program;
    std::set<std::pair<uint64_t,uint64_t>> used;
    for(size_t i=0;i<tracks.shape[0];i++) {
        if(drawItems.empty()) fail("Timeline needs a queued draw.");
        auto index=pm::checkUnsigned(at(i,0),"index",drawItems.size()-1);
        auto parameter=pm::checkUnsigned(at(i,1),"parameter",3);
        auto kind=pm::checkUnsigned(at(i,2),"kind",1);
        auto period=pm::checkUnsigned(at(i,3),"period",1000000);
        double amplitude=at(i,4),offset=at(i,5);
        if(!drawItems[index].procedural || period<2 || period%2 || !std::isfinite(amplitude) || !std::isfinite(offset) || !used.insert({index,parameter}).second) fail("Invalid track.");
        double low=kind ? std::min(offset,offset+amplitude) : offset-std::abs(amplitude);
        double high=kind ? std::max(offset,offset+amplitude) : offset+std::abs(amplitude);
        if(!std::isfinite(low) || !std::isfinite(high) || low<(parameter==0 ? 0 : -1000000) || high>(parameter==0 ? 1 : 1000000)) fail("Invalid track range.");
        program.push_back({index,parameter,kind,period,amplitude,offset});
    }
    auto scene=drawItems;size_t count=drawCount;
    pm::TimelineResult result{};result.expectedRefreshHz=1/ifi;
    pm::timeline::Presentations shown;shown.period=ifi;
    std::vector<std::array<double,4>> bounds(scene.size());std::vector<bool> enabled(scene.size());
    for(size_t i=0;i<scene.size();i++){enabled[i]=scene[i].procedural;for(int j=0;j<4;j++)bounds[i][j]=scene[i].rect[j];}
    std::vector<std::array<bool,4>> controls(scene.size());for(const auto &track:program)controls[track.drawIndex][track.parameter]=true;
    auto keyed=pm::timeline::keyTracks(keyframes,bounds,enabled,controls);(void)keyed;
    mockLiveTimeline.start(bounds,enabled);
    try {
        for(uint64_t frame=0;frame<frames;frame++) {
            if(mockTimelineCancelled.load() || pm::keys().down[40]) {result.cancelled=true;break;}
            drawItems=scene;drawCount=count;
            for(const auto &track:program){
                auto &item=drawItems[track.drawIndex];double value=pm::timeline::value(track,frame);
                if(track.parameter<2) item.stimulus[track.parameter==0 ? 4 : 7]=value;
                else {size_t axis=track.parameter-2;item.rect[axis]+=value;item.rect[axis+2]+=value;}
            }
            auto f=pm::flip(0);
            if(!result.submitted) result.firstToken=f.token;
            result.lastToken=f.token;result.lastQueueMs=f.queueMs;result.lastFlipMs=f.callMs;
            result.lastConfirmed=f.confirmed;
            shown.note(result.submitted++,f.time);     // the scripted display shows every frame at its time
        }
    } catch(...) {mockLiveTimeline.stop();drawItems.clear();drawCount=0;throw;}
    mockLiveTimeline.stop();drawItems.clear();drawCount=0;
    if(result.cancelled) mockTimelineCancelled.store(false);
    result.shown=shown.shown;result.late=shown.late;result.lateRefreshes=shown.lateRefreshes;
    result.firstLateSample=shown.late ? double(shown.firstLate) : NAN;
    result.meanSampleMs=shown.meanSampleSeconds()*1000;result.longestIntervalMs=shown.longest*1000;
    return result;
}
