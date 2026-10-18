// PsychMetalMex.cpp — the MATLAB / Octave front end: PsychMetalCore's
// mexFunction over the host-neutral engine (PsychMetalEngine.h).
// SPDX-License-Identifier: MIT
//
// PsychMetal.m is the only intended caller. This file only unpacks mxArrays,
// calls the engine and packs the results; validation beyond "is this the right
// kind of MATLAB value" belongs to the engine.
#include "mex.h"
#include "PsychMetalEngine.h"

#include <algorithm>
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

// UTF-8 as a MATLAB character row. Octave's characters are UTF-8 bytes; MATLAB's
// are UTF-16, which mxCreateString does not produce from anything but ASCII.
mxArray *utf8String(const std::string &s) {
#ifdef MATLAB_MEX_FILE
    std::u16string units;
    for (size_t i = 0; i < s.size();) {
        const unsigned char c = (unsigned char)s[i];
        const int extra = c < 0x80 ? 0 : c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : -1;
        uint32_t code = extra < 0 ? 0xFFFD : extra == 0 ? c : c & (0x3F >> extra);
        size_t j = i + 1;
        for (int k = 0; k < extra && j < s.size(); k++, j++) code = (code << 6) | ((unsigned char)s[j] & 0x3F);
        i = extra < 0 ? i + 1 : j;
        if (code >= 0x10000) { code -= 0x10000; units += (char16_t)(0xD800 + (code >> 10)); units += (char16_t)(0xDC00 + (code & 0x3FF)); }
        else units += (char16_t)code;
    }
    const mwSize dims[2] = {1, (mwSize)units.size()};
    mxArray *m = mxCreateCharArray(2, dims);
    std::copy(units.begin(), units.end(), (char16_t *)mxGetChars(m));
    return m;
#else
    return mxCreateString(s.c_str());
#endif
}

mxArray *row(std::initializer_list<double> values) {
    mxArray *m = mxCreateDoubleMatrix(1, values.size(), mxREAL);
    double *p = mxGetPr(m);
    for (double v : values) *p++ = v;
    return m;
}
mxArray *rect4(const pm::Rect4 &r) { return row({r[0], r[1], r[2], r[3]}); }
template <class T> mxArray *column(const std::vector<T> &values) {
    mxArray *m = mxCreateDoubleMatrix(values.size(), 1, mxREAL);
    double *p = mxGetPr(m);
    for (const T &v : values) *p++ = (double)v;
    return m;
}
template <size_t N> mxArray *rowOf(const std::array<double, N> &values) {
    mxArray *m = mxCreateDoubleMatrix(1, N, mxREAL);
    std::copy(values.begin(), values.end(), mxGetPr(m));
    return m;
}

// A scalar struct of named options, as the engine takes them: text, or real numbers.
std::vector<pm::Option> optionsOf(const mxArray *a) {
    if (!mxIsStruct(a) || mxGetNumberOfElements(a) != 1) fail("Options must be a scalar struct.");
    std::vector<pm::Option> out;
    for (int f = 0; f < mxGetNumberOfFields(a); f++) {
        pm::Option o;
        o.name = mxGetFieldNameByNumber(a, f);
        const mxArray *v = mxGetFieldByNumber(a, 0, f);
        if (v && mxIsChar(v)) { o.isText = true; o.text = text(v, o.name.c_str()); out.push_back(o); continue; }
        if (!v || mxIsComplex(v) || mxIsSparse(v) || !(mxIsNumeric(v) || mxIsLogical(v)))
            throw pm::Error(pm::kErrGeneral, "Invalid option: " + o.name + " must be real numbers or text.");
        const size_t n = mxGetNumberOfElements(v);
        const void *d = mxGetData(v);
        auto from = [&](auto *typed) { for (size_t i = 0; i < n; i++) o.numbers.push_back((double)typed[i]); };
        switch (mxGetClassID(v)) {
            case mxDOUBLE_CLASS: from((const double *)d); break;
            case mxSINGLE_CLASS: from((const float *)d); break;
            case mxLOGICAL_CLASS: from((const mxLogical *)d); break;
            case mxINT8_CLASS: from((const int8_t *)d); break;
            case mxUINT8_CLASS: from((const uint8_t *)d); break;
            case mxINT16_CLASS: from((const int16_t *)d); break;
            case mxUINT16_CLASS: from((const uint16_t *)d); break;
            case mxINT32_CLASS: from((const int32_t *)d); break;
            case mxUINT32_CLASS: from((const uint32_t *)d); break;
            case mxINT64_CLASS: from((const int64_t *)d); break;
            case mxUINT64_CLASS: from((const uint64_t *)d); break;
            default: throw pm::Error(pm::kErrGeneral, "Invalid option: " + o.name + " must be real numbers or text.");
        }
        out.push_back(o);
    }
    return out;
}


// Four real doubles, as a rect, a tint or a source rect.
pm::Rect4 fourOf(const mxArray *a, const char *what) {
    if (!isRealDouble(a) || mxGetNumberOfElements(a) != 4) {
        char message[128];
        snprintf(message, sizeof(message), "%s must be four real doubles.", what);
        fail(message);
    }
    const double *r = mxGetPr(a);
    return pm::Rect4{r[0], r[1], r[2], r[3]};
}

