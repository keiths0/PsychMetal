// PsychMetalEngine.h — host-neutral engine for PsychMetal 0.7.1.
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
inline constexpr const char *kEngineVersion = "0.7.1";

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
inline constexpr const char *kWarnInputMonitoring = "PsychMetal:InputMonitoring";

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

// A writable strided view of 16-bit values, allocated by the front end. Strides
// are in bytes, as everywhere.
struct MutableWordView {
    uint16_t *data = nullptr;
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
    bool displayLink = false;       // CAMetalDisplayLink; macOS 14 / iOS 17+
    bool waitForConfirm = true;
    bool displaySync = true;
    bool captureDisplay = true;
    std::optional<double> refreshHz; // 20..1000; overrides the reported rate
    // Diagnostic sessions only. Drawables are created readable and every frame's
    // drawable is copied before it is presented, so GetImage can return it. Off,
    // the layer is framebuffer-only and no frame is copied.
    bool readback = false;
    // Bits per channel of the drawable: 8 (BGRA8) or 10 (BGR10A2).
    uint64_t bitDepth = 8;
};
struct OpenResult {
    double pixelWidth, pixelHeight;  // render size in pixels
    double ifi;                      // nominal refresh period, seconds
    double pointWidth, pointHeight;  // display size in points
    uint64_t sessionToken;
};
// 'Open'. Requires prepareApp().
// Front ends use this default; explicit OpenOptions still select either backend.
bool defaultDisplayLink() noexcept;
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
// 'Flip'. when == 0 means as soon as possible; when < 0 throws. A frame that was
// submitted but never shown is not an error: flip returns its projected time, and
// flipStatus says what became of it. A GPU failure, no drawable and a
// confirmation timeout still throw.
PM_BLOCKING FlipResult flip(double when = 0);

// 'FlipStatus'. What the display has reported, as of now, of the last frame
// submitted by flip: shown (confirmed), never shown (dropped), or nothing yet
// (neither), which is how flip leaves a frame unless the session waits for
// confirmation; the next flip makes it about the next frame. droppedFrames
// counts every frame of the session the display has reported never shown,
// queued frames included, whenever the report arrived.
struct FlipStatus { bool confirmed, dropped; uint64_t droppedFrames; };
FlipStatus flipStatus();

// 'QueueFlip' / 'QueueResults' / 'QueueCancel'. Frames queued ahead. queueFlip
// renders what is drawn now into a store and returns at once; a presenter thread
// hands the frame to the display for the refresh at or after `when`, which must
// be later than that of the frame queued before it. The caller may therefore run
// ahead of the display, by up to `capacity` frames (as many as fit in a gigabyte,
// 2 to 64); with all stores in use queueFlip waits for one. Frames are shown in
// order and none is skipped: a late one is shown at the next refresh. flip waits
// for queued frames to be handed over before it submits its own.
// queueResults reports the frames queued since the last report that have been
// shown or dropped, or with wait every one of them, waiting until each is, or
// two seconds past the last one's time. A frame is reported once, with its
// outcome; one still pending after that wait is reported as pending and again
// by the next call, until ten seconds past its time, when it is given up on.
// status: 0 shown, 1 dropped, 2 still pending, 3 GPU error, 4 no drawable,
// 5 cancelled. A frame whose store the GPU failed to render is not shown. queueCancel abandons frames not yet handed to the display and
// returns how many.
struct QueueResult { uint64_t token; double pending, capacity; };
PM_BLOCKING QueueResult queueFlip(double when);
struct QueuedFrame { uint64_t token; double requested, presented; int status; };
PM_BLOCKING std::vector<QueuedFrame> queueResults(bool wait);
uint64_t queueCancel();

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
// 'CheckStimulus': 15 doubles: kind (0 grating, 1 noise), mean RGB (0..1),
// contrast (0..1), cycles/pixel (0..0.5), orientation/phase degrees, seed,
// grain pixels, colour, normal, opacity, aperture (0 rect,1 ellipse,2 Gaussian), sigma.
// Contrast is amplitude/mean; noise uses mean + mean*contrast*deviate, clamped.
std::array<double,15> checkStimulus(const ArrayView &parameters);
// 'DrawStimulus': dst (4 doubles); optional one-channel mask texture handle.
// The mask multiplies procedural aperture coverage, independent of noise scale.
void drawStimulus(const ArrayView &parameters, const ArrayView &dst, uint64_t mask);

void addShapes(const ArrayView &kind, const ArrayView &param,
               const ArrayView &rect, const ArrayView &color, const ArrayView &extra);

// 'MakeTexture' / 'UpdateTexture'. Image (H, W[, C]) of Float64, Float32, UInt8
// or Bool; H, W in 1..16384; C in {1, 3, 4}. A UInt8 value v is v / 255 and true
// is 1; both are stored in 8-bit textures, float images as half floats.
uint64_t makeTexture(const ArrayView &image);
void updateTexture(uint64_t handle, const ArrayView &image);

