// PsychMetalIOS.h — the iPhone's and iPad's side of the PsychMetal engine: its
// window, its screen and its input.
// SPDX-License-Identifier: MIT
//
// A part of PsychMetalEngine.mm: included by it, once, where the engine's state
// is already declared, and by nothing else. The Mac's side is in that file,
// between #if !PM_IOS and #endif.
//
// On these devices the main thread and its run loop belong to the app, so an
// experiment runs on a thread of its own. The engine puts a window of its own
// over the app's, holding a Metal layer at the screen's own pixels, and takes it
// away on Close. Touches, and the keys of an external keyboard, reach that
// window's view on the main thread with the system's times for them, which are
// on the engine's clock.

struct PMScreen { size_t pixelWidth, pixelHeight; double pointWidth, pointHeight, refreshHz; };

// --- input -------------------------------------------------------------------

// A program written for a mouse and a keyboard is driven by fingers:
//   one finger is the pointer: mouse() reports where it is, or last was;
//   a second finger down is button 1, at the pointer;
//   a third finger down is the Escape key.
// The pointer is the finger that went down when none was; when it lifts, the
// pointer stays where it was. touchEvents() reports every finger as it is.

static std::mutex iosInputLock;                 // guards everything in this section, and touchRing
static const void *iosFinger[PM_FINGERS];       // the touch that is finger k + 1, while it is down
static int iosDown;                             // how many of them are down
static double iosPointerX, iosPointerY;
static int iosPointerFinger;                    // the finger that is the pointer; 0 with none
static bool iosClick, iosEscape;                // two fingers down; three
static double iosEscapeTime;                    // when iosEscape last changed
#define PM_POINTER_EVENTS 4096
static pm::MouseEvent iosPointerEvents[PM_POINTER_EVENTS];
static unsigned iosPointerHead, iosPointerCount;
static uint64_t iosPointerDropped;
static bool iosPointerListening;
static bool iosKeyDown[256];                    // index k is HID usage k + 1, as everywhere
#define PM_USAGE_ESCAPE 41
static double iosPixelsPerPoint = 1;            // the view's points to window pixels
// The app stopped being the one in front (the home gesture, a call, the lock
// button) since the window opened. Frames cannot be shown from then on.
static std::atomic<bool> iosLeftFront;

// Caller holds iosInputLock.
static void iosPointerEvent(double time, bool pressed) {
    if (!iosPointerListening) return;
    if (iosPointerCount == PM_POINTER_EVENTS) {
        iosPointerHead = (iosPointerHead + 1) % PM_POINTER_EVENTS;
        iosPointerCount--;
        iosPointerDropped++;
    }
    iosPointerEvents[(iosPointerHead + iosPointerCount++) % PM_POINTER_EVENTS] =
        {time, 1, pressed, iosPointerX, iosPointerY};
}

// One sample of one finger: `key` is the same for as long as the finger is down.
// Caller holds iosInputLock.
static void iosNoteFinger(const void *key, int phase, double x, double y, double time) {
    int finger = 0;
    bool landed = false;        // this finger was not down before
    for (int k = 0; k < PM_FINGERS && !finger; k++)
        if (iosFinger[k] == key) finger = k + 1;
    if (!finger && phase == 0)
        for (int k = 0; k < PM_FINGERS && !finger; k++)
            if (!iosFinger[k]) { iosFinger[k] = key; finger = k + 1; landed = true; }
    if (!finger) return;        // more fingers than are numbered, or one not seen going down
    touchRing.push({time, finger, phase, x, y});
    if (landed && !iosDown) iosPointerFinger = finger;
    if (finger == iosPointerFinger) {
        iosPointerX = x;
        iosPointerY = y;
        if (phase >= 2) iosPointerFinger = 0;
    }
    if (landed) iosDown++;
    if (phase >= 2) { iosFinger[finger - 1] = nullptr; iosDown--; }
    if ((iosDown >= 2) != iosClick) { iosClick = !iosClick; iosPointerEvent(time, iosClick); }
    if ((iosDown >= 3) != iosEscape) { iosEscape = !iosEscape; iosEscapeTime = time; }
}
// --- end of the fingers' rules (tests/test_fingers.py compiles down to here) ---