// A time argument: a real numeric scalar, NaN meaning "at once".
double timeArgument(const mxArray *a, const char *name) {
    if (!mxIsNumeric(a) || mxIsComplex(a) || mxIsSparse(a) || mxGetNumberOfElements(a) != 1) pm::failNotScalar(name);
    double v = mxGetScalar(a);
    return std::isnan(v) ? v : pm::checkFinite(v, name);
}
mxArray *audioInfo(const pm::AudioInfo &i) {
    const char *names[] = {"rate", "channels", "bufferFrames", "outputLatency", "device", "transport", "timed",
                           "input", "inputRate", "inputChannels", "inputBufferFrames", "inputLatency",
                           "inputDevice", "inputTransport", "recordSeconds"};
    mxArray *s = mxCreateStructMatrix(1, 1, 15, names);
    mxSetField(s, 0, "rate", mxCreateDoubleScalar(i.rate));
    mxSetField(s, 0, "channels", mxCreateDoubleScalar(i.channels));
    mxSetField(s, 0, "bufferFrames", mxCreateDoubleScalar(i.bufferFrames));
    mxSetField(s, 0, "outputLatency", mxCreateDoubleScalar(i.outputLatency));
    mxSetField(s, 0, "device", utf8String(i.device));
    mxSetField(s, 0, "transport", utf8String(i.transport));
    mxSetField(s, 0, "timed", mxCreateLogicalScalar(i.timed));
    mxSetField(s, 0, "input", mxCreateLogicalScalar(i.input));
    mxSetField(s, 0, "inputRate", mxCreateDoubleScalar(i.inputRate));
    mxSetField(s, 0, "inputChannels", mxCreateDoubleScalar(i.inputChannels));
    mxSetField(s, 0, "inputBufferFrames", mxCreateDoubleScalar(i.inputBufferFrames));
    mxSetField(s, 0, "inputLatency", mxCreateDoubleScalar(i.inputLatency));
    mxSetField(s, 0, "inputDevice", utf8String(i.inputDevice));
    mxSetField(s, 0, "inputTransport", utf8String(i.inputTransport));
    mxSetField(s, 0, "recordSeconds", mxCreateDoubleScalar(i.recordSeconds));
    return s;
}
mxArray *singleMatrix(const std::vector<float> &planar, size_t rows, size_t cols) {
    mxArray *m = mxCreateNumericMatrix(rows, cols, mxSINGLE_CLASS, mxREAL);
    if (rows * cols) std::memcpy(mxGetData(m), planar.data(), rows * cols * sizeof(float));   // planar is column-major
    return m;
}
const char *audioKind(pm::AudioEventKind k) {
    static const char *names[] = {"sound start", "sound end", "recording start", "recording end", "key"};
    return names[(int)k];
}
const char *audioStatus(pm::AudioEventStatus s) {
    static const char *names[] = {"on time", "late", "finished", "stopped", "full", "refused", "triggered", "interrupted"};
    return names[(int)s];
}

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
    mxArray *out = mxCreateDoubleMatrix(count, 14, mxREAL);
    double *v = mxGetPr(out);
    for (size_t row = 0; row < count; row++) {
        const pm::FrameRecord &r = records[row];
        const double cols[14] = {(double)r.token, r.projected, r.presented, (double)r.status,
                                 r.scheduledAt, r.callback, (double)r.commandStatus, r.requestedTime,
                                 r.gpuStart, r.gpuEnd, r.presentRequest, r.committedAt,
                                 r.drawableAcquireMs, r.encodeMs};
        for (size_t c = 0; c < 14; c++) v[row + count * c] = cols[c];
    }
    return out;
}