// 'DrawTextures'. handle, angle and filterMode (N); src, dst and tint (N, 4); all
// Float64. src is normalised, dst in pixels, angle in radians about the
// destination centre, tint 0..1, filterMode 0 nearest or 1 bilinear. Drawn in
// order. Every entry is checked before any is queued, so a rejected call leaves
// the frame as it was.
void drawTextures(const ArrayView &handle, const ArrayView &src, const ArrayView &dst,
                  const ArrayView &angle, const ArrayView &tint, const ArrayView &filterMode);

// 'UpdateTexture' with a position. Replaces the part of the texture whose top
// left is (x, y), in whole texture pixels, with `image`, which must have the
// texture's kind (uint8 or logical, or float) and channel count and lie inside
// it. The texture is changed in place, so it must not be in a frame that is
// queued; a frame already submitted is waited for, for up to two seconds.
PM_BLOCKING void updateTextureRegion(uint64_t handle, const ArrayView &image, double x, double y);

// 'CloseTexture'
void closeTexture(uint64_t handle);

// 'BlendMode'. How shapes and textures queued from now on combine with what is
// already drawn: 0 source-over (the default), 1 additive (source times its
// alpha is added), 2 copy (the source replaces it, alpha included; pixels a shape
// or mask does not cover at all are left alone, and partly covered ones are
// written with their coverage as alpha). Into an offscreen window, copy stores
// the colour multiplied by its alpha, as that window holds everything. Reset by
// Open.
void setBlendMode(uint64_t mode);

// 'Clip'. Draws queued from now on are confined to rect, [left top right bottom]
// in whole pixels of what they are drawn into; no rect ends it. Reset by Open.
void setClip(const std::optional<Rect4> &rect);

// 'OpenOffscreen' / 'SetTarget'. An offscreen window is a texture that can be
// drawn into: half-float RGBA, width x height whole pixels up to 16384, opened
// holding the colour rgba (0..1, alpha included). What it holds is colour
// multiplied by alpha, and it is drawn as that: drawing it gives what the draws
// made into it would have given directly, and a tint's alpha scales all of it,
// in every blend mode. Its handle is a texture handle,
// for drawTextures and closeTexture; updateTexture refuses it. setTarget(handle)
// sends every draw queued from then on into that offscreen window, in its own
// pixel coordinates, adding to what it holds; setTarget(0) returns to the window.
// Draws reach an offscreen window when the target changes or a frame is made.
// It cannot be drawn into itself, nor drawn into again while the window has
// draws of it waiting for a Flip. Closing the target returns to the window.
uint64_t openOffscreen(double width, double height, const Rect4 &rgba);
void setTarget(uint64_t handle);

// 'DrawPolygon'. points (N, 2) Float64 in pixels, N in 3..4096, closed
// automatically; colour rgba 0..1. pen 0 fills it by the even-odd rule; pen > 0
// strokes its outline that many pixels wide, centred on the edges. Antialiased,
// drawn in order with everything else.
void drawPolygon(const ArrayView &points, const Rect4 &rgba, double pen);

// 'Gamma' / 'GammaTable'. Linearization. With either set, every colour and
// texture value is linear light: drawing and blending happen in a half-float
// target, and one more pass writes the display values. setGamma: the display
// value is the linear value raised to these exponents (1 / the display's gamma),
// each 0.05..20; (1, 1, 1) turns linearization off. setGammaTable: an (N, 3)
// Float64 table, N in 2..4096, of display values 0..1 for N evenly spaced linear
// values 0..1, read with linear interpolation. Reset by Open.
void setGamma(double r, double g, double b);
void setGammaTable(const ArrayView &table);

// 'TextBounds' / 'DrawText'. One line of UTF-8 text in the named font (empty:
// Helvetica) at `size` pixels. drawText queues it with its top left at (x, y) in
// pixels and colour rgba 0..1, drawn in order with shapes and textures. A line
// is rendered the first time it is drawn and its rendering kept, with those of
// polygons: 256 of them or 256 MB, the ones wanted longest ago making way.
// textBounds renders nothing.
struct TextBounds { double width, height, ascent; };   // pixels
TextBounds textBounds(const std::string &utf8, const std::string &font, double size);
TextBounds drawText(const std::string &utf8, const std::string &font, double size, double x, double y,
                    const Rect4 &rgba);

