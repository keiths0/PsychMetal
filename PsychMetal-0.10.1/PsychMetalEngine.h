// PsychMetalEngine.h — host-neutral engine for PsychMetal 0.10.1.
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
#include <cmath>
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
inline constexpr const char *kEngineVersion = "0.10.1";

// Every error and warning identifier the engine emits.
inline constexpr const char *kErrGeneral      = "PsychMetal:Error";
inline constexpr const char *kErrMetal        = "PsychMetal:Metal";
inline constexpr const char *kErrScreen       = "PsychMetal:Screen";
inline constexpr const char *kErrMode         = "PsychMetal:Mode";
inline constexpr const char *kErrDrawableSize = "PsychMetal:DrawableSize";
inline constexpr const char *kErrPipeline     = "PsychMetal:Pipeline";
inline constexpr const char *kErrShader       = "PsychMetal:Shader";
inline constexpr const char *kErrWindowOrigin = "PsychMetal:WindowOrigin";
inline constexpr const char *kErrAudio        = "PsychMetal:Audio";
inline constexpr const char *kErrMicrophone   = "PsychMetal:Microphone";  // input asked for, access refused
inline constexpr const char *kErrNative       = "PsychMetal:NativeException";  // front ends: std::exception
inline constexpr const char *kErrInterrupted  = "PsychMetal:Interrupted";  // Control-C or Command-period in the window
inline constexpr const char *kWarnRefresh        = "PsychMetal:UnknownRefreshRate";
inline constexpr const char *kWarnDisplayMapping = "PsychMetal:DisplayMapping";
inline constexpr const char *kWarnDrainTimeout   = "PsychMetal:DrainTimeout";
inline constexpr const char *kWarnDisplayCapture = "PsychMetal:DisplayCapture";
inline constexpr const char *kWarnInputMonitoring = "PsychMetal:InputMonitoring";
inline constexpr const char *kWarnDebugger        = "PsychMetal:Debugger";
inline constexpr const char *kWarnAudioRoute      = "PsychMetal:AudioRoute";
inline constexpr const char *kWarnRecording       = "PsychMetal:Recording";

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

struct MutableFloatView {
    float *data=nullptr;int ndim=0;
    std::array<size_t,3> shape{};std::array<ptrdiff_t,3> strides{};
};

using Rect4 = std::array<double, 4>;

// ---------------------------------------------------------------------------
// 'CreateImagePipeline', 'ProcessImage', 'CloseImagePipeline'. The compact
// program is Nx32 doubles: opcode, then arguments. Public wrappers accept named
// operations. ProcessImage returns/replaces a texture; intermediates stay on GPU.
uint64_t createImagePipeline(const ArrayView &operations);
uint64_t processImage(uint64_t pipeline,uint64_t source,uint64_t destination=0);
void closeImagePipeline(uint64_t pipeline);

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
    bool captureDisplay = true;     // macOS: opt out explicitly for compositor comparisons
    bool displayLink = false;       // CAMetalDisplayLink; macOS 14 / iOS 17+
    std::optional<double> refreshHz; // 20..1000; overrides the reported rate
    // Diagnostic sessions only. Drawables are created readable and every frame's
    // drawable is copied before it is presented, so GetImage can return it. Off,
    // the layer is framebuffer-only and no frame is copied.
    bool readback = false;
    // Drawable: 8 (BGRA8), 10 (SDR BGR10A2), 16 (linear Display-P3 EDR RGBA16Float).
    uint64_t bitDepth = 8;
};
// 'HDRInfo', 'HDRExposure'. Linear Display-P3 relative to SDR reference white.
struct HDRInfo {bool enabled=false;double currentHeadroom=1,potentialHeadroom=1,exposure=0;};
HDRInfo hdrInfo();
void setHDRExposure(double stops);
struct OpenResult {
    double pixelWidth, pixelHeight;  // render size in pixels
    double ifi;                      // nominal refresh period, seconds
    double pointWidth, pointHeight;  // display size in points
    uint64_t sessionToken;
};
// 'Open'. Requires prepareApp().
// 'DefaultPresentation': front ends use this default; explicit OpenOptions select either backend.
bool defaultDisplayLink() noexcept;
// debuggerAttached: a debugger (Xcode, lldb) is tracing this process. It stops the
// process to sample it, so presentation timing is then not representative.
struct EnvironmentInfo { std::string engineVersion, platform, osVersion, gpuName; bool gpuAvailable, debuggerAttached; };
// 'Environment'. No window, drawables, capture or presentation; GPU may be unavailable.
EnvironmentInfo environment();
PM_BLOCKING OpenResult openSession(const OpenOptions &options);
// 'OpenExport'. Standalone Metal canvas, no window/display/drawables/startup.
// Flip requires a virtual recording. Dimensions 2..8192, <=16,777,216 pixels.
PM_BLOCKING OpenResult openExport(uint64_t width,uint64_t height,double refreshHz,bool readback=false);

