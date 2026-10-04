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
//   PM_MOCK_MOUSE    "CLICK_AFTER,DX,DY" the mouse moves (DX, DY) per Mouse call
//                    and the left button is down once CLICK_AFTER frames have
//                    been flipped (-1: never). Default -1,0,0.
// Readback (OpenOptions::readback): a small software renderer stands in for the
// GPU, so GetImage returns real pixels and the readback checks run here too.
// It draws what those checks use and nothing else: the background, FillRect,
// and unrotated textures with nearest sampling, blended source-over into an
// 8-bit frame exactly as the engine's pipelines are configured. Other shapes,
// rotated textures and bilinear filtering leave the frame untouched.
// Test-only readbacks through diagnostic(): lastShapeRect holds the packed
// RGBA of texel (row 1, column 0) of the last uploaded image, lastShapeColor
// that of (row 0, column 1), so a transposed upload is visible to the tests.
#include "PsychMetalEngine.h"
#include "PsychMetalInternal.h"
#include "PsychMetalKeyboardQueue.h"

#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
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
struct Texture { pm::internal::ImageShape shape; std::vector<__fp16> texels; };
std::map<uint64_t, Texture> textures;
std::vector<__fp16> scratch;
pm::Rect4 probeA{}, probeB{};

// Readback.
struct DrawItem {
    bool texture = false;
    double rect[4] = {}, color[4] = {};       // FillRect: pixels, RGBA 0..1
    std::shared_ptr<Texture> image;           // texture: a snapshot taken when queued
    double src[4] = {}, dst[4] = {}, tint[4] = {};
};
bool readable = false, haveFrame = false;
std::vector<DrawItem> drawItems;
std::vector<uint8_t> frame;                   // RGBA, row-major
uint64_t frameToken = 0;

uint8_t toByte(double v) { return (uint8_t)std::lrint((v < 0 ? 0 : v > 1 ? 1 : v) * 255.0); }

// Source-over, as the engine's pipelines: rgb = src.rgb * a + dst.rgb * (1 - a).
void blendPixel(size_t x, size_t y, const double rgba[4]) {
    uint8_t *p = &frame[(y * (size_t)display.w + x) * 4];
    double a = rgba[3] < 0 ? 0 : rgba[3] > 1 ? 1 : rgba[3];
    for (int c = 0; c < 3; c++) p[c] = toByte(rgba[c] * a + (p[c] / 255.0) * (1 - a));
    p[3] = toByte(a + (p[3] / 255.0) * (1 - a));
}

void renderFrame(uint64_t token) {
    size_t W = (size_t)display.w, H = (size_t)display.h;
    frame.resize(W * H * 4);
    for (size_t i = 0; i < W * H; i++)
        for (int c = 0; c < 4; c++) frame[i * 4 + (size_t)c] = toByte(bg[c]);
    for (const DrawItem &it : drawItems) {
        const double *r = it.texture ? it.dst : it.rect;
        long x0 = std::lrint(std::ceil(r[0] - 0.5)), x1 = std::lrint(std::ceil(r[2] - 0.5));
        long y0 = std::lrint(std::ceil(r[1] - 0.5)), y1 = std::lrint(std::ceil(r[3] - 0.5));
        for (long y = y0 < 0 ? 0 : y0; y < y1 && y < (long)H; y++)
            for (long x = x0 < 0 ? 0 : x0; x < x1 && x < (long)W; x++) {
                double rgba[4];
                if (!it.texture) {
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
                }
                blendPixel((size_t)x, (size_t)y, rgba);
            }
    }
    haveFrame = true;
    frameToken = token;
}

int clickAfter = -1; double dx = 0, dy = 0, mouseX = 0, mouseY = 0; uint64_t flips = 0;

void readKeys(bool *kv, const bool *) { std::memset(kv, 0, 256); }
double keyClock() { return clockNow(); }
PMKeyboardQueue keyboard(readKeys, keyClock);
bool keyboardPinned = false;

void requireOpen() { if (!open || closing) fail("PsychMetal is not open."); }