// `touch` is the object that is the same for as long as the finger is down;
// `sample` holds this sample's place and time, and is either that object or one
// of the samples the system took between two deliveries.
static void iosNoteTouch(UITouch *touch, UITouch *sample, UIView *view, int phase) {
    const CGPoint place = [sample preciseLocationInView:view];
    iosNoteFinger((__bridge const void *)touch, phase, place.x * iosPixelsPerPoint, place.y * iosPixelsPerPoint,
                  sample.timestamp);
}

// The view the window shows: a Metal layer that takes touches and keys.
@interface PMMetalView : UIView
@end
@implementation PMMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)canBecomeFirstResponder { return YES; }
// Three fingers are Escape here, not the system's undo, copy and paste.
- (UIEditingInteractionConfiguration)editingInteractionConfiguration { return UIEditingInteractionConfigurationNone; }
// The display link exists to hold the display to its refresh rate; it does nothing.
- (void)tick:(CADisplayLink *)link { (void)link; }
- (void)note:(NSSet<UITouch *> *)touches event:(UIEvent *)event phase:(int)phase {
    bool was, escape;
    double when;
    {
        std::lock_guard<std::mutex> guard(iosInputLock);
        was = iosEscape;
        for (UITouch *touch in touches) {
            // A finger that moves is sampled more often than its moves are delivered.
            NSArray<UITouch *> *samples = phase == 1 ? [event coalescedTouchesForTouch:touch] : nil;
            if (samples.count)
                for (UITouch *sample in samples) iosNoteTouch(touch, sample, self, phase);
            else
                iosNoteTouch(touch, touch, self, phase);
        }
        escape = iosEscape;
        when = iosEscapeTime;
    }
    // Told to the keyboard queue as a key's own events are, with the lock let go.
    if (escape != was)
        keyboardQueue.post(when, PM_USAGE_ESCAPE, escape, CACurrentMediaTime() - when);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self note:touches event:event phase:0]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self note:touches event:event phase:1]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self note:touches event:event phase:2]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self note:touches event:event phase:3]; }
// The keys of an external keyboard. A key's code is its HID usage. NO if any of
// the presses was not a key, so that it can be passed on.
- (BOOL)keys:(NSSet<UIPress *> *)presses down:(bool)down {
    BOOL all = YES;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) { all = NO; continue; }
        const long usage = (long)key.keyCode;
        if (usage < 1 || usage > 256) continue;
        {
            std::lock_guard<std::mutex> guard(iosInputLock);
            iosKeyDown[usage - 1] = down;
        }
        const double now = CACurrentMediaTime();
        double stamp = press.timestamp;
        if (!(now - stamp > -0.005 && now - stamp < 5.0)) stamp = now;
        keyboardQueue.post(stamp, (int)usage, down, now - stamp);
    }
    return all;
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self keys:presses down:true]) [super pressesBegan:presses withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self keys:presses down:false]) [super pressesEnded:presses withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self keys:presses down:false]) [super pressesCancelled:presses withEvent:event];
}
@end

// The status bar is hidden and the device held as it was when the window opened:
// a window that turned would no longer be the size it was opened at. A swipe from
// an edge goes to the experiment first; the system acts on a second one. For
// that the home indicator has to stay: UIKit ignores the deferral when it is
// asked to hide it.
@interface PMViewController : UIViewController
@property (nonatomic) UIInterfaceOrientationMask held;
@end
@implementation PMViewController
- (void)loadView { self.view = [[PMMetalView alloc] initWithFrame:CGRectZero]; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return NO; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIEditingInteractionConfiguration)editingInteractionConfiguration { return UIEditingInteractionConfigurationNone; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return self.held; }
@end