// What a playback submitted, and what the display reported of it. shown counts
// the samples reported on screen (submitted - shown were never shown, or never
// reported); late those that appeared more than half a
// refresh after one refresh per sample since the last shown one, lateRefreshes
// the refreshes they cost, and firstLateSample the first of them (zero-based;
// NaN with none). meanSampleMs is the average time a sample was on screen,
// longestIntervalMs the longest time between two shown samples: from them the
// stimulus's actual frequency. Reports still outstanding when playback ends are
// waited for, briefly; a sample whose report never came is not counted as shown.
struct TimelineResult {
    uint64_t submitted, firstToken, lastToken;
    bool cancelled;
    double expectedRefreshHz, lastQueueMs, lastFlipMs;
    bool lastConfirmed;
    uint64_t shown, late, lateRefreshes;
    double firstLateSample, meanSampleMs, longestIntervalMs;
};
// 'PlayTimeline': snapshot queued window draws, replay with no host callbacks.
// tracks is N x 6 Float64: [zero-based draw index, parameter, kind, even period,
// amplitude, offset]. Parameter 0 contrast, 1 phase degrees, 2/3 x/y translation.
// Kind 0 cosine, 1 periodic ramp. Draw indices address the entire queued scene;
// tracks may target procedural stimulus draws only. Each submitted frame advances
// the sample once, even when the display later reports that presentation missing.
PM_BLOCKING TimelineResult playTimeline(uint64_t frames, const ArrayView &tracks, const ArrayView *keyframes=nullptr);
// 'CancelTimeline': ends the playback that is running, or the next one to start
// if none is: a request made just before playback begins is not lost. Playback
// that ends by it clears it; cancelTimeline(false) clears it otherwise. Callable
// from any thread during playback; takes no lock.
void cancelTimeline(bool cancel = true) noexcept;
// 'UpdateTimeline': N x 3 [zero-based draw index, parameter0..3, value].
void updateTimeline(const ArrayView &updates);

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
    double time;           // confirmed/projected physical time; logical refresh during virtual export
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
// During virtual recording, queueFlip takes increasing logical targets; queueResults
// still reports physical times, and its waits do not advance the logical clock.
// status: 0 shown, 1 dropped, 2 still pending, 3 GPU error, 4 no drawable,
// 5 cancelled. A frame whose store the GPU failed to render is not shown. queueCancel abandons frames not yet handed to the display and
// returns how many.
struct QueueResult { uint64_t token; double pending, capacity; };
PM_BLOCKING QueueResult queueFlip(double when);
struct QueuedFrame { uint64_t token; double requested, presented; int status; };
PM_BLOCKING std::vector<QueuedFrame> queueResults(bool wait);
uint64_t queueCancel();

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
// Kinds: 0 filled rect, 1 framed rect (param: pen), 2 filled oval, 3 framed oval
// (pen), 4 round dot, 5 line (rect is its ends, param its width), 6 Gabor, 7 noise,
// 8 arc (param 0: a filled wedge, else a band that many pixels wide; extra[0] the
// start and extra[1] the sweep, radians from the top, clockwise on the screen).
// 'CheckStimulus': 15 doubles: kind (0 grating, 1 noise), mean RGB (0..1),
// contrast (0..1), cycles/pixel (0..0.5), orientation/phase degrees, seed,
// grain pixels, colour, normal, opacity, aperture (0 rect,1 ellipse,2 Gaussian), sigma.
// Contrast is amplitude/mean; noise uses mean + mean*contrast*deviate, clamped.
std::array<double,15> checkStimulus(const ArrayView &parameters);
// 'CheckMask': 8 doubles: kind (0 ellipse,1 Gaussian,2 annulus,3 raised cosine),
// sigma, inner radius, outer radius, edge width, center x/y, invert (0/1).
// Geometry is in normalized half-aperture units; coverage is evaluated on GPU.
std::array<double,8> checkMask(const ArrayView &parameters);
// 'MakeStimulus' / 'StimulusWith' / 'MakeMask': a recipe from named options, the
// same for every front end. An option is a name and either text or numbers.
// makeStimulus starts from a kind's defaults ("grating" or "noise"); stimulusWith
// from a recipe, for one draw's overrides. Options: mean (1 or 3 numbers),
// contrast, frequency, orientation, phase, seed, grain, colour, normal, opacity,
// aperture ("rect", "ellipse" or "gaussian") and sigma. makeMask: kinds ellipse,
// gaussian, annulus and raised_cosine; options sigma (gaussian), inner (annulus),
// radius and edge (not gaussian), center (2 numbers) and invert.
struct Option { std::string name; bool isText = false; std::string text; std::vector<double> numbers; };
std::array<double,15> makeStimulus(const std::string &kind, const std::vector<Option> &options);
std::array<double,15> stimulusWith(const ArrayView &recipe, const std::vector<Option> &options);
std::array<double,8> makeMask(const std::string &kind, const std::vector<Option> &options);
// 'CreateShader' / 'CloseShader' / 'DrawShader': fixed custom fragment ABI.
// 16 finite parameters, destination4, optional image/analytic coverage.
uint64_t createShader(const std::string &source);
void closeShader(uint64_t handle);
void drawShader(uint64_t handle, const ArrayView &parameters, const ArrayView &dst,
                uint64_t mask, const ArrayView *coverage=nullptr);