uint64_t present(double when) {
    double now = clockNow();
    double target = when > now ? when : now;
    double next = std::isfinite(gridTime) ? gridTime + std::ceil((target - gridTime) / ifi - 1e-9) * ifi : target;
    if (next <= now) next += ifi;
    while (clockNow() < next) std::this_thread::sleep_for(std::chrono::microseconds(200));
    gridTime = next;
    gridSamples++;
    confirmed++;
    shapesEncoded += drawCount;
    drawCount = 0;
    uint64_t t = nextToken++;
    if (readable) renderFrame(t);
    drawItems.clear();
    pm::FrameRecord r{};
    r.token = t; r.projected = next; r.presented = next; r.status = 0; r.scheduledAt = now;
    r.callback = next; r.requestedTime = when > 0 ? when : NAN; r.presentRequest = NAN; r.committedAt = now;
    history.push_back(r);
    if (history.size() > 16384) history.erase(history.begin());
    flips++;
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
const char *pm::version() noexcept { return pm::kEngineVersion; }
void pm::prepareApp() { pm::closeSession(); prepared = true; }

pm::OpenResult pm::openSession(const pm::OpenOptions &o) {
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
    clickAfter = click; dx = mx; dy = my; mouseX = display.w / 2; mouseY = display.h / 2; flips = 0;
    ifi = 1.0 / hz; gridTime = NAN; gridSamples = 0; confirmed = 0;
    startup.clear(); history.clear(); drawCount = 0; preparedToken = 0;
    prefetch = false; displaySync = o.displaySync; waitConfirm = o.waitForConfirm;
    readable = o.readback; haveFrame = false; frameToken = 0; drawItems.clear();
    open = true; closing = false; session++;
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
    history.clear(); confirmed = 0; flips = 0;   // the mouse script counts stimulus frames
    return startup;
}
void pm::closeSession() {
    open = false; closing = true; prepared = false; textures.clear(); drawCount = 0; preparedToken = 0;
    readable = false; haveFrame = false; drawItems.clear(); std::vector<uint8_t>().swap(frame);
}

// ---- presentation -------------------------------------------------------------------

pm::FlipResult pm::flip(double when) {
    double began = clockNow();
    if (when < 0) fail("Target must be nonnegative.");
    requireOpen();
    if (preparedToken) fail("Present or cancel the prepared frame before Flip.");
    double queued = clockNow();
    uint64_t t = present(when);
    pm::FlipResult r{};
    r.time = gridTime; r.confirmed = true; r.slipRefreshes = 0; r.gridPeriod = ifi;
    r.queueMs = (queued - began) * 1000; r.returnTime = clockNow(); r.callMs = (r.returnTime - began) * 1000;
    r.token = t;
    return r;
}
uint64_t pm::queueFrame(std::optional<double> when) {
    requireOpen();
    if (preparedToken) fail("Present or cancel the prepared frame before Flip.");
    return present(when ? *when : 0);
}
pm::ScheduleResult pm::waitScheduled(uint64_t token, std::optional<double>) {
    for (const auto &r : history)
        if (r.token == token) return {r.presented, true, true, 0, ifi};
    fail("Unknown or expired frame token.");
}
uint64_t pm::prepareFlip() {
    requireOpen();
    if (preparedToken) fail("A frame is already prepared; call PresentNow before preparing another.");
    preparedToken = nextToken++;
    if (readable) renderFrame(preparedToken);
    drawItems.clear();
    drawCount = 0;
    return preparedToken;
}
pm::PresentResult pm::presentNow() {
    if (!preparedToken) fail("No prepared frame; call PrepareFlip first.");
    preparedToken = 0;
    double t = clockNow();
    return {t, 0.01};
}
void pm::setDisplaySync(bool on) { if (!open) fail("PsychMetal is not open."); displaySync = on; }
void pm::setPrefetchDrawable(bool on) { if (!open) fail("PsychMetal is not open."); prefetch = on; }

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
    t.shape = pm::internal::packImage(image, t.texels);
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
    it->second.shape = pm::internal::packImage(image, it->second.texels);
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
    if (readable)
        for (size_t k = 0; k < n; k++) {
            if (at(angle, k, 0) != 0 || at(filter, k, 0) != 0) continue;   // unrotated, nearest only
            DrawItem it;
            it.texture = true;
            it.image = std::make_shared<Texture>(textures[(uint64_t)at(handle, k, 0)]);
            for (size_t c = 0; c < 4; c++) { it.src[c] = at(src, k, c); it.dst[c] = at(dst, k, c); it.tint[c] = at(tint, k, c); }
            drawItems.push_back(it);
        }
    drawCount += n;
    texturesDrawn += n;
}
void pm::closeTexture(uint64_t handle) {
    if (!textures.erase(handle)) fail("Invalid or expired texture handle.");
}

