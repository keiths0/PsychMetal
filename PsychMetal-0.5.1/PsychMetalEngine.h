// PsychMetalEngine.h — host-neutral engine for PsychMetal 0.5.1.
// SPDX-License-Identifier: MIT
//
// Plain C++17. It never includes mex.h, Python.h or an Objective-C header, so
// every front end can include it:
//
//   PsychMetalMex.cpp     MATLAB / Octave front end -> PsychMetalCore.mexmaca64 / .mex
//   PsychMetalPython.cpp  Python front end (C API)   -> psychmetal/_psychmetal*.so
//   PsychMetalEngine.mm   the implementation: Metal, AppKit, CoreGraphics
//
// Boundary rules
//   1. Validation is shared, not duplicated. A front end checks only that a host
//      value has the right kind (a real numeric scalar, a dense array) and then
//      applies the shared scalar conventions below (checkFinite, checkUnsigned),
//      so both hosts word them identically. Everything else (ranges, state,
//      capacity, per-element checks) happens inside the engine functions.
//   2. Failures throw pm::Error{id, message}. The engine never calls a host
//      error function and never longjmps. Front ends catch at one boundary.
//   3. Arrays cross as ArrayView: pointer, element type, logical shape, byte
//      strides. The engine never assumes column- or row-major order, so MATLAB
//      and numpy arrays are both read in place.
//   4. PM_BLOCKING marks calls that can wait on the display, the GPU, a condition
//      variable, a thread join or the main thread. A front end with a global
//      interpreter lock must not hold it across those calls; the Python front
//      end releases it around every engine call, which is simpler and cheap.
//   5. One caller thread at a time. The engine synchronises against its own
//      Metal and keyboard threads, not against concurrent host calls.
//   6. No engine callback re-enters the host. Warnings go through HostHooks::warn,
//      which is called on the caller thread, inside the engine call.

#ifndef PSYCHMETAL_ENGINE_H
#define PSYCHMETAL_ENGINE_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

// Marker only; expands to nothing.
#define PM_BLOCKING