// 'GetImage'. The frame most recently submitted by Flip, Queue or PrepareFlip,
// read from a copy of its drawable made after rendering and before presentation:
// what the GPU handed to the display, not a second rendering. Requires a session
// opened with OpenOptions::readback. checkImageRect validates so a front end
// never allocates for a bad request: rect is [left top right bottom] in whole
// pixels inside the render rectangle, and no rect is the whole frame. getImage
// waits up to two seconds for that frame's GPU work, then fills (H, W, 3) RGB
// bytes in the front end's layout.
// An 8-bit window fills bytes 0..255 with getImage; a 10-bit window fills 16-bit
// values 0..1023 with getImage16. ImageRegion::bits says which.
struct ImageRegion { size_t x, y, width, height; int bits; };
ImageRegion checkImageRect(const std::optional<Rect4> &rect);
PM_BLOCKING void getImage(const ImageRegion &region, const MutableByteView &out);
PM_BLOCKING void getImage16(const ImageRegion &region, const MutableWordView &out);

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
// most pixels.
void setMode(double screenIndex, double pointWidth, double pointHeight);
// 'Cursor'
void setCursorVisible(bool visible);

// 'LinkInfo'. The DisplayPort link to the presentation display, read from the IO
// registry, and what the open window's picture needs. Every number is NaN when
// the link could not be identified (a built-in panel, HDMI, an unknown system).
struct LinkInfo {
    double lanes;        // lanes in use, summed over streams
    double laneGbps;     // signalling rate per lane
    double payloadGbps;  // what the link carries after line coding
    double pixelGbps;    // the window's pixels at its refresh rate and bit depth, without blanking
    double compressed;   // 1: the link cannot carry the picture uncompressed; 0: it can, with room; NaN: unknown
};
LinkInfo linkInfo();

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// Index k of every 256-element key array is HID usage k+1 (MATLAB keyCode(k+1)).
// KeyEvent::key is the HID usage (1-based).

struct MouseState { double x, y; std::array<bool, 3> buttons; };  // left, right, centre
// 'Mouse'. Pixel coordinates on the presentation display.
MouseState mouse();
// 'SetMouse'. Move the cursor to (x, y), in the same pixel coordinates, inside the
// window. Movement of the mouse counts again at once.
void setMouse(double x, double y);

// 'MouseEvents'. Button presses and releases with the times their events carry:
// button 1 left, 2 right, 3 centre; x, y in window pixels. The first call in a
// session starts listening and returns nothing; each later call returns the
// events since the one before, and how many were lost to a full buffer (4096).
struct MouseEvent { double time; int button; bool pressed; double x, y; };
struct MouseEvents { std::vector<MouseEvent> events; uint64_t dropped; };
MouseEvents mouseEvents();

// 'TouchEvents'. Fingers on a touch screen or a trackpad, with the times their
// events carry: each finger's going down (phase 0), every movement the system
// sampled (1), and its lifting (2) or being taken over by the system (3). finger
// numbers the fingers that are down, from 1, and a number is free again once its
// finger has lifted. x, y are in window pixels: on a touch screen where the
// finger is, on a trackpad its place on the trackpad as a place in the window,
// the trackpad's corners being the window's. Each call returns the events since
// the one before, or since the window opened, and how many were lost to a full
// buffer (8192).
//
// On an iPhone or iPad fingers are also the mouse and one key, so that a program
// written for those runs: one finger is the pointer that mouse() reports, a
// second finger down is button 1 (mouse() and mouseEvents()), and a third is the
// Escape key. On a Mac the trackpad already drives the pointer and its click is
// the button; the contacts are reported besides. There the first call starts
// listening and returns nothing, as MouseEvents does, and contacts arrive only
// while the pointer is over the window and the application is the active one.
struct TouchEvent { double time; int finger; int phase; double x, y; };
struct TouchEvents { std::vector<TouchEvent> events; uint64_t dropped; };
TouchEvents touchEvents();

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
    bool eventTimestamps;       // a listener for key events is attached; else every time is a poll's
    uint64_t eventStamped;      // transitions recorded with the event's time since Start
    uint64_t pollStamped;       // transitions recorded by polling while events were on: the first, and any event missed
    double maxEventDelayMs;     // the longest an event took to arrive, which is what polling would have cost
};
// 'KbQueueStatus'
KbQueueStatus kbQueueStatus();
// 'KbQueueCreate'. mask nonzero = watched, all finite; interval 0.001..0.1 s.
void kbQueueCreate(const std::array<double, 256> &mask, double interval);
// 'KbQueueRelease' / 'KbQueueStart' / 'KbQueueStop' / 'KbQueueFlush'. Start also
// asks the system for key events; where the host application is allowed Input
// Monitoring, transitions are recorded with the times the events carry, and
// polling remains as a check. Otherwise it warns once (kWarnInputMonitoring) and
// times are those of the polling scan.
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

// Bounded snapshot without draining GPU work; status 2 remains pending.
std::vector<FrameRecord> recentFrames(size_t count);

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