std::array<double,16> checkShaderParameters(const ArrayView &parameters);
// 'DrawMaskedTexture': source handle, 14 doubles (normalized src4, dst4,
// normalized RGBA4, angle radians, filter 0/1), optional image/analytic masks.
void drawMaskedTexture(uint64_t source, const ArrayView &parameters, uint64_t mask,
                       const ArrayView *coverage=nullptr);
// 'DrawStimulus': dst (4 doubles); optional one-channel mask texture handle.
// The mask multiplies procedural aperture coverage, independent of noise scale.
void drawStimulus(const ArrayView &parameters, const ArrayView &dst, uint64_t mask,
                  const ArrayView *coverage = nullptr);

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
// 'LayoutText'. Text split at newlines and, with a finite wrapWidth (pixels),
// between words; each line measured with textBounds, an empty one as 0 by 0.
// ascent is the first non-empty line's. The last sixteen layouts are kept, since
// a program draws the same text on every frame.
struct TextLayout { std::vector<std::string> lines; std::vector<std::array<double,2>> sizes; double ascent; };
TextLayout layoutText(const std::string &utf8, const std::string &font, double size, double wrapWidth);
TextBounds drawText(const std::string &utf8, const std::string &font, double size, double x, double y,
                    const Rect4 &rgba);