mxArray *diagnosticStruct(const pm::DiagnosticSummary &d) {
    const char *n[] = {
        "confirmedPresentations", "missingPresentedTimes", "lastTargetErrorMs", "lastConfirmDelayMs",
        "renderWidth", "renderHeight", "inFlight", "drawableCount",
        "measuredRefreshHz", "gridSamples", "noDrawable",
        "leadEstimateMs", "pipelineEstimateMs", "gpuEstimateMs", "readbackEnabled",
        "shapesAppended", "shapesEncoded",
        "texturesCreated", "texturesDrawn", "textureAllocations", "lastTextureUploadMs",
        "lastShapeRect", "lastShapeColor", "screenSafeAreaInsets", "backingScaleFactor", "displayCaptured"};
    mxArray *s = mxCreateStructMatrix(1, 1, (int)(sizeof(n) / sizeof(n[0])), n);
    auto num = [&](const char *f, double v) { mxSetField(s, 0, f, mxCreateDoubleScalar(v)); };
    auto r4 = [&](const char *f, const pm::Rect4 &v) { mxSetField(s, 0, f, rect4(v)); };
    num("confirmedPresentations", d.confirmedPresentations);
    num("missingPresentedTimes", d.missingPresentedTimes);
    num("lastTargetErrorMs", d.lastTargetErrorMs);
    num("lastConfirmDelayMs", d.lastConfirmDelayMs);
    num("renderWidth", d.renderWidth);
    num("renderHeight", d.renderHeight);
    num("inFlight", d.inFlight);
    num("drawableCount", d.drawableCount);
    num("measuredRefreshHz", d.measuredRefreshHz);
    num("gridSamples", d.gridSamples);
    num("noDrawable", d.noDrawable);
    num("leadEstimateMs", d.leadEstimateMs);
    num("pipelineEstimateMs", d.pipelineEstimateMs);
    num("gpuEstimateMs", d.gpuEstimateMs);
    mxSetField(s, 0, "readbackEnabled", mxCreateLogicalScalar(d.readbackEnabled));
    num("shapesAppended", d.shapesAppended);
    num("shapesEncoded", d.shapesEncoded);
    num("texturesCreated", d.texturesCreated);
    num("texturesDrawn", d.texturesDrawn);
    num("textureAllocations", d.textureAllocations);
    num("lastTextureUploadMs", d.lastTextureUploadMs);
    r4("lastShapeRect", d.lastShapeRect);
    r4("lastShapeColor", d.lastShapeColor);
    r4("screenSafeAreaInsets", d.screenSafeAreaInsets);
    num("backingScaleFactor", d.backingScaleFactor);
    mxSetField(s,0,"displayCaptured",mxCreateLogicalScalar(d.displayCaptured));
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
        const char *names[]={"engineVersion","platform","osVersion","gpuName","gpuAvailable","debuggerAttached"};
        plhs[0]=mxCreateStructMatrix(1,1,6,names);
        mxSetField(plhs[0],0,"engineVersion",mxCreateString(e.engineVersion.c_str()));
        mxSetField(plhs[0],0,"platform",mxCreateString(e.platform.c_str()));
        mxSetField(plhs[0],0,"osVersion",utf8String(e.osVersion));
        mxSetField(plhs[0],0,"gpuName",utf8String(e.gpuName));
        mxSetField(plhs[0],0,"gpuAvailable",mxCreateLogicalScalar(e.gpuAvailable));
        mxSetField(plhs[0],0,"debuggerAttached",mxCreateLogicalScalar(e.debuggerAttached));
        return;
    }
    if (is("AudioDevices")) {
        if (nrhs != 1 || nlhs != 1) fail("AudioDevices takes no arguments and returns one struct array.");
        auto list = pm::audioDevices();
        const char *names[] = {"id", "name", "transport", "outputChannels", "inputChannels", "rate", "defaultOutput", "defaultInput"};
        plhs[0] = mxCreateStructMatrix(1, list.size(), 8, names);
        for (size_t i = 0; i < list.size(); i++) {
            const auto &d = list[i];
            mxSetField(plhs[0], i, "id", mxCreateDoubleScalar((double)d.id));
            mxSetField(plhs[0], i, "name", utf8String(d.name));
            mxSetField(plhs[0], i, "transport", mxCreateString(d.transport.c_str()));
            mxSetField(plhs[0], i, "outputChannels", mxCreateDoubleScalar(d.outputChannels));
            mxSetField(plhs[0], i, "inputChannels", mxCreateDoubleScalar(d.inputChannels));
            mxSetField(plhs[0], i, "rate", mxCreateDoubleScalar(d.rate));
            mxSetField(plhs[0], i, "defaultOutput", mxCreateLogicalScalar(d.isDefaultOutput));
            mxSetField(plhs[0], i, "defaultInput", mxCreateLogicalScalar(d.isDefaultInput));
        }
        return;
    }
    if (is("OpenAudio")) {
        if (nrhs != 10 || nlhs != 1)
            fail("OpenAudio needs device, rate, channels, bufferFrames, anyRoute, input, inputDevice, inputChannels and recordSeconds.");
        pm::AudioOptions o;
        double device = scalar(prhs[1], "device"), inputDevice = scalar(prhs[7], "inputDevice");
        o.device = device < 0 ? -1 : (int64_t)pm::checkUnsigned(device, "device", UINT32_MAX);
        o.rate = scalar(prhs[2], "rate");
        o.channels = (uint32_t)unsignedScalar(prhs[3], "channels", 1024);
        o.bufferFrames = (uint32_t)unsignedScalar(prhs[4], "bufferFrames", 1 << 20);
        o.anyRoute = unsignedScalar(prhs[5], "anyRoute", 1) != 0;
        o.input = unsignedScalar(prhs[6], "input", 1) != 0;
        o.inputDevice = inputDevice < 0 ? -1 : (int64_t)pm::checkUnsigned(inputDevice, "inputDevice", UINT32_MAX);
        o.inputChannels = (uint32_t)unsignedScalar(prhs[8], "inputChannels", 1024);
        o.recordSeconds = scalar(prhs[9], "recordSeconds");
        plhs[0] = audioInfo(pm::openAudio(o));
        return;
    }
    if (is("CloseAudio")) {
        if (nrhs != 1 || nlhs != 0) fail("CloseAudio takes no arguments or outputs.");
        pm::closeAudio();
        return;
    }
    if (is("AudioStatus")) {
        if (nrhs != 1 || nlhs != 1) fail("AudioStatus returns one struct.");
        pm::AudioStatus st = pm::audioStatus();
        const char *names[] = {"open", "info", "sounds", "voices", "clippedSamples", "lostEvents", "recording", "recordedFrames"};
        plhs[0] = mxCreateStructMatrix(1, 1, 8, names);
        mxSetField(plhs[0], 0, "open", mxCreateLogicalScalar(st.open));
        mxSetField(plhs[0], 0, "info", st.open ? audioInfo(st.info) : mxCreateDoubleMatrix(0, 0, mxREAL));
        mxSetField(plhs[0], 0, "sounds", mxCreateDoubleScalar((double)st.sounds));
        mxSetField(plhs[0], 0, "voices", mxCreateDoubleScalar((double)st.voices));
        mxSetField(plhs[0], 0, "clippedSamples", mxCreateDoubleScalar((double)st.clippedSamples));
        mxSetField(plhs[0], 0, "lostEvents", mxCreateDoubleScalar((double)st.lostEvents));
        mxSetField(plhs[0], 0, "recording", mxCreateLogicalScalar(st.recording));
        mxSetField(plhs[0], 0, "recordedFrames", mxCreateDoubleScalar((double)st.recordedFrames));
        return;
    }
    if(is("MakeAudioStream")) {
        if(nrhs!=3 || nlhs!=1)fail("MakeAudioStream takes capacityFrames and channels, returns one handle.");
        plhs[0]=mxCreateDoubleScalar((double)pm::makeAudioStream(unsignedScalar(prhs[1],"capacityFrames",16777216),(uint32_t)unsignedScalar(prhs[2],"channels",32)));return;
    }
    if(is("RefillSound")) {
        if(nrhs!=4 || nlhs!=1)fail("RefillSound takes a handle, samples and final, returns written frames.");
        auto v=imageView(prhs[2]);if(v.ndim==2 && v.shape[1]==1)v.ndim=1;
        plhs[0]=mxCreateDoubleScalar((double)pm::refillSound(unsignedScalar(prhs[1],"sound",pm::kMaxId),v,unsignedScalar(prhs[3],"final",1)!=0));return;
    }
    if(is("AudioStreamStatus")) {
        if(nrhs!=2 || nlhs!=1)fail("AudioStreamStatus returns one struct for a stream handle.");
        auto q=pm::audioStreamStatus(unsignedScalar(prhs[1],"sound",pm::kMaxId));
        const char *names[]={"capacity","queued","free","written","consumed","underflowFrames","sealed"};
        auto out=mxCreateStructMatrix(1,1,7,names);
        const double values[]={(double)q.capacity,(double)q.queued,(double)q.free,(double)q.written,(double)q.consumed,(double)q.underflowFrames};
        for(int i=0;i<6;i++)mxSetField(out,0,names[i],mxCreateDoubleScalar(values[i]));
        mxSetField(out,0,"sealed",mxCreateLogicalScalar(q.sealed));plhs[0]=out;return;
    }
    if (is("MakeSound")) {
        if (nrhs != 3 || nlhs != 1) fail("MakeSound takes samples and a rate, and returns a handle.");
        pm::ArrayView v = imageView(prhs[1]);
        if (v.ndim == 2 && v.shape[1] == 1) v.ndim = 1;                 // a column: one channel
        plhs[0] = mxCreateDoubleScalar((double)pm::makeSound(v, scalar(prhs[2], "rate")));
        return;
    }
    if (is("CloseSound")) {
        if (nrhs != 2 || nlhs != 0) fail("CloseSound takes a sound handle.");
        pm::closeSound(unsignedScalar(prhs[1], "sound", pm::kMaxId));
        return;
    }
    if (is("Play")) {
        if (nrhs != 7 || nlhs != 1) fail("Play takes sound, when, frame, offset, gain and repeats, and returns a voice.");
        uint64_t voice = pm::play(unsignedScalar(prhs[1], "sound", pm::kMaxId), timeArgument(prhs[2], "when"),
                                  unsignedScalar(prhs[3], "frame", pm::kMaxId), scalar(prhs[4], "offset"),
                                  scalar(prhs[5], "gain"), (uint32_t)unsignedScalar(prhs[6], "repeats", UINT32_MAX));
        plhs[0] = mxCreateDoubleScalar((double)voice);
        return;
    }
    if (is("StopSound")) {
        if (nrhs != 3 || nlhs != 0) fail("StopSound takes a voice (0: all) and a time.");
        pm::stopSound(unsignedScalar(prhs[1], "voice", pm::kMaxId), timeArgument(prhs[2], "when"));
        return;
    }
    if (is("Modulate")) {
        if (nrhs != 6 || nlhs != 0) fail("Modulate takes a voice, hz, phase, depth and a time.");
        pm::modulate(unsignedScalar(prhs[1], "voice", pm::kMaxId), scalar(prhs[2], "hz"), scalar(prhs[3], "phase"),
                     scalar(prhs[4], "depth"), timeArgument(prhs[5], "when"));
        return;
    }
    if (is("StartRecording")) {
        if (nrhs != 2 || nlhs != 1) fail("StartRecording takes a time and returns an id.");
        plhs[0] = mxCreateDoubleScalar((double)pm::startRecording(timeArgument(prhs[1], "when")));
        return;
    }
    if (is("StopRecording")) {
        if (nrhs != 2 || nlhs != 0) fail("StopRecording takes a time.");
        pm::stopRecording(timeArgument(prhs[1], "when"));
        return;
    }
    if (is("GetRecording")) {
        if (nrhs != 1 || nlhs != 3) fail("GetRecording returns samples, rate and the first sample's time.");
        pm::Recording r = pm::getRecording();
        plhs[0] = singleMatrix(r.samples, (size_t)r.frames, r.channels);
        plhs[1] = mxCreateDoubleScalar(r.rate);
        plhs[2] = mxCreateDoubleScalar(r.firstSampleTime);
        return;
    }
    if (is("VoiceKey")) {
        if (nrhs != 5 || nlhs != 1) fail("VoiceKey takes threshold, when, window and minimum, and returns an id.");
        plhs[0] = mxCreateDoubleScalar((double)pm::voiceKey(scalar(prhs[1], "threshold"), timeArgument(prhs[2], "when"),
            scalar(prhs[3], "window"), (uint32_t)unsignedScalar(prhs[4], "minimum", UINT32_MAX)));
        return;
    }
    if (is("InputRecent")) {
        if (nrhs != 2 || nlhs != 3) fail("InputRecent takes seconds and returns samples, rate and end time.");
        pm::InputRecent r = pm::inputRecent(scalar(prhs[1], "seconds"));
        plhs[0] = singleMatrix(r.samples, r.samples.size(), 1);
        plhs[1] = mxCreateDoubleScalar(r.rate);
        plhs[2] = mxCreateDoubleScalar(r.endTime);
        return;
    }
    if (is("AudioResults")) {
        if (nrhs != 1 || nlhs != 1) fail("AudioResults takes no arguments and returns one struct array.");
        auto events = pm::audioResults();
        const char *names[] = {"kind", "id", "requested", "time", "status", "frames", "level", "frameToken", "framePresented"};
        plhs[0] = mxCreateStructMatrix(1, events.size(), 9, names);
        for (size_t i = 0; i < events.size(); i++) {
            const auto &e = events[i];
            mxSetField(plhs[0], i, "kind", mxCreateString(audioKind(e.kind)));
            mxSetField(plhs[0], i, "id", mxCreateDoubleScalar((double)e.id));
            mxSetField(plhs[0], i, "requested", mxCreateDoubleScalar(e.requested));
            mxSetField(plhs[0], i, "time", mxCreateDoubleScalar(e.time));
            mxSetField(plhs[0], i, "status", mxCreateString(audioStatus(e.status)));
            mxSetField(plhs[0], i, "frames", mxCreateDoubleScalar(e.frames));
            mxSetField(plhs[0], i, "level", mxCreateDoubleScalar(e.level));
            mxSetField(plhs[0], i, "frameToken", mxCreateDoubleScalar((double)e.frameToken));
            mxSetField(plhs[0], i, "framePresented", mxCreateDoubleScalar(e.framePresented));
        }
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
    if (is("KeyNames")) {
        if (nrhs != 1 || nlhs != 1) fail("KeyNames takes no arguments and returns one table.");
        const std::vector<pm::KeyName> &names = pm::keyNames();
        mxArray *table = mxCreateCellMatrix(names.size(), 2);
        for (size_t i = 0; i < names.size(); i++) {
            mxSetCell(table, i, mxCreateDoubleScalar(names[i].usage));
            mxSetCell(table, i + names.size(), mxCreateString(names[i].name));
        }
        plhs[0] = table;
        return;
    }
    if (is("Tone") || is("Click") || is("WhiteNoise")) {
        // Tone: frequency, seconds, rate[, amplitude, ramp]. Click: rate[, seconds, amplitude].
        // WhiteNoise: seconds, rate[, amplitude, seed (NaN: fresh), ramp].
        const int needed = is("Click") ? 1 : is("Tone") ? 3 : 2, most = is("Click") ? 3 : 5;
        if (nrhs - 1 < needed || nrhs - 1 > most || nlhs != 1) fail("Wrong number of arguments for a sound.");
        double a[5];
        for (int i = 1; i < nrhs; i++) {
            if (!mxIsNumeric(prhs[i]) || mxIsComplex(prhs[i]) || mxGetNumberOfElements(prhs[i]) != 1)
                pm::failNotScalar("sound argument");
            a[i - 1] = mxGetScalar(prhs[i]);
        }
        auto at = [&](int i, double otherwise) { return i < nrhs - 1 ? a[i] : otherwise; };
        if (is("Tone")) plhs[0] = column(pm::tone(a[0], a[1], a[2], at(3, 0.5), at(4, 0.005)));
        else if (is("Click")) plhs[0] = column(pm::click(a[0], at(1, 0.001), at(2, 0.9)));
        else plhs[0] = column(pm::whiteNoise(a[0], a[1], at(2, 0.3), at(3, NAN), at(4, 0.005)));
        return;
    }
    if (is("ConfirmStartup")) {
        if (nrhs != 1 || nlhs != 1) fail("ConfirmStartup returns the initialization history.");
        plhs[0] = startupMatrix(pm::confirmStartup());
        return;
    }
    if(is("OpenExport")) {
        if(nrhs!=5||nlhs!=6) fail("OpenExport takes width,height,refreshHz,readback and returns six session fields.");
        auto w=unsignedScalar(prhs[1],"export width",8192),h=unsignedScalar(prhs[2],"export height",8192);
        auto r=pm::openExport(w,h,scalar(prhs[3],"refreshHz"),unsignedScalar(prhs[4],"readback",1)!=0);
        const double values[]={r.pixelWidth,r.pixelHeight,r.ifi,r.pointWidth,r.pointHeight,double(r.sessionToken)};
        for(int i=0;i<6;i++) plhs[i]=mxCreateDoubleScalar(values[i]);return;
    }
    if (is("Open")) {
        if ((nrhs < 3 || nrhs > 8) || nlhs != 6)
            fail("Open needs screenIndex,drawableCount[,refreshHz[,readback[,bitDepth[,displayLink[,captureDisplay]]]]] "
                 "and returns width,height,ifi,pointWidth,pointHeight,sessionToken.");
        pm::OpenOptions o;
        o.screenIndex = scalar(prhs[1], "screen index");
        o.drawableCount = unsignedScalar(prhs[2], "maximum drawable count", 3);
        // An empty refreshHz is no override, so readback can follow it.
        if (nrhs >= 4 && !mxIsEmpty(prhs[3])) o.refreshHz = scalar(prhs[3], "refreshHz");
        if (nrhs >= 5) o.readback = unsignedScalar(prhs[4], "readback", 1) != 0;
        if (nrhs >= 6) o.bitDepth = unsignedScalar(prhs[5], "bit depth", 16);
        if (nrhs >= 7) o.displayLink = unsignedScalar(prhs[6], "display link", 1) != 0;
        if(nrhs==8)o.captureDisplay=unsignedScalar(prhs[7],"capture display",1)!=0;
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
    if (is("RecentFrames")) {
        if (nrhs != 2 || nlhs != 1) fail("RecentFrames takes a count and returns one matrix.");
        size_t count = (size_t)unsignedScalar(prhs[1], "count", 256);
        if (count < 1) fail("count must be an integer from 1 to 256.");
        std::vector<pm::FrameRecord> records = pm::recentFrames(count);
        size_t n = records.size();
        plhs[0] = mxCreateDoubleMatrix(n, 4, mxREAL);
        double *out = mxGetPr(plhs[0]);
        for (size_t i = 0; i < n; i++) {
            out[i] = (double)records[i].token; out[i + n] = records[i].status;
            out[i + 2 * n] = records[i].presented; out[i + 3 * n] = records[i].committedAt;
        }
        return;
    }
    if (is("QueueCancel")) {
        if (nrhs != 1 || nlhs != 1) fail("QueueCancel takes no arguments and returns a count.");
        plhs[0] = mxCreateDoubleScalar((double)pm::queueCancel());
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
    if (is("MakeStimulus") || is("MakeMask")) {
        if ((nrhs != 2 && nrhs != 3) || nlhs != 1) fail("MakeStimulus and MakeMask take a kind and an optional options struct.");
        const std::string kind = text(prhs[1], "The kind");
        const std::vector<pm::Option> options = nrhs == 3 ? optionsOf(prhs[2]) : std::vector<pm::Option>{};
        plhs[0] = is("MakeMask") ? rowOf(pm::makeMask(kind, options)) : rowOf(pm::makeStimulus(kind, options));
        return;
    }
    if (is("StimulusWith")) {
        if (nrhs != 3 || nlhs != 1) fail("StimulusWith takes a recipe's parameters and an options struct.");
        plhs[0] = rowOf(pm::stimulusWith(rowView(prhs[1]), optionsOf(prhs[2])));
        return;
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
        if ((nrhs != 6 && nrhs != 7) || nlhs != 0) fail("AddShapes needs kind, param, rect, color and extra arrays, and optional angles.");
        pm::ArrayView angle;
        if (nrhs == 7) angle = rowView(prhs[6]);
        pm::addShapes(rowView(prhs[1]), rowView(prhs[2]), columnsView(prhs[3]),
                      columnsView(prhs[4]), columnsView(prhs[5]), nrhs == 7 ? &angle : nullptr);
        return;
    }
    if (is("Transform")) {
        if (nrhs != 1 || nlhs > 1) fail("Transform takes no arguments and returns [a b c d tx ty].");
        auto m = pm::transform();
        plhs[0] = mxCreateDoubleMatrix(1, 6, mxREAL);
        std::copy(m.begin(), m.end(), mxGetPr(plhs[0]));
        return;
    }
    if (is("SetTransform") || is("MultiplyTransform")) {
        if (nrhs != 2 || nlhs != 0) fail("SetTransform and MultiplyTransform take [a b c d tx ty] and have no outputs.");
        if (!isRealDouble(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 6)
            fail("A transform is six real doubles, [a b c d tx ty].");
        std::array<double,6> m;
        std::copy(mxGetPr(prhs[1]), mxGetPr(prhs[1]) + 6, m.begin());
        if (is("SetTransform")) pm::setTransform(m); else pm::multiplyTransform(m);
        return;
    }
    if (is("PushTransform") || is("PopTransform")) {
        if (nrhs != 1 || nlhs != 0) fail("PushTransform and PopTransform take no arguments.");
        if (is("PushTransform")) pm::pushTransform(); else pm::popTransform();
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
    // --- movies (MOVIES.md); frames are numbered from 0 here, from 1 in PsychMetal.m
    if (is("OpenMovie")) {
        if (nrhs != 2 || nlhs != 2) fail("OpenMovie takes a path, and returns a handle and an info struct.");
        pm::MovieInfo i;
        uint64_t handle = pm::openMovie(text(prhs[1], "movie path"), i);
        const char *names[] = {"width", "height", "frames", "frameRate", "duration", "constantRate",
                               "soundChannels", "soundRate", "codec", "keyframeInterval"};
        mxArray *info = mxCreateStructMatrix(1, 1, 10, names);
        auto number = [&](const char *f, double v) { mxSetField(info, 0, f, mxCreateDoubleScalar(v)); };
        number("width", i.width); number("height", i.height); number("frames", i.frames);
        number("frameRate", i.frameRate); number("duration", i.duration);
        mxSetField(info, 0, "constantRate", mxCreateLogicalScalar(i.constantRate));
        number("keyframeInterval",i.keyframeInterval);
        number("soundChannels", i.soundChannels); number("soundRate", i.soundRate);
        mxSetField(info, 0, "codec", utf8String(i.codec));
        plhs[0] = mxCreateDoubleScalar((double)handle);
        plhs[1] = info;
        return;
    }
    if(is("TranscodeMovie")) {
        if(nrhs!=4||nlhs!=1)fail("TranscodeMovie takes source, destination and codec; returns frames.");
        plhs[0]=mxCreateDoubleScalar((double)pm::transcodeMovie(text(prhs[1],"source"),text(prhs[2],"destination"),text(prhs[3],"codec")));return;
    }
    if(is("PrepareMovie")) {
        if(nrhs!=4 || nlhs!=1) fail("PrepareMovie takes movie, frames and maxBytes; returns resident frames.");
        plhs[0]=mxCreateDoubleScalar((double)pm::prepareMovie(unsignedScalar(prhs[1],"movie",pm::kMaxId),
            (uint32_t)unsignedScalar(prhs[2],"frames",256),unsignedScalar(prhs[3],"maxBytes",2147483648ull)));return;
    }
    if (is("MovieFrameTimes")) {
        if (nrhs != 2 || nlhs != 1) fail("MovieFrameTimes takes a movie handle and returns the frame times.");
        plhs[0] = column(pm::movieFrameTimes(unsignedScalar(prhs[1], "movie", pm::kMaxId)));
        return;
    }
    if (is("DrawMovieFrame")) {
        if (nrhs != 8 || nlhs != 0) fail("DrawMovieFrame takes movie, index, srcRect, dstRect, angle, tint and filter.");
        pm::drawMovieFrame(unsignedScalar(prhs[1], "movie", pm::kMaxId), unsignedScalar(prhs[2], "frame", pm::kMaxId),
                           fourOf(prhs[3], "The source rect"), fourOf(prhs[4], "The destination rect"),
                           scalar(prhs[5], "angle"), fourOf(prhs[6], "The tint"),
                           (int)unsignedScalar(prhs[7], "filter", 1));
        return;
    }
    if (is("MovieSound")) {
        if (nrhs != 5 || nlhs != 1) fail("MovieSound takes movie, rate, speed and keepPitch, and returns samples x channels.");
        uint32_t channels = 1;
        std::vector<float> interleaved = pm::movieSound(unsignedScalar(prhs[1], "movie", pm::kMaxId),
                                                        scalar(prhs[2], "rate"), scalar(prhs[3], "speed"),
                                                        unsignedScalar(prhs[4], "keepPitch", 1) != 0, channels);
        const size_t frames = interleaved.size() / channels;
        std::vector<float> planar(frames * channels);
        for (size_t f = 0; f < frames; f++)
            for (uint32_t c = 0; c < channels; c++) planar[c * frames + f] = interleaved[f * channels + c];
        plhs[0] = singleMatrix(planar, frames, channels);
        return;
    }
    if (is("PlayMovie")) {
        if (nrhs != 10 || nlhs != 1)
            fail("PlayMovie takes movie, first, count, refreshes, srcRect, dstRect, when, sound and gain.");
        auto r = pm::playMovie(unsignedScalar(prhs[1], "movie", pm::kMaxId), unsignedScalar(prhs[2], "first frame", pm::kMaxId),
                               unsignedScalar(prhs[3], "frame count", pm::kMaxId),
                               (uint32_t)unsignedScalar(prhs[4], "refreshes per frame", 1000),
                               fourOf(prhs[5], "The source rect"), fourOf(prhs[6], "The destination rect"),
                               timeArgument(prhs[7], "when"), unsignedScalar(prhs[8], "sound", pm::kMaxId),
                               scalar(prhs[9], "gain"));
        const char *names[] = {"submitted", "firstToken", "lastToken", "frames", "cancelled", "start", "firstPresented",
                               "shown", "late", "lateRefreshes", "expectedRefreshHz", "longestIntervalMs", "voice", "audioStartOffsetMs", "audioEndOffsetMs", "audioVideoDriftMs"};
        plhs[0] = mxCreateStructMatrix(1, 1, 16, names);
        auto number = [&](const char *f, double v) { mxSetField(plhs[0], 0, f, mxCreateDoubleScalar(v)); };
        number("submitted", (double)r.submitted); number("firstToken", (double)r.firstToken);
        number("lastToken", (double)r.lastToken); number("frames", (double)r.frames);
        mxSetField(plhs[0], 0, "cancelled", mxCreateLogicalScalar(r.cancelled));
        number("start", r.start); number("firstPresented", r.firstPresented);
        number("shown", (double)r.shown); number("late", (double)r.late); number("lateRefreshes", (double)r.lateRefreshes);
        number("expectedRefreshHz", r.expectedRefreshHz); number("longestIntervalMs", r.longestIntervalMs);
        number("voice", (double)r.voice);
        number("audioStartOffsetMs",r.audioStartOffsetMs);number("audioEndOffsetMs",r.audioEndOffsetMs);number("audioVideoDriftMs",r.audioVideoDriftMs);
        return;
    }
    if (is("StartMovieRecording")) {
        if ((nrhs != 5 && nrhs != 6) || nlhs != 0) fail("StartMovieRecording takes path, codec, scale, sound and an optional virtual-clock flag.");
        pm::startMovieRecording(text(prhs[1], "movie path"), text(prhs[2], "codec"), scalar(prhs[3], "scale"),
                                unsignedScalar(prhs[4], "sound", 1) != 0, nrhs==6 && unsignedScalar(prhs[5], "virtual clock", 1)!=0);
        return;
    }
    if (is("StopMovieRecording")) {
        if (nrhs != 1 || nlhs != 1) fail("StopMovieRecording returns one struct.");
        pm::MovieRecording r = pm::stopMovieRecording();
        const char *names[] = {"path", "codec", "width", "height", "frames", "refreshes", "refreshHz", "duration",
                               "late", "unreported", "sound", "soundSeconds", "soundLostSeconds", "virtualClock"};
        plhs[0] = mxCreateStructMatrix(1, 1, 14, names);
        auto number = [&](const char *f, double v) { mxSetField(plhs[0], 0, f, mxCreateDoubleScalar(v)); };
        mxSetField(plhs[0], 0, "path", utf8String(r.path));
        mxSetField(plhs[0], 0, "codec", utf8String(r.codec));
        number("width", r.width); number("height", r.height); number("frames", r.frames);
        number("refreshes", r.refreshes); number("refreshHz", r.refreshHz); number("duration", r.duration);
        number("late", r.late); number("unreported", r.unreported);
        mxSetField(plhs[0], 0, "sound", mxCreateLogicalScalar(r.sound));
        number("soundSeconds", r.soundSeconds); number("soundLostSeconds", r.soundLostSeconds);
        mxSetField(plhs[0],0,"virtualClock",mxCreateLogicalScalar(r.virtualClock));
        return;
    }
    if (is("CloseMovie")) {
        if (nrhs != 2 || nlhs != 0) fail("CloseMovie takes a movie handle.");
        pm::closeMovie(unsignedScalar(prhs[1], "movie", pm::kMaxId));
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
    if (is("LayoutText")) {
        if (nrhs != 5 || nlhs != 3) fail("LayoutText takes text, font, size and wrap width, and returns lines, sizes and ascent.");
        pm::TextLayout l = pm::layoutText(text(prhs[1], "Text"), text(prhs[2], "Font"), scalar(prhs[3], "text size"),
                                          mxGetScalar(prhs[4]));
        plhs[0] = mxCreateCellMatrix(1, l.lines.size());
        for (size_t i = 0; i < l.lines.size(); i++) mxSetCell(plhs[0], i, utf8String(l.lines[i]));
        plhs[1] = mxCreateDoubleMatrix(l.sizes.size(), 2, mxREAL);
        double *s = mxGetPr(plhs[1]);
        for (size_t i = 0; i < l.sizes.size(); i++) { s[i] = l.sizes[i][0]; s[i + l.sizes.size()] = l.sizes[i][1]; }
        plhs[2] = mxCreateDoubleScalar(l.ascent);
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
    if(is("CreateImagePipeline")) {
        if(nrhs!=2||nlhs!=1)fail("CreateImagePipeline takes a program and returns one handle.");
        plhs[0]=mxCreateDoubleScalar((double)pm::createImagePipeline(imageView(prhs[1])));return;
    }
    if(is("ProcessImage")) {
        if(nrhs!=4||nlhs!=1)fail("ProcessImage takes pipeline, source and destination handles.");
        plhs[0]=mxCreateDoubleScalar((double)pm::processImage(unsignedScalar(prhs[1],"pipeline",pm::kMaxId),
            unsignedScalar(prhs[2],"source",pm::kMaxId),unsignedScalar(prhs[3],"destination",pm::kMaxId)));return;
    }
    if(is("CloseImagePipeline")) {if(nrhs!=2||nlhs)fail("CloseImagePipeline takes one handle.");pm::closeImagePipeline(unsignedScalar(prhs[1],"pipeline",pm::kMaxId));return;}
    if(is("HDRInfo")) {
        if(nrhs!=1||nlhs!=1)fail("HDRInfo returns one struct.");auto q=pm::hdrInfo();
        const char *names[]={"enabled","currentHeadroom","potentialHeadroom","exposure","units"};
        auto out=mxCreateStructMatrix(1,1,5,names);mxSetField(out,0,"enabled",mxCreateLogicalScalar(q.enabled));
        mxSetField(out,0,"currentHeadroom",mxCreateDoubleScalar(q.currentHeadroom));mxSetField(out,0,"potentialHeadroom",mxCreateDoubleScalar(q.potentialHeadroom));
        mxSetField(out,0,"exposure",mxCreateDoubleScalar(q.exposure));mxSetField(out,0,"units",mxCreateString("linear Display-P3; 1 = SDR reference white"));plhs[0]=out;return;
    }
    if(is("HDRExposure")) {if(nrhs!=2||nlhs)fail("HDRExposure takes stops and returns nothing.");pm::setHDRExposure(scalar(prhs[1],"exposure"));return;}
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
        if(g.bits==16) {
            plhs[0]=mxCreateNumericArray(3,dims,mxSINGLE_CLASS,mxREAL);pm::MutableFloatView out;
            out.data=(float*)mxGetData(plhs[0]);out.ndim=3;out.shape={(size_t)H,(size_t)W,3};out.strides={4,(ptrdiff_t)(4*H),(ptrdiff_t)(4*H*W)};
            pm::getImageFloat(g,out);return;
        }
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
    if (is("Screens")) {
        if (nrhs != 1 || nlhs > 1) fail("Screens takes no arguments and returns one struct array.");
        std::vector<pm::ScreenInfo> v = pm::screens();
        const char *names[] = {"index", "name", "width", "height", "pixelWidth", "pixelHeight", "hz", "main", "builtIn"};
        plhs[0] = mxCreateStructMatrix(1, v.size(), 9, names);
        for (size_t i = 0; i < v.size(); i++) {
            const pm::ScreenInfo &x = v[i];
            mxSetField(plhs[0], i, "index", mxCreateDoubleScalar(x.index));
            mxSetField(plhs[0], i, "name", mxCreateString(x.name.c_str()));
            mxSetField(plhs[0], i, "width", mxCreateDoubleScalar(x.pointWidth));
            mxSetField(plhs[0], i, "height", mxCreateDoubleScalar(x.pointHeight));
            mxSetField(plhs[0], i, "pixelWidth", mxCreateDoubleScalar(x.pixelWidth));
            mxSetField(plhs[0], i, "pixelHeight", mxCreateDoubleScalar(x.pixelHeight));
            mxSetField(plhs[0], i, "hz", mxCreateDoubleScalar(x.refreshHz));
            mxSetField(plhs[0], i, "main", mxCreateLogicalScalar(x.main));
            mxSetField(plhs[0], i, "builtIn", mxCreateLogicalScalar(x.builtIn));
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