static void readKeyboardState(bool *kv, const bool *filter) {
    std::lock_guard<std::mutex> guard(iosInputLock);
    for (int k = 0; k < 256; k++)
        kv[k] = (iosKeyDown[k] || (k == PM_USAGE_ESCAPE - 1 && iosEscape)) && (!filter || filter[k]);
}
// Key events reach the view whenever a keyboard is attached; the keyboard queue
// takes them while it runs.
static void startKeyTap(void) { keyboardQueue.setExternal(true); }
static void stopKeyTap(void) { keyboardQueue.setExternal(false); }
static void stopMouseTap(void) {
    std::lock_guard<std::mutex> guard(iosInputLock);
    iosPointerListening = false;
    iosPointerHead = iosPointerCount = 0;
    iosPointerDropped = 0;
}

// --- the screen and the window --------------------------------------------------

static UIWindow *iosAppKeyWindow;       // the app's key window, made key again on Close
static CADisplayLink *iosLink;          // holds the display to the refresh rate
static bool iosIdleTimerWas;            // whether the app had stopped the screen from locking
static id iosResignObserver;

// The scene the window is in, or with no window the one the app is showing.
// Main thread.
static UIWindowScene *iosScene(void) {
    if (metalWindow.windowScene) return metalWindow.windowScene;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)scene;
    return nil;
}

// The device's screen as it is held now: its own pixels, its points, and the
// refresh rate the app can have.
static PMScreen iosScreen(void) {
    __block PMScreen out = {0, 0, 0, 0, 0};
    __block bool found = false;
    onMainSync(^{
        UIWindowScene *scene = iosScene();
        if (!scene) return;
        found = true;
        UIScreen *screen = scene.screen;
        const CGSize native = screen.nativeBounds.size;     // pixels, with the device upright
        const CGSize points = screen.bounds.size;           // points, as it is held
        const bool sideways = points.width > points.height;
        out.pixelWidth = (size_t)llround(sideways ? native.height : native.width);
        out.pixelHeight = (size_t)llround(sideways ? native.width : native.height);
        out.pointWidth = points.width;
        out.pointHeight = points.height;
        double hz = (double)screen.maximumFramesPerSecond;
        // An iPhone holds an app to 60 Hz unless the app's Info.plist asks otherwise,
        // and any device does in Low Power Mode.
        if (hz > 60 && UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
            ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CADisableMinimumFrameDurationOnPhone"] boolValue])
            hz = 60;
        if (hz > 60 && NSProcessInfo.processInfo.lowPowerModeEnabled)
            hz = 60;
        out.refreshHz = hz;
    });
    if (!found) fail("PsychMetal needs the app to be in front.");
    return out;
}

static void iosOpenWindow(NSUInteger w, NSUInteger h, double hz, NSUInteger drawableCount, bool readable) {
    {
        std::lock_guard<std::mutex> guard(iosInputLock);
        touchRing.clear();
        memset(iosFinger, 0, sizeof(iosFinger));
        memset(iosKeyDown, 0, sizeof(iosKeyDown));
        iosDown = iosPointerFinger = 0;
        iosClick = iosEscape = false;
        iosPointerX = (double)w / 2;
        iosPointerY = (double)h / 2;
        iosPointerListening = false;
        iosPointerHead = iosPointerCount = 0;
        iosPointerDropped = 0;
    }
    iosLeftFront.store(false);
    __block NSString *problem = nil;
    __block CGSize drawable = CGSizeZero;
    __block bool lowPower = false;
    onMainSync(^{
        UIWindowScene *scene = iosScene();
        if (!scene) { problem = @"PsychMetal needs the app to be in front."; return; }
        UIScreen *screen = scene.screen;
        PMViewController *controller = [PMViewController new];
        const UIInterfaceOrientation held = scene.interfaceOrientation;
        controller.held = held == UIInterfaceOrientationUnknown ? UIInterfaceOrientationMaskAll
                                                                : (UIInterfaceOrientationMask)(1UL << held);
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.windowLevel = UIWindowLevelAlert + 1;
        window.backgroundColor = UIColor.blackColor;
        window.rootViewController = controller;
        PMMetalView *view = (PMMetalView *)controller.view;
        view.multipleTouchEnabled = YES;
        iosAppKeyWindow = scene.keyWindow;
        iosIdleTimerWas = UIApplication.sharedApplication.idleTimerDisabled;
        [window makeKeyAndVisible];
        [window layoutIfNeeded];
        [view becomeFirstResponder];
        metalWindow = window;
        const CGSize size = view.bounds.size, whole = screen.bounds.size;
        if (fabs(size.width - whole.width) > 0.5 || fabs(size.height - whole.height) > 0.5) {
            problem = [NSString stringWithFormat:@"The window is %.0fx%.0f points and the screen %.0fx%.0f: "
                       "PsychMetal needs the whole screen, not a share of it.",
                       size.width, size.height, whole.width, whole.height];
            return;
        }
        iosPixelsPerPoint = (double)w / size.width;
        layer = (CAMetalLayer *)view.layer;
        layer.device = device;
        layer.pixelFormat = drawableFormat;
        layer.opaque = YES;
        layer.framebufferOnly = readable ? NO : YES;
        layer.maximumDrawableCount = drawableCount;
        drawableCountReadback = layer.maximumDrawableCount;
        layer.presentsWithTransaction = NO;
        layer.contentsScale = screen.nativeScale;
        layer.drawableSize = CGSizeMake((CGFloat)w, (CGFloat)h);
        drawable = layer.drawableSize;
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        iosLink = [CADisplayLink displayLinkWithTarget:view selector:@selector(tick:)];
        const float rate = (float)hz;
        iosLink.preferredFrameRateRange = CAFrameRateRangeMake(rate, rate, rate);
        [iosLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        iosResignObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) { (void)note; iosLeftFront.store(true); }];
        lowPower = NSProcessInfo.processInfo.lowPowerModeEnabled;
    });
    if (problem)
        failOpen(pm::kErrGeneral, problem);
    if (llround(drawable.width) != (long long)w || llround(drawable.height) != (long long)h)
        failOpen(pm::kErrDrawableSize,
                 [NSString stringWithFormat:@"Metal drawable is %.0fx%.0f but the render rectangle is %lux%lu. "
                  "Refusing to scale the stimulus.", drawable.width, drawable.height,
                  (unsigned long)w, (unsigned long)h]);
    if (lowPower)
        hookWarn(pm::kWarnRefresh, "This device is in Low Power Mode, which holds its display to 60 Hz and "
                 "may slow it further. Turn it off for timing work.");
}