// 'GetImage'. The frame most recently submitted by Flip or QueueFlip,
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
// Half-float RGBA drawables return RGB float32 in relative linear-light units.
PM_BLOCKING void getImageFloat(const ImageRegion &region,const MutableFloatView &out);

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
// most pixels. Optional refreshHz selects a reported fixed rate within 0.01 Hz.
// Equal-resolution ties preserve the current mode, then prefer higher refresh.
// Modes refreshHz==0 means unknown/variable, never an assumed 60 Hz.
void setMode(double screenIndex, double pointWidth, double pointHeight, double refreshHz = 0);
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
    double secureInputPID;     // 0 inactive, -1 active (the owner is not looked up)
    bool eventTimestamps;       // key events are the source (IOHIDManager, or an iPhone's presses); else polling
    uint64_t eventStamped;      // transitions recorded with the event's own time since Start
    uint64_t pollStamped;       // transitions recorded by polling since Start
    double maxEventDelayMs;     // the longest an event took to arrive, which is what polling would have cost
};
// 'KbQueueStatus'
KbQueueStatus kbQueueStatus();
// 'KeyNames'. HID usage and name, as Psychtoolbox's KbName on macOS.
struct KeyName { int usage; const char *name; };
const std::vector<KeyName> &keyNames();
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
// Audio. PsychMetalAudio.h is the real-time core; AUDIO.md the user's guide.
// One output, and optionally one input, per process. Every time is GetSecs time.
// ---------------------------------------------------------------------------

struct AudioOptions {
    int64_t device = -1;           // output device id from audioDevices(); -1: the default
    double rate = 0;               // 0: the device's own rate
    uint32_t channels = 2;
    uint32_t bufferFrames = 64;    // requested; AudioInfo says what the device granted
    bool anyRoute = false;         // allow Bluetooth and AirPlay; AudioInfo.timed is then false
    bool input = false;            // also open the input: recording and the voice key
    int64_t inputDevice = -1;
    uint32_t inputChannels = 1;
    double recordSeconds = 60;     // memory for one recording, allocated at open
};
struct AudioInfo {
    double rate = 0;
    uint32_t channels = 0, bufferFrames = 0;
    double outputLatency = 0;      // seconds after a buffer's host time that its first sample leaves the device
    std::string device, transport;
    bool timed = false;            // false on Bluetooth and AirPlay: their latency is not known
    bool input = false;
    double inputRate = 0;
    uint32_t inputChannels = 0, inputBufferFrames = 0;
    double inputLatency = 0;       // seconds before a buffer's host time that its first sample entered the device
    std::string inputDevice, inputTransport;
    double recordSeconds = 0;
};
struct AudioDevice {
    int64_t id;
    std::string name, transport;
    uint32_t outputChannels, inputChannels;
    double rate;
    bool isDefaultOutput, isDefaultInput;
};
// 'AudioDevices'. On iOS, the current route as one output and one input.
std::vector<AudioDevice> audioDevices();
// 'OpenAudio'. Input asks for microphone access the first time; refusal fails.
PM_BLOCKING AudioInfo openAudio(const AudioOptions &options);
// 'CloseAudio'. Stops everything at once; sounds and recordings are released.
PM_BLOCKING void closeAudio();

struct AudioStatus {
    bool open = false;
    AudioInfo info;
    uint64_t sounds = 0, voices = 0;          // loaded sounds; voices playing or waiting
    uint64_t clippedSamples = 0, lostEvents = 0;
    bool recording = false;
    uint64_t recordedFrames = 0;
};
// 'AudioStatus'
AudioStatus audioStatus();

// 'Tone', 'Click', 'WhiteNoise': sounds to load with MakeSound, at `rate` Hz.
// A tone is a sine and white noise Gaussian (clipped to -1..1), both with
// raised-cosine onset and offset ramps of `ramp` seconds; a click is
// rectangular, its onset its first sample. A NaN seed draws a fresh noise.
std::vector<double> tone(double frequency, double seconds, double rate, double amplitude = 0.5, double ramp = 0.005);
std::vector<double> click(double rate, double seconds = 0.001, double amplitude = 0.9);
std::vector<double> whiteNoise(double seconds, double rate, double amplitude = 0.3, double seed = NAN, double ramp = 0.005);