namespace pm {

// ---------------------------------------------------------------------------
// Version and errors
// ---------------------------------------------------------------------------

// Engine version. Both front ends return it for 'Version'; PsychMetal.m and the
// psychmetal package refuse to run against a different value.
inline constexpr const char *kEngineVersion = "0.5.1";

// Every error and warning identifier the engine emits.
inline constexpr const char *kErrGeneral      = "PsychMetal:Error";
inline constexpr const char *kErrMetal        = "PsychMetal:Metal";
inline constexpr const char *kErrScreen       = "PsychMetal:Screen";
inline constexpr const char *kErrMode         = "PsychMetal:Mode";
inline constexpr const char *kErrDrawableSize = "PsychMetal:DrawableSize";
inline constexpr const char *kErrPipeline     = "PsychMetal:Pipeline";
inline constexpr const char *kErrShader       = "PsychMetal:Shader";
inline constexpr const char *kErrWindowOrigin = "PsychMetal:WindowOrigin";
inline constexpr const char *kErrNative       = "PsychMetal:NativeException";  // front ends: std::exception
inline constexpr const char *kWarnRefresh        = "PsychMetal:UnknownRefreshRate";
inline constexpr const char *kWarnDisplayMapping = "PsychMetal:DisplayMapping";
inline constexpr const char *kWarnDisplayCapture = "PsychMetal:DisplayCapture";
inline constexpr const char *kWarnDrainTimeout   = "PsychMetal:DrainTimeout";

class Error : public std::runtime_error {
public:
    Error(std::string id, const std::string &message)
        : std::runtime_error(message), id_(std::move(id)) {}
    explicit Error(const std::string &message) : Error(kErrGeneral, message) {}
    const std::string &id() const noexcept { return id_; }
private:
    std::string id_;
};

// ---------------------------------------------------------------------------
// Shared scalar conventions for the front ends
// ---------------------------------------------------------------------------

// "<name> must be a real numeric scalar." Front ends call this when a host value
// is not a real, dense, one-element number.
[[noreturn]] void failNotScalar(const char *name);
// Returns v; throws "<name> must be finite." otherwise.
double checkFinite(double v, const char *name);
// checkFinite, then "<name> must be a nonnegative integer in range." unless v is
// an integer in [0, maximum].
uint64_t checkUnsigned(double v, const char *name, uint64_t maximum);
// Largest integer a double represents exactly; the ceiling for handles and tokens.
inline constexpr uint64_t kMaxId = 9007199254740991ULL;

// ---------------------------------------------------------------------------
// Host hooks and lifecycle
// ---------------------------------------------------------------------------

struct HostHooks {
    // Replaces mexWarnMsgIdAndTxt. Called on the caller thread during an engine call.
    void (*warn)(const char *id, const char *message) = nullptr;
    // Replace mexLock / mexUnlock: called when the engine starts or stops holding
    // state that asynchronous callbacks reference (a window, a keyboard queue).
    void (*pinModule)() = nullptr;
    void (*unpinModule)() = nullptr;
};
void installHostHooks(const HostHooks &hooks);

// Release every native resource. Idempotent and noexcept. The MEX front end
// registers it with mexAtExit; the Python front end with atexit.
PM_BLOCKING void shutdown() noexcept;

// ---------------------------------------------------------------------------
// Array views
// ---------------------------------------------------------------------------

// Other: any element type the engine does not accept (complex, sparse, int16,
// float16, ...). Passing it lets the engine report its own message.
enum class ScalarType : uint8_t { Float64, Float32, UInt8, Bool, Other };

// A read-only strided view. Strides are in bytes. Logical shapes:
//   image      (H, W) or (H, W, C), C in {1, 3, 4}
//   per-shape  (N) for kind and param; (N, 4) for rect, color and extra
// A MATLAB 4xN matrix and a numpy C-contiguous (N, 4) array occupy the same
// memory: both are (N, 4) with strides (4*8, 8).
struct ArrayView {
    const void *data = nullptr;
    ScalarType type = ScalarType::Other;
    int ndim = 0;
    std::array<size_t, 3> shape{};
    std::array<ptrdiff_t, 3> strides{};
    size_t count() const noexcept {
        if (ndim <= 0) return 0;
        size_t n = 1;
        for (int i = 0; i < ndim; i++) n *= shape[size_t(i)];
        return n;
    }
};

// A writable strided view of doubles, allocated by the front end.
struct MutableArrayView {
    double *data = nullptr;
    int ndim = 0;
    std::array<size_t, 3> shape{};
    std::array<ptrdiff_t, 3> strides{};
};

// A writable strided view of bytes, allocated by the front end.
struct MutableByteView {
    uint8_t *data = nullptr;
    int ndim = 0;
    std::array<size_t, 3> shape{};
    std::array<ptrdiff_t, 3> strides{};
};

using Rect4 = std::array<double, 4>;

// ---------------------------------------------------------------------------
// Main thread (no MEX command)
// ---------------------------------------------------------------------------

// True on the process main thread (the AppKit thread).
bool onMainThread() noexcept;
// Service AppKit on the main thread for up to `seconds`, returning early once
// queued events are drained. Key events are discarded: the engine polls the
// keyboard and an unhandled keyDown would beep. Throws off the main thread.
// Python's run(threaded=True) parks the main thread in a loop of these calls
// while the experiment runs on a worker, which is how MATLAB hosts the engine.
PM_BLOCKING void serviceMainRunLoop(double seconds);

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

// 'Version'
const char *version() noexcept;

// 'PrepareApp'. Closes any open session, then activates the host as a regular app.
PM_BLOCKING void prepareApp();

struct OpenOptions {
    double screenIndex = 0;          // CoreGraphics active-display index; -1 = last
    uint64_t drawableCount = 3;      // 2 or 3
    bool waitForConfirm = true;
    bool displaySync = true;
    bool captureDisplay = true;
    std::optional<double> refreshHz; // 20..1000; overrides the reported rate
    // Diagnostic sessions only. Drawables are created readable and every frame's
    // drawable is copied before it is presented, so GetImage can return it. Off,
    // the layer is framebuffer-only and no frame is copied.
    bool readback = false;
};
struct OpenResult {
    double pixelWidth, pixelHeight;  // render size in pixels
    double ifi;                      // nominal refresh period, seconds
    double pointWidth, pointHeight;  // display size in points
    uint64_t sessionToken;
};
// 'Open'. Requires prepareApp().
PM_BLOCKING OpenResult openSession(const OpenOptions &options);

// One startup presentation attempt: a row of the StartupHistory matrix.
struct StartupRecord {
    uint64_t token;
    int status;             // 0 confirmed, 1 missing, 2 pending, 3 GPU error, 4 no drawable
    double presentedTime;
    double callbackTime;
    int gpuDone;
    double committedTime;
};
// 'StartupHistory'
std::vector<StartupRecord> startupHistory();
// 'ConfirmStartup'. Returns the startup history; on failure throws, and
// startupHistory() still returns the attempts.
PM_BLOCKING std::vector<StartupRecord> confirmStartup();

// 'Close'. Idempotent.
PM_BLOCKING void closeSession();

// ---------------------------------------------------------------------------
// Presentation
// ---------------------------------------------------------------------------

struct FlipResult {
    double time;           // confirmed presentation time, else projected
    bool confirmed;
    double slipRefreshes;  // slip of the previous confirmed frame, whole refreshes
    double gridPeriod;     // measured period if available, else nominal
    double queueMs;        // time spent in enqueue
    double callMs;         // whole call
    double returnTime;
    uint64_t token;
};
// 'Flip'. when == 0 means as soon as possible; when < 0 throws.
PM_BLOCKING FlipResult flip(double when = 0);

// 'Queue'. A supplied `when` counts as a target even when it is 0.
PM_BLOCKING uint64_t queueFrame(std::optional<double> when);

struct ScheduleResult {
    double time;           // confirmed presentation time, else projected
    bool scheduled;        // the MEX column 2 reports !scheduled as 2
    bool confirmed;
    double slipRefreshes;
    double gridPeriod;
};
// 'WaitScheduled'. Times out two seconds after max(now, when).
PM_BLOCKING ScheduleResult waitScheduled(uint64_t token, std::optional<double> when);

// 'PrepareFlip' / 'PresentNow'
PM_BLOCKING uint64_t prepareFlip();
struct PresentResult { double time; double callMs; };
PresentResult presentNow();

// 'SetDisplaySync'
PM_BLOCKING void setDisplaySync(bool enabled);

// 'PrefetchDrawable'
void setPrefetchDrawable(bool enabled);

// ---------------------------------------------------------------------------
// Refresh grid
// ---------------------------------------------------------------------------

struct GridAnchor { double anchor; double period; double samples; };
// 'GridAnchor'. anchor is NaN before the first confirmed frame.
GridAnchor gridAnchor();
// 'NextPhase'. NaN before the first confirmed frame.
double nextPhase(double after, double phase);
// 'NextRefresh'
double nextRefresh(double after);

struct WaitToDrawResult { double wokeAt; double lead; double deadline; };
// 'WaitToDraw'. budget >= 0 seconds.
PM_BLOCKING WaitToDrawResult waitToDraw(double target, double budget);

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// 'SetBackgroundColor'. Components 0..1.
void setBackgroundColor(double r, double g, double b, double a);

// 'AddShapes'. kind and param (N); rect, color and extra (N, 4); all Float64.
void addShapes(const ArrayView &kind, const ArrayView &param,
               const ArrayView &rect, const ArrayView &color, const ArrayView &extra);

// 'MakeTexture' / 'UpdateTexture'. Image (H, W[, C]) of Float64, Float32, UInt8
// or Bool; H, W in 1..16384; C in {1, 3, 4}. UInt8 scales by 1/255.
uint64_t makeTexture(const ArrayView &image);
void updateTexture(uint64_t handle, const ArrayView &image);

// 'DrawTextures'. handle, angle and filterMode (N); src, dst and tint (N, 4); all
// Float64. src is normalised, dst in pixels, angle in radians about the
// destination centre, tint 0..1, filterMode 0 nearest or 1 bilinear. Drawn in
// order. Every entry is checked before any is queued, so a rejected call leaves
// the frame as it was.
void drawTextures(const ArrayView &handle, const ArrayView &src, const ArrayView &dst,
                  const ArrayView &angle, const ArrayView &tint, const ArrayView &filterMode);

// 'CloseTexture'
void closeTexture(uint64_t handle);

// 'GetImage'. The frame most recently submitted by Flip, Queue or PrepareFlip,
// read from a copy of its drawable made after rendering and before presentation:
// what the GPU handed to the display, not a second rendering. Requires a session
// opened with OpenOptions::readback. checkImageRect validates so a front end
// never allocates for a bad request: rect is [left top right bottom] in whole
// pixels inside the render rectangle, and no rect is the whole frame. getImage
// waits up to two seconds for that frame's GPU work, then fills (H, W, 3) RGB
// bytes in the front end's layout.
struct ImageRegion { size_t x, y, width, height; };
ImageRegion checkImageRect(const std::optional<Rect4> &rect);
PM_BLOCKING void getImage(const ImageRegion &region, const MutableByteView &out);

// 'NoiseValues'. checkNoiseRequest validates so a front end never allocates for a
// bad request; noiseValues then fills (H, W) or (H, W, 3) in the front end's
// layout with exactly the values the GPU noise shape draws.
struct NoiseRequest {
    double width, height;   // integers 1..16384
    double seed;            // integer 0..16777215
    bool normal;
    bool colour;
    std::array<double, 3> mean;
    double spread;          // >= 0
};
void checkNoiseRequest(const NoiseRequest &request);
void noiseValues(const NoiseRequest &request, const MutableArrayView &out);

// ---------------------------------------------------------------------------
// Display modes and cursor
// ---------------------------------------------------------------------------

struct DisplayMode {
    double pointWidth, pointHeight, pixelWidth, pixelHeight, refreshHz;
};
// 'Modes'. The current mode first. screenIndex -1 = last display.
std::vector<DisplayMode> modes(double screenIndex);
// 'SetMode'. Requires a closed window; picks the matching point size with the
// most pixels. (The MEX front end still returns 1.)
void setMode(double screenIndex, double pointWidth, double pointHeight);
// 'Cursor'
void setCursorVisible(bool visible);

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// Index k of every 256-element key array is HID usage k+1 (MATLAB keyCode(k+1)).
// KeyEvent::key is the HID usage (1-based).

struct MouseState { double x, y; std::array<bool, 3> buttons; };  // left, right, centre
// 'Mouse'. Pixel coordinates on the presentation display.
MouseState mouse();

struct KeyState {
    bool anyDown;
    double secs;
    std::array<bool, 256> down;
    double securePid;   // 0 inactive, -1 active (owner not queried)
};
// 'Keys'
KeyState keys();

struct KbQueueStatus {
    bool created, running;
    double pollInterval, lastScanInterval, maxScanInterval;
    uint64_t scans, dropped;
    double secureInputPID;
};
// 'KbQueueStatus'
KbQueueStatus kbQueueStatus();
// 'KbQueueCreate'. mask nonzero = watched, all finite; interval 0.001..0.1 s.
void kbQueueCreate(const std::array<double, 256> &mask, double interval);
// 'KbQueueRelease' / 'KbQueueStart' / 'KbQueueStop' / 'KbQueueFlush'
PM_BLOCKING void kbQueueRelease();
void kbQueueStart();
PM_BLOCKING void kbQueueStop();
void kbQueueFlush();

struct KeyEvent { double time; int key; bool pressed; };
struct KbEvents { std::vector<KeyEvent> events; uint64_t dropped; };
// 'KbQueueGetEvents'
KbEvents kbQueueGetEvents();

struct KbCheck {
    bool pressed;
    std::array<double, 256> firstPress, firstRelease, lastPress, lastRelease;
};
// 'KbQueueCheck'
KbCheck kbQueueCheck();

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

// 'Now'. CACurrentMediaTime, the clock of every timestamp here.
double now() noexcept;
// 'Wait'. Sleep, then spin, until the absolute deadline; returns the time on return.
PM_BLOCKING double waitUntil(double deadline);

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

// One presented frame: a row of the Diagnostic history matrix, in column order.
struct FrameRecord {
    uint64_t token;
    double projected;
    double presented;
    int status;            // done ? status : 2
    double scheduledAt;
    double callback;
    int commandStatus;
    double requestedTime;
    double gpuStart, gpuEnd;
    double presentRequest;
    double presentCallMs;
    double committedAt;
    double drawableAcquireMs, encodeMs, prefetchMs;
};

// The Diagnostic summary; field names and order are those of the MATLAB struct.
struct DiagnosticSummary {
    double confirmedPresentations, missingPresentedTimes;
    double lastTargetErrorMs, lastConfirmDelayMs, appKitScreenIndex;
    double cgDisplayID, renderWidth, renderHeight;
    double drawableWidth, drawableHeight, inFlight;
    double requestedDrawableCount, drawableCountReadback;
    std::string hostBundleIdentifier;
    double activationPolicyBefore, activationPolicyAfter;
    bool activationPolicyPromotionAttempted, activationPolicyPromotionSucceeded;
    std::string macOSVersion, processName;
    double machTimebaseHz, machTickNanoseconds;
    bool waitForConfirm;
    double measuredRefreshHz, gridSamples, directNoDrawable, directConfirmTimeouts;
    double leadEstimateMs, pipelineEstimateMs, gpuEstimateMs;
    bool displaySyncEnabled, displayCaptured, readbackEnabled;
    double modePointWidth, modePixelWidth, largestModePixelWidth;
    double shapesAppended, shapesEncoded, shapeEncodeCalls;
    double texturesCreated, texturesDrawn, textureAllocations, textureUpdates;
    double lastTextureUploadMs;
    Rect4 lastShapeRect, lastShapeColor;
    double lastShapeKind;
    Rect4 windowFrame, viewBounds, layerFrame;
    Rect4 screenFrame, screenVisibleFrame, screenSafeAreaInsets;  // insets: top, left, bottom, right
    Rect4 cgDisplayBounds;
    double backingScaleFactor;
    double keyScanMaxMs, secureQueryMaxMs, keyScanMeanMs, secureQueryMeanMs, keyReadCount;
};

struct DiagnosticReport {
    std::vector<FrameRecord> history;   // user frames since ConfirmStartup, newest 16384
    DiagnosticSummary summary;
};
// 'Diagnostic'. Waits up to two seconds for in-flight frames first.
PM_BLOCKING DiagnosticReport diagnostic();

}  // namespace pm

#endif  // PSYCHMETAL_ENGINE_H