static void iosCloseWindow(void) {
    onMainSync(^{
        if (!metalWindow) return;
        [iosLink invalidate];
        iosLink = nil;
        if (iosResignObserver) [NSNotificationCenter.defaultCenter removeObserver:iosResignObserver];
        iosResignObserver = nil;
        UIApplication.sharedApplication.idleTimerDisabled = iosIdleTimerWas;
        metalWindow.hidden = YES;
        metalWindow.rootViewController = nil;
        metalWindow = nil;
        // Fingers still down when the window goes are not fingers any more.
        std::lock_guard<std::mutex> guard(iosInputLock);
        memset(iosFinger, 0, sizeof(iosFinger));
        memset(iosKeyDown, 0, sizeof(iosKeyDown));
        iosDown = iosPointerFinger = 0;
        iosClick = iosEscape = false;
        [iosAppKeyWindow makeKeyWindow];
        iosAppKeyWindow = nil;
    });
}

static void iosRequireFront(void) {
    if (iosLeftFront.load())
        fail("The app is no longer in front, so nothing more can be shown: Close the window.");
}

// The Diagnostic fields that describe the window and the screen.
static void iosDescribeWindow(pm::DiagnosticSummary &d) {
    __block CGRect window = CGRectZero, view = CGRectZero, layerFrame = CGRectZero, screen = CGRectZero;
    __block UIEdgeInsets insets = UIEdgeInsetsZero;
    __block double scale = NAN;
    if (metalWindow)
        onMainSync(^{
            window = metalWindow.frame;
            view = metalWindow.rootViewController.view.bounds;
            if (layer) layerFrame = layer.frame;
            screen = metalWindow.windowScene.screen.bounds;
            scale = metalWindow.windowScene.screen.nativeScale;
            insets = metalWindow.safeAreaInsets;
        });
    auto r4 = [](CGRect r) -> pm::Rect4 { return {r.origin.x, r.origin.y, r.size.width, r.size.height}; };
    d.windowFrame = r4(window);
    d.viewBounds = r4(view);
    d.layerFrame = r4(layerFrame);
    d.screenFrame = r4(screen);
    d.screenVisibleFrame = r4(screen);
    d.screenSafeAreaInsets = {insets.top, insets.left, insets.bottom, insets.right};
    d.cgDisplayBounds = r4(CGRectZero);
    d.backingScaleFactor = scale;
}