// 'MakeSound'. samples: (frames) or (frames, channels), Float64 or Float32, in
// -1..1; channels 1 (played on every channel) or the output's. rate 0 means the
// output's; another rate is converted here, once.
// 'MakeAudioStream', 'RefillSound', 'AudioStreamStatus'. Frames are at the
// open output rate; refills are all-or-nothing and never wait for buffer space.
struct AudioStreamStatus {
    uint64_t capacity=0, queued=0, free=0, written=0, consumed=0, underflowFrames=0;
    bool sealed=false;
};
uint64_t makeAudioStream(uint64_t capacityFrames,uint32_t channels);
uint64_t refillSound(uint64_t sound,const ArrayView &samples,bool final);
AudioStreamStatus audioStreamStatus(uint64_t sound);
uint64_t makeSound(const ArrayView &samples, double rate);
// 'CloseSound'. Voices already playing it keep it until they end.
void closeSound(uint64_t sound);
// 'Play'. when: a GetSecs time, NaN for at once. frame: a queued frame's token
// (0: none); the sound then starts offset seconds after that frame's projected
// presentation time. gain multiplies the samples; repeats 0 plays until stopped.
uint64_t play(uint64_t sound, double when, uint64_t frame, double offset, double gain, uint32_t repeats);
// 'StopSound'. voice 0 stops every voice; when NaN is at once.
void stopSound(uint64_t voice, double when);
// 'Modulate'. From `when` (NaN: at once) on the nearest sample, the voice's
// samples are multiplied by 1 - depth * (1 - cos(2 pi hz t + phase)) / 2, t the
// GetSecs time of each sample: 1 at the peaks, 1 - depth at the troughs. depth 0
// ends modulation. A timed change replaces a timed change not yet due; a change
// at once leaves it due.
void modulate(uint64_t voice, double hz, double phase, double depth, double when);

// 'StartRecording' / 'StopRecording'. One recording at a time; a new one
// replaces the last one's samples.
uint64_t startRecording(double when);
void stopRecording(double when);
struct Recording {
    std::vector<float> samples;   // channel c, frame i at samples[c * frames + i]
    uint64_t frames = 0;
    uint32_t channels = 0;
    double rate = 0;
    double firstSampleTime = 0;   // NaN before the recording has started
    bool recording = false;       // still growing
};
// 'GetRecording'. A copy of the recording so far.
Recording getRecording();
// 'VoiceKey'. One-shot, from when (NaN: at once): triggers when `minimum` of the
// samples within `window` seconds reach `threshold` (absolute amplitude 0..1),
// at the first of them. A new key replaces an armed one.
uint64_t voiceKey(double threshold, double when, double window, uint32_t minimum);
// 'InputRecent'. The newest `seconds` of the first input channel (at most
// about half a second at 48 kHz), and the time just after its last sample.
struct InputRecent { std::vector<float> samples; double rate = 0; double endTime = 0; };
InputRecent inputRecent(double seconds);

// Kinds and statuses of audioResults events.
enum class AudioEventKind : int { SoundStart, SoundEnd, RecordStart, RecordEnd, Key };
enum class AudioEventStatus : int { OnTime, Late, Finished, Stopped, Full, Refused, Triggered, Interrupted };
struct AudioEvent {
    AudioEventKind kind;
    uint64_t id;                  // voice, recording or key
    double requested, time;       // NaN requested: at once
    AudioEventStatus status;
    double frames;                // RecordEnd: frames recorded; Key: its frame in the recording (NaN: none)
    double level;                 // Key: the triggering sample's amplitude
    uint64_t frameToken;          // sounds played at a frame (0: none)
    double framePresented;        // that frame's confirmed presentation time, if known yet (else NaN)
};
// 'AudioResults'. Every event not yet reported, oldest first. Does not wait.
std::vector<AudioEvent> audioResults();

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
    double committedAt;
    double drawableAcquireMs, encodeMs;
};