pm::ImageRegion pm::checkImageRect(const std::optional<pm::Rect4> &rect) {
    requireOpen();
    if (!readable) fail("GetImage requires a window opened with readback.");
    if (!rect) return {0, 0, (size_t)display.w, (size_t)display.h};
    const pm::Rect4 &r = *rect;
    for (double v : r)
        if (!std::isfinite(v) || v != std::floor(v))
            fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    if (r[0] < 0 || r[1] < 0 || r[2] <= r[0] || r[3] <= r[1] || r[2] > display.w || r[3] > display.h)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    return {(size_t)r[0], (size_t)r[1], (size_t)(r[2] - r[0]), (size_t)(r[3] - r[1])};
}

void pm::getImage(const pm::ImageRegion &g, const pm::MutableByteView &out) {
    requireOpen();
    if (!readable) fail("GetImage requires a window opened with readback.");
    if (!g.width || !g.height || g.x + g.width > (size_t)display.w || g.y + g.height > (size_t)display.h)
        fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
    if (!out.data || out.ndim != 3 || out.shape[0] != g.height || out.shape[1] != g.width || out.shape[2] != 3)
        fail("Image output buffer does not match the request.");
    if (!haveFrame) fail("GetImage needs a frame; Flip first.");
    if (frameToken != nextToken - 1) fail("The last frame was not copied; there is nothing to read.");
    for (size_t y = 0; y < g.height; y++)
        for (size_t x = 0; x < g.width; x++) {
            const uint8_t *p = &frame[((g.y + y) * (size_t)display.w + g.x + x) * 4];
            uint8_t *q = out.data + (ptrdiff_t)y * out.strides[0] + (ptrdiff_t)x * out.strides[1];
            for (int c = 0; c < 3; c++) q[c * out.strides[2]] = p[c];
        }
}

// ---- display modes, cursor, input ------------------------------------------------------

std::vector<pm::DisplayMode> pm::modes(double si) {
    if (si < 0) si = 0;
    if (si != std::floor(si) || si >= 1) fail("Screen index is out of range.");
    readDisplay();
    return {{display.w, display.h, display.w, display.h, display.hz}, {1024, 768, 1024, 768, 60}};
}
void pm::setMode(double si, double w, double h) {
    if (open) fail("Close the PsychMetal window before changing the display mode.");
    auto m = pm::modes(si);
    for (auto &d : m) if (d.pointWidth == w && d.pointHeight == h) return;
    failWith(pm::kErrMode, "No display mode is %g x %g points on that display.", w, h);
}
void pm::setCursorVisible(bool) {}

pm::MouseState pm::mouse() {
    if (!open) fail("Mouse requires an open PsychMetal window.");
    mouseX += dx; mouseY += dy;
    pm::MouseState m{};
    m.x = mouseX; m.y = mouseY;
    m.buttons = {clickAfter >= 0 && flips >= (uint64_t)clickAfter, false, false};
    return m;
}
pm::KeyState pm::keys() {
    pm::KeyState k{};
    k.anyDown = false; k.secs = clockNow(); k.securePid = 0;
    return k;
}
pm::KbQueueStatus pm::kbQueueStatus() {
    auto s = keyboard.stats();
    return {s.created, s.running, s.interval, s.lastScanInterval, s.maxScanInterval,
            (uint64_t)s.scans, (uint64_t)s.dropped, 0};
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
