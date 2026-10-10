// PsychMetalMex.cpp — the MATLAB / Octave front end: PsychMetalCore's
// mexFunction over the host-neutral engine (PsychMetalEngine.h).
// SPDX-License-Identifier: MIT
//
// PsychMetal.m is the only intended caller. This file only unpacks mxArrays,
// calls the engine and packs the results; validation beyond "is this the right
// kind of MATLAB value" belongs to the engine.
#include "mex.h"
#include "PsychMetalEngine.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <strings.h>

namespace {

char command[64];
bool is(const char *s) { return strcasecmp(command, s) == 0; }

[[noreturn]] void fail(const char *s) { throw pm::Error(pm::kErrGeneral, s); }

// A real, dense, one-element numeric value, then finite.
double scalar(const mxArray *a, const char *name) {
    if (!mxIsNumeric(a) || mxIsComplex(a) || mxIsSparse(a) || mxGetNumberOfElements(a) != 1)
        pm::failNotScalar(name);
    return pm::checkFinite(mxGetScalar(a), name);
}
uint64_t unsignedScalar(const mxArray *a, const char *name, uint64_t maximum) {
    return pm::checkUnsigned(scalar(a, name), name, maximum);
}

bool isRealDouble(const mxArray *a) { return mxIsDouble(a) && !mxIsComplex(a) && !mxIsSparse(a); }

pm::ScalarType typeOf(const mxArray *a, size_t &elementSize) {
    elementSize = 0;
    if (mxIsComplex(a) || mxIsSparse(a)) return pm::ScalarType::Other;
    if (mxIsDouble(a))  { elementSize = 8; return pm::ScalarType::Float64; }
    if (mxIsSingle(a))  { elementSize = 4; return pm::ScalarType::Float32; }
    if (mxIsUint8(a))   { elementSize = 1; return pm::ScalarType::UInt8; }
    if (mxIsLogical(a)) { elementSize = sizeof(mxLogical); return pm::ScalarType::Bool; }
    return pm::ScalarType::Other;
}

// An HxW or HxWxC MATLAB array as a column-major (H, W[, C]) view, read in place.
pm::ArrayView imageView(const mxArray *a) {
    pm::ArrayView v;
    size_t es = 0;
    v.type = typeOf(a, es);
    mwSize nd = mxGetNumberOfDimensions(a);
    if (nd > 3) { v.type = pm::ScalarType::Other; nd = 3; }
    const mwSize *d = mxGetDimensions(a);
    v.data = mxGetData(a);
    v.ndim = (int)nd;
    for (mwSize i = 0; i < nd; i++) v.shape[i] = d[i];
    v.strides = {(ptrdiff_t)es, (ptrdiff_t)(es * v.shape[0]), (ptrdiff_t)(es * v.shape[0] * v.shape[1])};
    return v;
}

// AddShapes arguments. A 1xN MATLAB row is logical shape (N); a 4xN matrix is
// (N, 4), since each shape's four values are contiguous in column-major order.
// Anything else is passed with ndim 0 so the engine reports it.
pm::ArrayView rowView(const mxArray *a) {
    pm::ArrayView v;
    size_t es = 0;
    v.type = typeOf(a, es);
    if (v.type != pm::ScalarType::Float64) return v;
    v.data = mxGetData(a);
    if (mxGetNumberOfDimensions(a) == 2 && mxGetM(a) == 1) {
        v.ndim = 1; v.shape[0] = mxGetN(a); v.strides[0] = 8;
    }
    return v;
}
pm::ArrayView columnsView(const mxArray *a) {
    pm::ArrayView v;
    size_t es = 0;
    v.type = typeOf(a, es);
    if (v.type != pm::ScalarType::Float64) return v;
    v.data = mxGetData(a);
    if (mxGetNumberOfDimensions(a) == 2 && mxGetM(a) == 4) {
        v.ndim = 2; v.shape[0] = mxGetN(a); v.shape[1] = 4; v.strides[0] = 32; v.strides[1] = 8;
    }
    return v;
}

// A MATLAB character row as UTF-8.
std::string text(const mxArray *a, const char *name) {
    // Octave's characters are UTF-8 bytes already; MATLAB's are UTF-16 and are converted.
#ifdef MATLAB_MEX_FILE
    char *s = (mxIsChar(a) && mxGetM(a) <= 1) ? mxArrayToUTF8String(a) : nullptr;
#else
    char *s = (mxIsChar(a) && mxGetM(a) <= 1) ? mxArrayToString(a) : nullptr;
#endif
    if (!s) {
        char message[96];
        snprintf(message, sizeof(message), "%s must be a character row.", name);
        fail(message);
    }
    std::string out(s);
    mxFree(s);
    return out;
}

mxArray *row(std::initializer_list<double> values) {
    mxArray *m = mxCreateDoubleMatrix(1, values.size(), mxREAL);
    double *p = mxGetPr(m);
    for (double v : values) *p++ = v;
    return m;
}
mxArray *rect4(const pm::Rect4 &r) { return row({r[0], r[1], r[2], r[3]}); }

mxArray *startupMatrix(const std::vector<pm::StartupRecord> &records) {
    size_t n = records.size();
    mxArray *out = mxCreateDoubleMatrix(n, 6, mxREAL);
    double *v = mxGetPr(out);
    for (size_t i = 0; i < n; i++) {
        const pm::StartupRecord &r = records[i];
        v[i] = (double)r.token; v[i + n] = r.status; v[i + 2 * n] = r.presentedTime;
        v[i + 3 * n] = r.callbackTime; v[i + 4 * n] = r.gpuDone; v[i + 5 * n] = r.committedTime;
    }
    return out;
}

mxArray *historyMatrix(const std::vector<pm::FrameRecord> &records) {
    size_t count = records.size();
    mxArray *out = mxCreateDoubleMatrix(count, 16, mxREAL);
    double *v = mxGetPr(out);
    for (size_t row = 0; row < count; row++) {
        const pm::FrameRecord &r = records[row];
        const double cols[16] = {(double)r.token, r.projected, r.presented, (double)r.status,
                                 r.scheduledAt, r.callback, (double)r.commandStatus, r.requestedTime,
                                 r.gpuStart, r.gpuEnd, r.presentRequest, r.presentCallMs, r.committedAt,
                                 r.drawableAcquireMs, r.encodeMs, r.prefetchMs};
        for (size_t c = 0; c < 16; c++) v[row + count * c] = cols[c];
    }
    return out;
}

mxArray *diagnosticStruct(const pm::DiagnosticSummary &d) {
    const char *n[] = {
        "confirmedPresentations", "missingPresentedTimes",
        "lastTargetErrorMs",     "lastConfirmDelayMs",     "appKitScreenIndex",
        "cgDisplayID",           "renderWidth",            "renderHeight",
        "drawableWidth",         "drawableHeight",        "inFlight",
        "requestedDrawableCount",  "drawableCountReadback",
        "hostBundleIdentifier",  "activationPolicyBefore",
        "activationPolicyAfter", "activationPolicyPromotionAttempted",
        "activationPolicyPromotionSucceeded", "macOSVersion", "processName",
        "machTimebaseHz",        "machTickNanoseconds",
        "waitForConfirm",        "measuredRefreshHz",
        "gridSamples",           "directNoDrawable",       "directConfirmTimeouts",
        "leadEstimateMs",
        "pipelineEstimateMs",      "gpuEstimateMs",          "displaySyncEnabled",
        "displayCaptured",         "readbackEnabled",
        "modePointWidth",          "modePixelWidth",         "largestModePixelWidth",
        "shapesAppended",          "shapesEncoded",          "shapeEncodeCalls",
        "texturesCreated",         "texturesDrawn", "textureAllocations", "textureUpdates", "lastTextureUploadMs",
        "lastShapeRect",           "lastShapeColor",         "lastShapeKind",
        "windowFrame",             "viewBounds",             "layerFrame",
        "screenFrame",             "screenVisibleFrame",     "screenSafeAreaInsets",
        "cgDisplayBounds",         "backingScaleFactor", "keyScanMaxMs", "secureQueryMaxMs", "keyScanMeanMs", "secureQueryMeanMs", "keyReadCount"};
    mxArray *s = mxCreateStructMatrix(1, 1, (int)(sizeof(n) / sizeof(n[0])), n);
    auto num = [&](const char *f, double v) { mxSetField(s, 0, f, mxCreateDoubleScalar(v)); };
    auto flag = [&](const char *f, bool v) { mxSetField(s, 0, f, mxCreateLogicalScalar(v)); };
    auto text = [&](const char *f, const std::string &v) { mxSetField(s, 0, f, mxCreateString(v.c_str())); };
    auto r4 = [&](const char *f, const pm::Rect4 &v) { mxSetField(s, 0, f, rect4(v)); };
    num("confirmedPresentations", d.confirmedPresentations);
    num("missingPresentedTimes", d.missingPresentedTimes);
    num("lastTargetErrorMs", d.lastTargetErrorMs);
    num("lastConfirmDelayMs", d.lastConfirmDelayMs);
    num("appKitScreenIndex", d.appKitScreenIndex);
    num("cgDisplayID", d.cgDisplayID);
    num("renderWidth", d.renderWidth);
    num("renderHeight", d.renderHeight);
    num("drawableWidth", d.drawableWidth);
    num("drawableHeight", d.drawableHeight);
    num("inFlight", d.inFlight);
    num("requestedDrawableCount", d.requestedDrawableCount);
    num("drawableCountReadback", d.drawableCountReadback);
    text("hostBundleIdentifier", d.hostBundleIdentifier);
    num("activationPolicyBefore", d.activationPolicyBefore);
    num("activationPolicyAfter", d.activationPolicyAfter);
    flag("activationPolicyPromotionAttempted", d.activationPolicyPromotionAttempted);
    flag("activationPolicyPromotionSucceeded", d.activationPolicyPromotionSucceeded);
    text("macOSVersion", d.macOSVersion);
    text("processName", d.processName);
    num("machTimebaseHz", d.machTimebaseHz);
    num("machTickNanoseconds", d.machTickNanoseconds);
    flag("waitForConfirm", d.waitForConfirm);
    num("measuredRefreshHz", d.measuredRefreshHz);
    num("gridSamples", d.gridSamples);
    num("directNoDrawable", d.directNoDrawable);
    num("directConfirmTimeouts", d.directConfirmTimeouts);
    num("leadEstimateMs", d.leadEstimateMs);
    num("pipelineEstimateMs", d.pipelineEstimateMs);
    num("gpuEstimateMs", d.gpuEstimateMs);
    flag("displaySyncEnabled", d.displaySyncEnabled);
    flag("displayCaptured", d.displayCaptured);
    flag("readbackEnabled", d.readbackEnabled);
    num("modePointWidth", d.modePointWidth);
    num("modePixelWidth", d.modePixelWidth);
    num("largestModePixelWidth", d.largestModePixelWidth);
    num("shapesAppended", d.shapesAppended);
    num("shapesEncoded", d.shapesEncoded);
    num("shapeEncodeCalls", d.shapeEncodeCalls);
    num("texturesCreated", d.texturesCreated);
    num("texturesDrawn", d.texturesDrawn);
    num("textureAllocations", d.textureAllocations);
    num("textureUpdates", d.textureUpdates);
    num("lastTextureUploadMs", d.lastTextureUploadMs);
    r4("lastShapeRect", d.lastShapeRect);
    r4("lastShapeColor", d.lastShapeColor);
    num("lastShapeKind", d.lastShapeKind);
    r4("windowFrame", d.windowFrame);
    r4("viewBounds", d.viewBounds);
    r4("layerFrame", d.layerFrame);
    r4("screenFrame", d.screenFrame);
    r4("screenVisibleFrame", d.screenVisibleFrame);
    r4("screenSafeAreaInsets", d.screenSafeAreaInsets);
    r4("cgDisplayBounds", d.cgDisplayBounds);
    num("backingScaleFactor", d.backingScaleFactor);
    num("keyScanMaxMs", d.keyScanMaxMs);
    num("secureQueryMaxMs", d.secureQueryMaxMs);
    num("keyScanMeanMs", d.keyScanMeanMs);
    num("secureQueryMeanMs", d.secureQueryMeanMs);
    num("keyReadCount", d.keyReadCount);
    return s;
}

void warnHook(const char *id, const char *message) { mexWarnMsgIdAndTxt(id, "%s", message); }
void pinHook() { mexLock(); }
void unpinHook() { mexUnlock(); }
void atExit() { pm::shutdown(); }

void dispatch(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    if (nrhs < 1 || !mxIsChar(prhs[0]) || mxGetNumberOfElements(prhs[0]) >= sizeof(command) ||
        mxGetString(prhs[0], command, sizeof(command)))
        fail("A short command string is required.");

    // --- session lifecycle ------------------------------------------------
    if (is("DefaultPresentation")) {
        if (nrhs != 1 || nlhs != 1) fail("DefaultPresentation returns one logical.");
        plhs[0] = mxCreateLogicalScalar(pm::defaultDisplayLink());
        return;
    }
    if (is("PlayTimeline")) {
        if((nrhs!=3 && nrhs!=4) || nlhs!=1) fail("PlayTimeline takes frames, tracks and optional keyframes, returning one result.");
        pm::ArrayView keys;if(nrhs==4)keys=imageView(prhs[3]);
        auto r=pm::playTimeline(unsignedScalar(prhs[1],"timeline frames",1000000),imageView(prhs[2]),nrhs==4?&keys:nullptr);
        const char *names[]={"submitted","firstToken","lastToken","cancelled","expectedRefreshHz","lastQueueMs",
                             "lastFlipMs","lastConfirmed","shown","late","lateRefreshes","firstLateSample",
                             "meanSampleMs","longestIntervalMs"};
        plhs[0]=mxCreateStructMatrix(1,1,14,names);
        auto number=[&](const char *name,double v){mxSetField(plhs[0],0,name,mxCreateDoubleScalar(v));};
        number("submitted",(double)r.submitted);number("firstToken",(double)r.firstToken);
        number("lastToken",(double)r.lastToken);
        mxSetField(plhs[0],0,"cancelled",mxCreateLogicalScalar(r.cancelled));
        number("expectedRefreshHz",r.expectedRefreshHz);number("lastQueueMs",r.lastQueueMs);
        number("lastFlipMs",r.lastFlipMs);
        mxSetField(plhs[0],0,"lastConfirmed",mxCreateLogicalScalar(r.lastConfirmed));
        number("shown",(double)r.shown);number("late",(double)r.late);number("lateRefreshes",(double)r.lateRefreshes);
        // MATLAB counts samples from 1, as it counts draws.
        number("firstLateSample",r.firstLateSample+1);
        number("meanSampleMs",r.meanSampleMs);number("longestIntervalMs",r.longestIntervalMs);return;
    }
    if (is("Environment")) {
        if(nrhs!=1 || nlhs!=1) fail("Environment returns one struct and takes no arguments.");
        auto e=pm::environment();
        const char *names[]={"engineVersion","platform","osVersion","gpuName","gpuAvailable"};
        plhs[0]=mxCreateStructMatrix(1,1,5,names);
        mxSetField(plhs[0],0,"engineVersion",mxCreateString(e.engineVersion.c_str()));
        mxSetField(plhs[0],0,"platform",mxCreateString(e.platform.c_str()));
        mxSetField(plhs[0],0,"osVersion",mxCreateString(e.osVersion.c_str()));
        mxSetField(plhs[0],0,"gpuName",mxCreateString(e.gpuName.c_str()));
        mxSetField(plhs[0],0,"gpuAvailable",mxCreateLogicalScalar(e.gpuAvailable));
        return;
    }
    if (is("Version")) {
        if (nrhs != 1 || nlhs != 1) fail("Version returns one string.");
        plhs[0] = mxCreateString(pm::version());
        return;
    }
    if (is("PrepareApp")) {
        if (nrhs != 1 || nlhs != 0) fail("PrepareApp takes no arguments or outputs.");
        pm::prepareApp();
        return;
    }
    if (is("StartupHistory")) {
        if (nrhs != 1 || nlhs != 1) fail("StartupHistory returns one matrix.");
        plhs[0] = startupMatrix(pm::startupHistory());
        return;
    }
    if (is("ConfirmStartup")) {
        if (nrhs != 1 || nlhs != 1) fail("ConfirmStartup returns the initialization history.");
        plhs[0] = startupMatrix(pm::confirmStartup());
        return;
    }
    if (is("Open")) {
        if ((nrhs < 3 || nrhs > 10) || nlhs != 6)
            fail("Open needs screenIndex,drawableCount[,waitForConfirm"
                 "[,displaySync[,captureDisplay[,refreshHz[,readback[,bitDepth[,displayLink]]]]]]] "
                 "and returns width,height,ifi,pointWidth,pointHeight,sessionToken.");
        pm::OpenOptions o;
        o.screenIndex = scalar(prhs[1], "screen index");
        o.drawableCount = unsignedScalar(prhs[2], "maximum drawable count", 3);
        if (nrhs >= 6) o.captureDisplay = unsignedScalar(prhs[5], "capture display", 1) != 0;
        if (nrhs >= 5) o.displaySync = unsignedScalar(prhs[4], "display sync", 1) != 0;
        if (nrhs >= 4) o.waitForConfirm = unsignedScalar(prhs[3], "wait for confirmation", 1) != 0;
        // An empty refreshHz is no override, so readback can follow it.
        if (nrhs >= 7 && !mxIsEmpty(prhs[6])) o.refreshHz = scalar(prhs[6], "refreshHz");
        if (nrhs >= 8) o.readback = unsignedScalar(prhs[7], "readback", 1) != 0;
        if (nrhs >= 9) o.bitDepth = unsignedScalar(prhs[8], "bit depth", 10);
        if (nrhs == 10) o.displayLink = unsignedScalar(prhs[9], "display link", 1) != 0;
        pm::OpenResult r = pm::openSession(o);
        plhs[0] = mxCreateDoubleScalar(r.pixelWidth);
        plhs[1] = mxCreateDoubleScalar(r.pixelHeight);
        plhs[2] = mxCreateDoubleScalar(r.ifi);
        plhs[3] = mxCreateDoubleScalar(r.pointWidth);
        plhs[4] = mxCreateDoubleScalar(r.pointHeight);
        plhs[5] = mxCreateDoubleScalar((double)r.sessionToken);
        return;
    }
    if (is("Close")) {
        if (nrhs != 1 || nlhs != 0) fail("Close takes no arguments or outputs.");
        pm::closeSession();
        return;
    }

    // --- presentation -----------------------------------------------------
    if (is("Flip")) {
        if ((nrhs != 1 && nrhs != 2) || nlhs != 1) fail("Flip accepts an optional target and returns one record.");
        pm::FlipResult r = pm::flip(nrhs == 2 ? scalar(prhs[1], "target") : 0);
        plhs[0] = row({r.time, r.confirmed ? 1.0 : 0.0, r.slipRefreshes, r.gridPeriod,
                       r.queueMs, r.callMs, r.returnTime, (double)r.token});
        return;
    }
    if (is("FlipStatus")) {
        if (nrhs != 1 || nlhs != 1) fail("FlipStatus takes no arguments and returns one row.");
        pm::FlipStatus s = pm::flipStatus();
        plhs[0] = row({s.confirmed ? 1.0 : 0.0, s.dropped ? 1.0 : 0.0, (double)s.droppedFrames});
        return;
    }
    if (is("QueueFlip")) {
        if (nrhs != 2 || nlhs != 1) fail("QueueFlip takes a time and returns one row.");
        pm::QueueResult r = pm::queueFlip(scalar(prhs[1], "presentation time"));
        plhs[0] = row({(double)r.token, r.pending, r.capacity});
        return;
    }
    if (is("QueueResults")) {
        if (nrhs != 2 || nlhs != 1) fail("QueueResults takes a wait flag and returns one matrix.");
        std::vector<pm::QueuedFrame> frames = pm::queueResults(unsignedScalar(prhs[1], "wait", 1) != 0);
        size_t n = frames.size();
        plhs[0] = mxCreateDoubleMatrix(n, 4, mxREAL);
        double *out = mxGetPr(plhs[0]);
        for (size_t i = 0; i < n; i++) {
            out[i] = frames[i].requested; out[i + n] = frames[i].presented;
            out[i + 2 * n] = frames[i].status; out[i + 3 * n] = (double)frames[i].token;
        }
        return;
    }
    if (is("QueueCancel")) {
        if (nrhs != 1 || nlhs != 1) fail("QueueCancel takes no arguments and returns a count.");
        plhs[0] = mxCreateDoubleScalar((double)pm::queueCancel());
        return;
    }
    if (is("PrepareFlip")) {
        if (nrhs != 1 || nlhs != 1) fail("PrepareFlip takes no arguments and one output.");
        plhs[0] = mxCreateDoubleScalar((double)pm::prepareFlip());
        return;
    }
    if (is("PresentNow")) {
        if (nrhs != 1 || nlhs != 1) fail("PresentNow takes no arguments and one output.");
        pm::PresentResult r = pm::presentNow();
        plhs[0] = row({r.time, r.callMs});
        return;
    }
    if (is("SetDisplaySync")) {
        if (nrhs != 2 || nlhs != 0) fail("SetDisplaySync needs one flag and no outputs.");
        pm::setDisplaySync(unsignedScalar(prhs[1], "display sync", 1) != 0);
        return;
    }
    if (is("PrefetchDrawable")) {
        if (nrhs != 2 || nlhs != 0) fail("PrefetchDrawable takes one logical argument.");
        pm::setPrefetchDrawable(unsignedScalar(prhs[1], "prefetch flag", 1) != 0);
        return;
    }

    // --- refresh grid -----------------------------------------------------
    if (is("GridAnchor")) {
        if (nrhs != 1 || nlhs != 1) fail("GridAnchor takes no arguments and one output.");
        pm::GridAnchor g = pm::gridAnchor();
        plhs[0] = row({g.anchor, g.period, g.samples});
        return;
    }
    if (is("NextPhase")) {
        if (nrhs != 3 || nlhs != 1) fail("NextPhase needs a time, a phase and one output.");
        double after = scalar(prhs[1], "time");
        double phase = scalar(prhs[2], "phase");
        plhs[0] = mxCreateDoubleScalar(pm::nextPhase(after, phase));
        return;
    }
    if (is("NextRefresh")) {
        if (nrhs != 2 || nlhs != 1) fail("NextRefresh needs one time and one output.");
        plhs[0] = mxCreateDoubleScalar(pm::nextRefresh(scalar(prhs[1], "time")));
        return;
    }
    if (is("WaitToDraw")) {
        if (nrhs != 3 || nlhs != 1) fail("WaitToDraw needs a target presentation time and a drawing budget.");
        double target = scalar(prhs[1], "target presentation time");
        double budget = scalar(prhs[2], "drawing budget");
        pm::WaitToDrawResult r = pm::waitToDraw(target, budget);
        plhs[0] = row({r.wokeAt, r.lead, r.deadline});
        return;
    }

    // --- drawing ------------------------------------------------------------
    if (is("SetBackgroundColor")) {
        if (nrhs != 5 || nlhs != 0) fail("SetBackgroundColor needs r, g, b and a.");
        double c[4];
        for (int a = 1; a <= 4; a++) c[a - 1] = scalar(prhs[a], "background colour component");
        pm::setBackgroundColor(c[0], c[1], c[2], c[3]);
        return;
    }
    if (is("CheckStimulus")) {
        if(nrhs!=2 || nlhs!=0) fail("CheckStimulus needs a parameter vector.");
        pm::checkStimulus(rowView(prhs[1])); return;
    }
    if (is("CheckMask")) {
        if(nrhs!=2 || nlhs!=0) fail("CheckMask needs a parameter vector.");
        pm::checkMask(rowView(prhs[1]));return;
    }
    if (is("DrawMaskedTexture")) {
        if((nrhs!=4 && nrhs!=5) || nlhs!=0)fail("DrawMaskedTexture needs source, parameters, mask and optional coverage.");
        pm::ArrayView c;if(nrhs==5)c=rowView(prhs[4]);
        pm::drawMaskedTexture(unsignedScalar(prhs[1],"texture",pm::kMaxId),rowView(prhs[2]),
                              unsignedScalar(prhs[3],"mask",pm::kMaxId),nrhs==5 ? &c : nullptr);return;
    }
    if(is("CreateShader")) {
        if(nrhs!=2 || nlhs!=1)fail("CreateShader needs source and one output.");
        if(mxIsChar(prhs[1]))for(size_t i=0;i<mxGetNumberOfElements(prhs[1]);i++)if(mxGetChars(prhs[1])[i]==0)fail("Shader source cannot contain NUL.");
        plhs[0]=mxCreateDoubleScalar((double)pm::createShader(text(prhs[1],"Shader source")));return;
    }
    if(is("CloseShader")) {
        if(nrhs!=2 || nlhs!=0)fail("CloseShader needs one handle and no outputs.");
        pm::closeShader(unsignedScalar(prhs[1],"shader",pm::kMaxId));return;
    }
    if(is("DrawShader")) {
        if((nrhs!=5 && nrhs!=6) || nlhs!=0)fail("DrawShader needs shader, parameters, destination, mask and optional coverage.");
        pm::ArrayView c;if(nrhs==6)c=rowView(prhs[5]);
        pm::drawShader(unsignedScalar(prhs[1],"shader",pm::kMaxId),rowView(prhs[2]),rowView(prhs[3]),unsignedScalar(prhs[4],"mask",pm::kMaxId),nrhs==6?&c:nullptr);return;
    }
    if (is("DrawStimulus")) {
        if((nrhs!=4 && nrhs!=5) || nlhs!=0) fail("DrawStimulus needs parameters, destination, image mask and optional coverage.");
        pm::ArrayView coverage;if(nrhs==5) coverage=rowView(prhs[4]);
        pm::drawStimulus(rowView(prhs[1]),rowView(prhs[2]),unsignedScalar(prhs[3],"mask",pm::kMaxId),nrhs==5 ? &coverage : nullptr); return;
    }
    if (is("AddShapes")) {
        if (nrhs != 6 || nlhs != 0) fail("AddShapes needs kind, param, rect, color and extra arrays.");
        pm::addShapes(rowView(prhs[1]), rowView(prhs[2]), columnsView(prhs[3]),
                      columnsView(prhs[4]), columnsView(prhs[5]));
        return;
    }
    if (is("MakeTexture")) {
        if (nrhs != 2 || nlhs != 1) fail("MakeTexture takes a dense image and returns a handle.");
        plhs[0] = mxCreateDoubleScalar((double)pm::makeTexture(imageView(prhs[1])));
        return;
    }
    if (is("UpdateTexture")) {
        if ((nrhs != 3 && nrhs != 5) || nlhs != 0)
            fail("UpdateTexture takes a texture handle and image, and optionally the left and top of a part.");
        uint64_t handle = unsignedScalar(prhs[1], "texture handle", pm::kMaxId);
        if (nrhs == 3) {
            pm::updateTexture(handle, imageView(prhs[2]));
        } else {
            double x = scalar(prhs[3], "texture left");
            double y = scalar(prhs[4], "texture top");
            pm::updateTextureRegion(handle, imageView(prhs[2]), x, y);
        }
        return;
    }
    if (is("DrawTextures")) {
        if (nrhs != 7 || nlhs != 0)
            fail("DrawTextures needs handles, srcRects, dstRects, angles, tints and filterModes.");
        pm::drawTextures(rowView(prhs[1]), columnsView(prhs[2]), columnsView(prhs[3]),
                         rowView(prhs[4]), columnsView(prhs[5]), rowView(prhs[6]));
        return;
    }
    if (is("CloseTexture")) {
        if (nrhs != 2 || nlhs != 0) fail("CloseTexture needs a texture handle.");
        pm::closeTexture(unsignedScalar(prhs[1], "texture handle", pm::kMaxId));
        return;
    }
    if (is("BlendMode")) {
        if (nrhs != 2 || nlhs != 0) fail("BlendMode takes one mode and has no outputs.");
        pm::setBlendMode(unsignedScalar(prhs[1], "blend mode", 2));
        return;
    }
    if (is("Clip")) {
        if (nrhs > 2 || nlhs != 0) fail("Clip takes an optional rect and has no outputs.");
        std::optional<pm::Rect4> rect;
        if (nrhs == 2) {
            if (!isRealDouble(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 4)
                fail("The clip rect must be [left top right bottom] in whole pixels.");
            const double *r = mxGetPr(prhs[1]);
            rect = pm::Rect4{r[0], r[1], r[2], r[3]};
        }
        pm::setClip(rect);
        return;
    }
    if (is("OpenOffscreen")) {
        if (nrhs != 4 || nlhs != 1) fail("OpenOffscreen takes width, height and RGBA, and returns a handle.");
        double w = scalar(prhs[1], "offscreen width"), h = scalar(prhs[2], "offscreen height");
        if (!isRealDouble(prhs[3]) || mxGetNumberOfElements(prhs[3]) != 4)
            fail("Offscreen window colour must be four real doubles, RGBA.");
        const double *c = mxGetPr(prhs[3]);
        plhs[0] = mxCreateDoubleScalar((double)pm::openOffscreen(w, h, pm::Rect4{c[0], c[1], c[2], c[3]}));
        return;
    }
    if (is("SetTarget")) {
        if (nrhs != 2 || nlhs != 0) fail("SetTarget takes one handle and has no outputs.");
        pm::setTarget(unsignedScalar(prhs[1], "target handle", pm::kMaxId));
        return;
    }
    if (is("DrawPolygon")) {
        if (nrhs != 4 || nlhs != 0) fail("DrawPolygon takes points, RGBA and a pen width, and has no outputs.");
        // A 2xN MATLAB matrix is (N, 2): each point's two values are contiguous.
        pm::ArrayView v;
        size_t es = 0;
        v.type = typeOf(prhs[1], es);
        if (v.type == pm::ScalarType::Float64 && mxGetNumberOfDimensions(prhs[1]) == 2 && mxGetM(prhs[1]) == 2) {
            v.data = mxGetData(prhs[1]);
            v.ndim = 2;
            v.shape = {mxGetN(prhs[1]), 2, 0};
            v.strides = {16, 8, 0};
        }
        if (!isRealDouble(prhs[2]) || mxGetNumberOfElements(prhs[2]) != 4)
            fail("Polygon colour must be four real doubles, RGBA.");
        const double *c = mxGetPr(prhs[2]);
        pm::drawPolygon(v, pm::Rect4{c[0], c[1], c[2], c[3]}, scalar(prhs[3], "pen width"));
        return;
    }
    if (is("Gamma")) {
        if (nrhs != 4 || nlhs != 0) fail("Gamma takes three exponents and has no outputs.");
        double e[3];
        for (int c = 0; c < 3; c++) e[c] = scalar(prhs[c + 1], "gamma exponent");
        pm::setGamma(e[0], e[1], e[2]);
        return;
    }
    if (is("GammaTable")) {
        if (nrhs != 2 || nlhs != 0) fail("GammaTable takes one Nx3 table and has no outputs.");
        // An Nx3 MATLAB matrix is (N, 3): rows 8 bytes apart, columns 8 * N.
        pm::ArrayView v;
        size_t es = 0;
        v.type = typeOf(prhs[1], es);
        if (v.type == pm::ScalarType::Float64 && mxGetNumberOfDimensions(prhs[1]) == 2) {
            v.data = mxGetData(prhs[1]);
            v.ndim = 2;
            v.shape = {mxGetM(prhs[1]), mxGetN(prhs[1]), 0};
            v.strides = {8, (ptrdiff_t)(8 * mxGetM(prhs[1])), 0};
        }
        pm::setGammaTable(v);
        return;
    }
    if (is("TextBounds")) {
        if (nrhs != 4 || nlhs != 1) fail("TextBounds takes text, font and size, and returns one row.");
        std::string s = text(prhs[1], "Text"), font = text(prhs[2], "Font");
        pm::TextBounds b = pm::textBounds(s, font, scalar(prhs[3], "text size"));
        plhs[0] = row({b.width, b.height, b.ascent});
        return;
    }
    if (is("DrawText")) {
        if (nrhs != 7 || nlhs != 1) fail("DrawText takes text, font, size, x, y and RGBA, and returns one row.");
        std::string s = text(prhs[1], "Text"), font = text(prhs[2], "Font");
        double size = scalar(prhs[3], "text size");
        double x = scalar(prhs[4], "text x");
        double y = scalar(prhs[5], "text y");
        if (!isRealDouble(prhs[6]) || mxGetNumberOfElements(prhs[6]) != 4)
            fail("Text colour must be four real doubles, RGBA.");
        const double *c = mxGetPr(prhs[6]);
        pm::TextBounds b = pm::drawText(s, font, size, x, y, pm::Rect4{c[0], c[1], c[2], c[3]});
        plhs[0] = row({b.width, b.height, b.ascent});
        return;
    }
    if (is("GetImage")) {
        if ((nrhs != 1 && nrhs != 2) || nlhs != 1) fail("GetImage accepts an optional rect and returns one image.");
        std::optional<pm::Rect4> rect;
        if (nrhs == 2) {
            if (!isRealDouble(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 4)
                fail("GetImage rect must be [left top right bottom] in whole pixels inside the window.");
            const double *r = mxGetPr(prhs[1]);
            rect = pm::Rect4{r[0], r[1], r[2], r[3]};
        }
        pm::ImageRegion g = pm::checkImageRect(rect);
        mwSize H = (mwSize)g.height, W = (mwSize)g.width;
        mwSize dims[3] = {H, W, 3};
        if (g.bits == 10) {      // uint16, 0..1023
            plhs[0] = mxCreateNumericArray(3, dims, mxUINT16_CLASS, mxREAL);
            pm::MutableWordView out;
            out.data = (uint16_t *)mxGetData(plhs[0]);
            out.ndim = 3;
            out.shape = {(size_t)H, (size_t)W, 3};
            out.strides = {2, (ptrdiff_t)(2 * H), (ptrdiff_t)(2 * H * W)};   // column-major
            pm::getImage16(g, out);
            return;
        }
        plhs[0] = mxCreateNumericArray(3, dims, mxUINT8_CLASS, mxREAL);
        pm::MutableByteView out;
        out.data = (uint8_t *)mxGetData(plhs[0]);
        out.ndim = 3;
        out.shape = {(size_t)H, (size_t)W, 3};
        out.strides = {1, (ptrdiff_t)H, (ptrdiff_t)(H * W)};   // column-major
        pm::getImage(g, out);
        return;
    }
    if (is("NoiseValues")) {
        if (nrhs != 8 || nlhs != 1) fail("NoiseValues needs width,height,seed,normal,colour,mean,spread.");
        pm::NoiseRequest q;
        q.width = scalar(prhs[1], "width");
        q.height = scalar(prhs[2], "height");
        q.seed = scalar(prhs[3], "seed");
        q.normal = scalar(prhs[4], "normal flag") != 0.0;
        q.colour = scalar(prhs[5], "colour flag") != 0.0;
        if (!isRealDouble(prhs[6]) || mxGetNumberOfElements(prhs[6]) != 3)
            fail("Noise mean must be a 3-element RGB vector.");
        const double *mean = mxGetPr(prhs[6]);
        q.mean = {mean[0], mean[1], mean[2]};
        q.spread = scalar(prhs[7], "spread");
        pm::checkNoiseRequest(q);
        mwSize H = (mwSize)q.height, W = (mwSize)q.width;
        mwSize dims[3] = {H, W, 3};
        plhs[0] = mxCreateNumericArray(q.colour ? 3 : 2, dims, mxDOUBLE_CLASS, mxREAL);
        pm::MutableArrayView out;
        out.data = mxGetPr(plhs[0]);
        out.ndim = q.colour ? 3 : 2;
        out.shape = {(size_t)H, (size_t)W, 3};
        out.strides = {8, (ptrdiff_t)(8 * H), (ptrdiff_t)(8 * H * W)};
        pm::noiseValues(q, out);
        return;
    }

    // --- display modes and cursor --------------------------------------------
    if (is("Modes")) {
        if (nrhs != 2 || nlhs != 1) fail("Modes needs a screen index and returns one matrix.");
        std::vector<pm::DisplayMode> m = pm::modes(scalar(prhs[1], "screen index"));
        size_t n = m.size();
        plhs[0] = mxCreateDoubleMatrix(n, 5, mxREAL);
        double *v = mxGetPr(plhs[0]);
        for (size_t i = 0; i < n; i++) {
            v[i] = m[i].pointWidth; v[i + n] = m[i].pointHeight; v[i + 2 * n] = m[i].pixelWidth;
            v[i + 3 * n] = m[i].pixelHeight; v[i + 4 * n] = m[i].refreshHz;
        }
        return;
    }
    if (is("SetMode")) {
        if ((nrhs != 4 && nrhs != 5) || nlhs != 0) fail("SetMode needs screenIndex, width, height and optional refreshHz, and has no outputs.");
        double si = scalar(prhs[1], "screen index");
        double w = scalar(prhs[2], "width"), h = scalar(prhs[3], "height");
        pm::setMode(si, w, h, nrhs == 5 ? scalar(prhs[4], "refresh rate") : 0);
        return;
    }
    if (is("LinkInfo")) {
        if (nrhs != 1 || nlhs != 1) fail("LinkInfo takes no arguments and returns one row.");
        pm::LinkInfo k = pm::linkInfo();
        plhs[0] = row({k.lanes, k.laneGbps, k.payloadGbps, k.pixelGbps, k.compressed});
        return;
    }
    if (is("Cursor")) {
        if (nrhs != 2 || nlhs != 0) fail("Cursor takes one logical argument.");
        pm::setCursorVisible(scalar(prhs[1], "show cursor") != 0.0);
        return;
    }

    // --- input ------------------------------------------------------------------
    if (is("MouseEvents")) {
        if (nrhs != 1 || nlhs != 2) fail("MouseEvents returns events and dropped count.");
        pm::MouseEvents e = pm::mouseEvents();
        size_t n = e.events.size();
        plhs[0] = mxCreateDoubleMatrix(n, 5, mxREAL);
        double *out = mxGetPr(plhs[0]);
        for (size_t i = 0; i < n; i++) {
            out[i] = e.events[i].time; out[i + n] = e.events[i].button; out[i + 2 * n] = e.events[i].pressed ? 1 : 0;
            out[i + 3 * n] = e.events[i].x; out[i + 4 * n] = e.events[i].y;
        }
        plhs[1] = mxCreateDoubleScalar((double)e.dropped);
        return;
    }
    if (is("TouchEvents")) {
        if (nrhs != 1 || nlhs != 2) fail("TouchEvents returns events and dropped count.");
        pm::TouchEvents e = pm::touchEvents();
        size_t n = e.events.size();
        plhs[0] = mxCreateDoubleMatrix(n, 5, mxREAL);
        double *out = mxGetPr(plhs[0]);
        for (size_t i = 0; i < n; i++) {
            out[i] = e.events[i].time; out[i + n] = e.events[i].finger; out[i + 2 * n] = e.events[i].phase;
            out[i + 3 * n] = e.events[i].x; out[i + 4 * n] = e.events[i].y;
        }
        plhs[1] = mxCreateDoubleScalar((double)e.dropped);
        return;
    }
    if (is("Mouse")) {
        if (nrhs != 1 || nlhs != 3) fail("Mouse takes no arguments and returns x, y and buttons.");
        pm::MouseState m = pm::mouse();
        plhs[0] = mxCreateDoubleScalar(m.x);
        plhs[1] = mxCreateDoubleScalar(m.y);
        plhs[2] = mxCreateLogicalMatrix(1, 3);
        mxLogical *b = mxGetLogicals(plhs[2]);
        for (size_t i = 0; i < 3; i++) b[i] = m.buttons[i];
        return;
    }
    if (is("SetMouse")) {
        if (nrhs != 3 || nlhs != 0) fail("SetMouse takes x and y and has no outputs.");
        double x = scalar(prhs[1], "mouse x");
        double y = scalar(prhs[2], "mouse y");
        pm::setMouse(x, y);
        return;
    }
    if (is("Keys")) {
        if (nrhs != 1 || nlhs != 4) fail("Keys takes no arguments and returns four values.");
        pm::KeyState k = pm::keys();
        plhs[0] = mxCreateLogicalScalar(k.anyDown);
        plhs[1] = mxCreateDoubleScalar(k.secs);
        plhs[2] = mxCreateLogicalMatrix(1, 256);
        mxLogical *kv = mxGetLogicals(plhs[2]);
        for (size_t i = 0; i < 256; i++) kv[i] = k.down[i];
        plhs[3] = mxCreateDoubleScalar(k.securePid);
        return;
    }
    if (is("KbQueueStatus")) {
        if (nrhs != 1 || nlhs != 1) fail("KbQueueStatus returns one structure.");
        pm::KbQueueStatus st = pm::kbQueueStatus();
        const char *fields[] = {"created", "running", "pollInterval", "lastScanInterval",
                                "maxScanInterval", "scans", "dropped", "secureInputPID",
                                "eventTimestamps", "eventStamped", "pollStamped", "maxEventDelayMs"};
        plhs[0] = mxCreateStructMatrix(1, 1, 12, fields);
        const double values[] = {double(st.created), double(st.running), st.pollInterval,
                                 st.lastScanInterval, st.maxScanInterval, double(st.scans),
                                 double(st.dropped), st.secureInputPID, double(st.eventTimestamps),
                                 double(st.eventStamped), double(st.pollStamped), st.maxEventDelayMs};
        for (int i = 0; i < 12; i++) mxSetField(plhs[0], 0, fields[i], mxCreateDoubleScalar(values[i]));
        return;
    }
    if (is("KbQueueCreate")) {
        if (nrhs != 3 || nlhs != 0 || !isRealDouble(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 256)
            fail("KbQueueCreate requires a 256-element mask and poll interval, no outputs.");
        std::array<double, 256> mask;
        std::memcpy(mask.data(), mxGetPr(prhs[1]), sizeof(double) * 256);
        pm::kbQueueCreate(mask, scalar(prhs[2], "poll interval"));
        return;
    }
    if (is("KbQueueRelease")) {
        if (nrhs != 1 || nlhs != 0) fail("KbQueueRelease takes no arguments or outputs.");
        pm::kbQueueRelease();
        return;
    }
    if (is("KbQueueStart") || is("KbQueueStop") || is("KbQueueFlush")) {
        if (nrhs != 1 || nlhs != 0) fail("Queue Start/Stop/Flush take no arguments or outputs.");
        if (is("KbQueueStart")) pm::kbQueueStart();
        else if (is("KbQueueStop")) pm::kbQueueStop();
        else pm::kbQueueFlush();
        return;
    }
    if (is("KbQueueGetEvents")) {
        if (nrhs != 1 || nlhs != 2) fail("KbQueueGetEvents returns events and dropped count.");
        pm::KbEvents e = pm::kbQueueGetEvents();
        size_t n = e.events.size();
        plhs[0] = mxCreateDoubleMatrix(n, 3, mxREAL);
        double *out = mxGetPr(plhs[0]);
        for (size_t i = 0; i < n; i++) {
            out[i] = e.events[i].time; out[i + n] = e.events[i].key; out[i + 2 * n] = e.events[i].pressed ? 1 : 0;
        }
        plhs[1] = mxCreateDoubleScalar((double)e.dropped);
        return;
    }
    if (is("KbQueueCheck")) {
        if (nrhs != 1 || nlhs != 5) fail("KbQueueCheck returns pressed and four timestamp vectors.");
        pm::KbCheck c = pm::kbQueueCheck();
        plhs[0] = mxCreateLogicalScalar(c.pressed);
        const std::array<double, 256> *src[4] = {&c.firstPress, &c.firstRelease, &c.lastPress, &c.lastRelease};
        for (int j = 0; j < 4; j++) {
            plhs[j + 1] = mxCreateDoubleMatrix(1, 256, mxREAL);
            std::memcpy(mxGetPr(plhs[j + 1]), src[j]->data(), sizeof(double) * 256);
        }
        return;
    }

    // --- time and diagnostics ----------------------------------------------------
    if (is("Wait")) {
        if (nrhs != 2 || nlhs != 1) fail("Wait needs an absolute deadline and returns the time on return.");
        plhs[0] = mxCreateDoubleScalar(pm::waitUntil(scalar(prhs[1], "deadline")));
        return;
    }
    if (is("Now")) {
        if (nrhs != 1 || nlhs != 1) fail("Now takes no arguments and one output.");
        plhs[0] = mxCreateDoubleScalar(pm::now());
        return;
    }
    if (is("Diagnostic")) {
        if (nrhs != 1 || nlhs != 2) fail("Diagnostic needs two outputs.");
        pm::DiagnosticReport r = pm::diagnostic();
        plhs[0] = historyMatrix(r.history);
        plhs[1] = diagnosticStruct(r.summary);
        return;
    }
    fail("Unknown command.");
}

}  // namespace

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    static bool initialized = false;
    if (!initialized) {
        pm::HostHooks h;
        h.warn = warnHook;
        h.pinModule = pinHook;
        h.unpinModule = unpinHook;
        pm::installHostHooks(h);
        mexAtExit(atExit);
        initialized = true;
    }
    // Copy the error out and raise it after the handler has finished:
    // mexErrMsgIdAndTxt does not return, and under Octave it longjmps.
    static char errorId[128], errorText[1024];
    bool failed = false;
    try {
        dispatch(nlhs, plhs, nrhs, prhs);
    } catch (const pm::Error &e) {
        snprintf(errorId, sizeof(errorId), "%s", e.id().c_str());
        snprintf(errorText, sizeof(errorText), "%s", e.what());
        failed = true;
    } catch (const std::exception &e) {
        snprintf(errorId, sizeof(errorId), "%s", pm::kErrNative);
        snprintf(errorText, sizeof(errorText), "%s", e.what());
        failed = true;
    }
    if (failed)
        mexErrMsgIdAndTxt(errorId, "%s", errorText);
}