// 'RecentFrames'. Bounded snapshot without draining GPU work; status 2 remains pending.
std::vector<FrameRecord> recentFrames(size_t count);

// The Diagnostic summary; field names and order are those of the MATLAB struct.
struct DiagnosticSummary {
    double confirmedPresentations, missingPresentedTimes;
    double lastTargetErrorMs, lastConfirmDelayMs;
    double renderWidth, renderHeight, inFlight, drawableCount;
    double measuredRefreshHz, gridSamples, noDrawable;
    double leadEstimateMs, pipelineEstimateMs, gpuEstimateMs;
    bool readbackEnabled;
    double shapesAppended, shapesEncoded;
    double texturesCreated, texturesDrawn, textureAllocations, lastTextureUploadMs;
    Rect4 lastShapeRect, lastShapeColor;
    Rect4 screenSafeAreaInsets;   // top, left, bottom, right, in points
    double backingScaleFactor;    // pixels per point
    bool displayCaptured;         // actual CoreGraphics capture state; false on iOS/export
};

struct DiagnosticReport {
    std::vector<FrameRecord> history;   // user frames since ConfirmStartup, newest 16384
    DiagnosticSummary summary;
};
// 'Diagnostic'. Waits up to two seconds for in-flight frames first.
PM_BLOCKING DiagnosticReport diagnostic();

// --- movies (MOVIES.md) ------------------------------------------------------
// A movie is read with AVFoundation, decoded by the hardware decoder, and each
// frame handed to Metal without a copy. Frames are numbered from 0 in the order
// they are shown, from the presentation times in the file.
struct MovieInfo {
    double width = 0, height = 0;    // pixels, as shown: turned as the track asks
    double frames = 0;               // video frames
    double frameRate = 0;            // frames per second: frames over the time they span
    double duration = 0;             // seconds
    double keyframeInterval=0;         // largest sync-frame spacing, in frames; 0 unknown
    bool constantRate = true;        // every frame lasts the same time, to 0.1 %
    double soundChannels = 0, soundRate = 0;   // 0 when the movie has no sound
    std::string codec;               // the video codec, as four characters ("avc1", "hvc1", "apcn", ...)
};
// 'OpenMovie'. Reads the file's frame times (without decoding) and returns a handle.
PM_BLOCKING uint64_t openMovie(const std::string &path, MovieInfo &info);
// 'TranscodeMovie'. All-intra re-encoding without a window, preserving sample times.
// Stereo audio is decoded/re-encoded; existing destination replaced only on success.
PM_BLOCKING uint64_t transcodeMovie(const std::string &source,const std::string &destination,const std::string &codec);
// 'PrepareMovie'. Decode a bounded lookahead ring; frames=0 preloads the complete movie after
// checking its total decoded size against the explicit budget. Returns resident frames.
PM_BLOCKING uint64_t prepareMovie(uint64_t movie,uint32_t frames,uint64_t maxBytes);
// 'MovieFrameTimes'. Each frame's presentation time in the movie, seconds.
std::vector<double> movieFrameTimes(uint64_t movie);
// 'DrawMovieFrame'. Queues frame `index` like a texture: src as a fraction of the
// frame as shown [l t r b], dst in pixels, angle in degrees, tint RGBA 0..1, filter 0
// nearest or 1 linear. Decodes it if it is not the frame decoded last.
PM_BLOCKING void drawMovieFrame(uint64_t movie, uint64_t index, const Rect4 &src, const Rect4 &dst,
                                double angle, const Rect4 &tint, int filter);