// --- the engine's commands that are the device's own ---------------------------------

std::vector<pm::DisplayMode> pm::modes(double screenIndex) {
    if (screenIndex != floor(screenIndex) || screenIndex >= 1)
        fail("Screen index is out of range.");
    const PMScreen screen = iosScreen();
    return {{screen.pointWidth, screen.pointHeight, (double)screen.pixelWidth, (double)screen.pixelHeight,
             screen.refreshHz}};
}

void pm::setMode(double, double, double) {
    failWith(pm::kErrMode, "%s", "This device's display has one mode; it cannot be changed.");
}

// There is no cursor to show or hide.
void pm::setCursorVisible(bool) {}

// How the display is driven is not something this device reports.
pm::LinkInfo pm::linkInfo() {
    if (!device || closing) fail("LinkInfo requires an open PsychMetal window.");
    pm::LinkInfo info{NAN, NAN, NAN, NAN, NAN};
    info.pixelGbps = (double)renderWidth * (double)renderHeight * (3.0 * outputBits) / ifi / 1e9;
    return info;
}

pm::TouchEvents pm::touchEvents() {
    if (!device || closing) fail("TouchEvents requires an open PsychMetal window.");
    std::lock_guard<std::mutex> guard(iosInputLock);
    return touchRing.take();
}

// The pointer: where one finger is, or last was; button 1 is a second finger.
pm::MouseState pm::mouse() {
    if (!metalWindow || !renderWidth || !renderHeight)
        fail("Mouse requires an open PsychMetal window.");
    std::lock_guard<std::mutex> guard(iosInputLock);
    pm::MouseState out{};
    out.x = iosPointerX;
    out.y = iosPointerY;
    out.buttons = {iosClick, false, false};
    return out;
}

// There is no cursor to move: this is where the pointer is taken to be until a
// finger next goes down.
void pm::setMouse(double x, double y) {
    if (!metalWindow || !renderWidth || !renderHeight)
        fail("SetMouse requires an open PsychMetal window.");
    if (!(x >= 0 && x <= (double)renderWidth && y >= 0 && y <= (double)renderHeight))
        fail("SetMouse position must be inside the window, in pixels.");
    std::lock_guard<std::mutex> guard(iosInputLock);
    iosPointerX = x;
    iosPointerY = y;
}

// A second finger going down and lifting, as presses and releases of button 1
// at the pointer. As on the Mac, the first call starts listening and returns
// nothing.
pm::MouseEvents pm::mouseEvents() {
    if (!metalWindow || !renderWidth || !renderHeight)
        fail("MouseEvents requires an open PsychMetal window.");
    pm::MouseEvents out{};
    std::lock_guard<std::mutex> guard(iosInputLock);
    if (!iosPointerListening) {
        iosPointerListening = true;
        return out;
    }
    out.events.reserve(iosPointerCount);
    for (unsigned i = 0; i < iosPointerCount; i++)
        out.events.push_back(iosPointerEvents[(iosPointerHead + i) % PM_POINTER_EVENTS]);
    out.dropped = iosPointerDropped;
    iosPointerHead = iosPointerCount = 0;
    iosPointerDropped = 0;
    return out;
}