// 'MovieSound'. The sound track decoded to `rate` Hz, interleaved, at most two
// channels, from the first frame's time, for playing `speed` times as fast (1: as
// recorded; 20/24 goes with a 24 fps movie's frames shown at 20). keepPitch false
// resamples, so the pitch changes with the speed; true stretches the time with
// AVFoundation's spectral time-pitch algorithm, keeping the pitch.
PM_BLOCKING std::vector<float> movieSound(uint64_t movie, double rate, double speed, bool keepPitch, uint32_t &channels);
struct MovieResult {
    uint64_t submitted = 0, firstToken = 0, lastToken = 0;     // refreshes presented, and their tokens
    uint64_t frames = 0;                 // movie frames shown
    bool cancelled = false;
    double start = 0;                    // the refresh the first frame was aimed at (GetSecs)
    double firstPresented = 0;           // when the display reported it (NaN if not reported)
    uint64_t shown = 0, late = 0, lateRefreshes = 0;
    double expectedRefreshHz = 0, longestIntervalMs = 0;
    double audioStartOffsetMs=NAN,audioEndOffsetMs=NAN,audioVideoDriftMs=NAN;
    uint64_t voice = 0;                  // the sound's voice, 0 if none
};
// 'PlayMovie'. Frames first..first+count-1, each shown for `refreshes` refreshes,
// drawn into dst (src as for DrawMovieFrame) on the window. The first is aimed at
// the refresh at or after `when` (NaN: three refreshes from now). If `sound` is
// not 0 it is played (gain) to start on that refresh. Escape or CancelTimeline
// stops it.
PM_BLOCKING MovieResult playMovie(uint64_t movie, uint64_t first, uint64_t count, uint32_t refreshes,
                                  const Rect4 &src, const Rect4 &dst, double when, uint64_t sound, double gain);
// 'CloseMovie'.
void closeMovie(uint64_t movie);

// --- recording what PsychMetal draws (MOVIES.md) ---------------------------------
// While recording, every frame the window presents (Flip, QueueFlip, PlayTimeline,
// PlayMovie) is drawn by the GPU into the encoder's buffer, scaled, and written as
// one movie frame stamped with the refresh it was aimed at, counted from the first
// recorded frame: a frame held for several refreshes lasts that long in the movie.
// No frame is dropped: if the encoder falls behind, Flip waits for it.
struct MovieRecording {
    std::string path, codec;
    bool virtualClock = false;
    double width = 0, height = 0;        // pixels, after scaling
    double frames = 0;                   // movie frames written
    double refreshes = 0;                // the movie's length in refreshes
    double refreshHz = 0;                // the timebase: the display's nominal rate
    double duration = 0;                 // seconds
    double late = 0;                     // frames the display reported more than half a refresh after their aim
    double unreported = 0;               // frames whose report was not (or no longer) available
    bool sound = false;                  // a captured live or rendered generated sound track
    double soundSeconds = 0;             // of sound written
    double soundLostSeconds = 0;         // sound that did not reach the track (the tap overflowed)
};
// 'StartMovieRecording'. codec: prores4444, prores422, hevc or h264; .mov for any,
// .mp4 or .m4v for hevc and h264. scale 0.05 to 1. An existing file is replaced.
// sound: when audio is open, everything it plays from now on is the movie's sound
// track (linear PCM in .mov, AAC in .mp4 and .m4v), placed by the times it is heard.
// virtualClock: Flip/GetSecs use logical export time; newly scheduled generated
// audio uses that timeline. Queued playback is refused; diagnostics stay physical.
PM_BLOCKING void startMovieRecording(const std::string &path, const std::string &codec, double scale, bool sound, bool virtualClock = false);
// 'StopMovieRecording'. Waits for every recorded frame to be encoded and finishes the file.
PM_BLOCKING MovieRecording stopMovieRecording();

}  // namespace pm

#endif  // PSYCHMETAL_ENGINE_H
