// PsychMetalPython.cpp — the Python front end: module psychmetal._psychmetal,
// a thin binding of PsychMetalEngine.h using the plain CPython C API.
// SPDX-License-Identifier: MIT
//
// Build dependencies: a C++17 compiler and Python's headers. numpy is used at
// run time only: arrays arrive through the buffer protocol with their own
// strides (never copied), and arrays leave through a factory the psychmetal
// package installs (numpy.frombuffer), so this file needs no numpy headers.
//
// Every engine call releases the GIL, so other Python threads keep running while
// Flip or a wait blocks. Releasing the GIL is also what lets the main thread
// service AppKit (serviceMainRunLoop) while a worker thread is inside an engine
// call that dispatch_syncs to it. Engine warnings are queued during the call and
// issued as Python warnings once the GIL is held again.
//
// Calls are of three kinds (see hold()). Most change the engine's state and run
// one at a time, alone. Reading input (mouse, touches, keys, the keyboard queue)
// runs beside a playing timeline, with input readers serialized, so that a second
// thread can steer a timeline from what the participant does. Waiting for a time
// and the clock touch nothing of the engine's and take no lock at all.
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include "PsychMetalEngine.h"

#include <chrono>
#include <cstring>
#include <functional>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

PyObject *ErrorType = nullptr;       // psychmetal.PsychMetalError (RuntimeError), with .id
PyObject *arrayFactory = nullptr;    // factory(buffer, typecode, shape) -> array
std::timed_mutex engineMutex;           // one call that changes the engine at a time
std::shared_timed_mutex inputMutex;     // shared by readers; held alone by a call that changes the engine
std::timed_mutex readerMutex;          // input routines also update counters/lazy listeners
std::mutex warningMutex;
std::vector<std::pair<std::string, std::string>> pendingWarnings;

// A Python error is already set; unwind to the binding's boundary.
struct PythonErrorSet {};

void warnHook(const char *id, const char *message) {
    std::lock_guard<std::mutex> guard(warningMutex);
    pendingWarnings.emplace_back(id, message);
}

void flushWarnings() {
    std::vector<std::pair<std::string, std::string>> w;
    {
        std::lock_guard<std::mutex> guard(warningMutex);
        w.swap(pendingWarnings);
    }
    for (auto &x : w) {
        std::string text = x.first + ": " + x.second;
        if (PyErr_WarnEx(PyExc_UserWarning, text.c_str(), 2) < 0) throw PythonErrorSet{};
    }
}

// How a call holds the engine:
//   Alone:   it changes the engine; nothing else runs beside it.
//   Reading: it reads input; it runs beside a playing timeline, one reader at a time.
//   Playing: a timeline; readers run beside it, other calls wait for it.
enum class Hold { Alone, Reading, Playing };

// Run fn without the GIL, holding the engine as `how` says. The main thread
// waits at most a moment: a call that holds the engine on another thread may
// itself be waiting for the main thread, so a longer wait could never end.
// Exceptions from the engine are carried back across the GIL boundary and
// rethrown with it held.
template <Hold how = Hold::Alone, class F> void engine(F &&fn) {
    std::exception_ptr error;
    bool busy = false;
    Py_BEGIN_ALLOW_THREADS
    {
        const bool main = pm::onMainThread();
        const auto moment = std::chrono::milliseconds(50);
        std::unique_lock<std::timed_mutex> calls(engineMutex, std::defer_lock);
        std::unique_lock<std::shared_timed_mutex> alone(inputMutex, std::defer_lock);
        std::shared_lock<std::shared_timed_mutex> reading(inputMutex, std::defer_lock);
        std::unique_lock<std::timed_mutex> reader(readerMutex, std::defer_lock);
        if (how != Hold::Reading)
            busy = main ? !calls.try_lock_for(moment) : (calls.lock(), false);
        if (!busy && how == Hold::Alone)
            busy = main ? !alone.try_lock_for(moment) : (alone.lock(), false);
        if (!busy && how != Hold::Alone)
            busy = main ? !reading.try_lock_for(moment) : (reading.lock(), false);
        // Readers may run beside playback, but not beside one another: keys()
        // updates diagnostic counters, and touchEvents() installs listeners lazily.
        if (!busy && how == Hold::Reading)
            busy = main ? !reader.try_lock_for(moment) : (reader.lock(), false);
        if (!busy)
            try { fn(); } catch (...) { error = std::current_exception(); }
    }
    Py_END_ALLOW_THREADS
    if (busy)
        throw pm::Error("PsychMetal is in use on another thread, and the main thread cannot wait "
                        "for it. Call it from the experiment's thread.");
    flushWarnings();
    if (error) std::rethrow_exception(error);
}

// Audio has its own state and its own lock: a sound can be scheduled from one
// thread while another draws, flips or plays a timeline. The main thread waits
// at most a moment, as for the engine.
std::timed_mutex audioMutex;
template <class F> void audio(F &&fn) {
    std::exception_ptr error;
    bool busy = false;
    Py_BEGIN_ALLOW_THREADS
    {
        std::unique_lock<std::timed_mutex> held(audioMutex, std::defer_lock);
        busy = pm::onMainThread() ? !held.try_lock_for(std::chrono::milliseconds(50)) : (held.lock(), false);
        if (!busy)
            try { fn(); } catch (...) { error = std::current_exception(); }
    }
    Py_END_ALLOW_THREADS
    if (busy)
        throw pm::Error("PsychMetal audio is in use on another thread, and the main thread cannot wait "
                        "for it. Call it from the experiment's thread.");
    flushWarnings();
    if (error) std::rethrow_exception(error);
}

void raiseError(const std::string &id, const std::string &message) {
    PyObject *exc = PyObject_CallFunction(ErrorType, "s", message.c_str());
    if (!exc) return;
    PyObject *pid = PyUnicode_FromString(id.c_str());
    if (pid) { PyObject_SetAttrString(exc, "id", pid); Py_DECREF(pid); }
    PyErr_SetObject(ErrorType, exc);
    Py_DECREF(exc);
}

// The boundary of every binding: C++ exceptions become Python exceptions.
PyObject *guarded(const std::function<PyObject *()> &body) {
    try {
        return body();
    } catch (const PythonErrorSet &) {
        return nullptr;
    } catch (const pm::Error &e) {
        raiseError(e.id(), e.what());
    } catch (const std::exception &e) {
        raiseError(pm::kErrNative, e.what());
    }
    return nullptr;
}

// ---- argument conversion (the engine's scalar conventions) --------------------

bool isNumber(PyObject *o) {
    if (PyBool_Check(o) || PyLong_Check(o) || PyFloat_Check(o)) return true;
    if (PyUnicode_Check(o) || PyBytes_Check(o) || PyComplex_Check(o) || o == Py_None) return false;
    // numpy scalars and one-element arrays define __float__; complex ones do not.
    PyNumberMethods *nb = Py_TYPE(o)->tp_as_number;
    return nb && nb->nb_float;
}

double scalar(PyObject *o, const char *name) {
    if (!isNumber(o)) pm::failNotScalar(name);
    double v = PyFloat_AsDouble(o);
    if (v == -1.0 && PyErr_Occurred()) { PyErr_Clear(); pm::failNotScalar(name); }
    return pm::checkFinite(v, name);
}

uint64_t unsignedScalar(PyObject *o, const char *name, uint64_t maximum) {
    return pm::checkUnsigned(scalar(o, name), name, maximum);
}

bool truth(PyObject *o, const char *name) { return unsignedScalar(o, name, 1) != 0; }

std::optional<double> optionalScalar(PyObject *o, const char *name) {
    if (!o || o == Py_None) return std::nullopt;
    return scalar(o, name);
}

// Holds buffers for the duration of one binding call; released with the GIL held.
struct Buffers {
    std::vector<Py_buffer> views;
    ~Buffers() { for (auto &v : views) PyBuffer_Release(&v); }
    pm::ArrayView view(PyObject *o) {
        pm::ArrayView v;
        if (!PyObject_CheckBuffer(o)) return v;
        Py_buffer b;
        if (PyObject_GetBuffer(o, &b, PyBUF_RECORDS_RO) < 0) { PyErr_Clear(); return v; }
        views.push_back(b);
        const char *f = b.format ? b.format : "B";
        bool bigEndian = *f == '>' || *f == '!';
        while (*f == '<' || *f == '=' || *f == '@') f++;
        if (!bigEndian && f[1] == 0) {
            if (*f == 'd' && b.itemsize == 8) v.type = pm::ScalarType::Float64;
            else if (*f == 'f' && b.itemsize == 4) v.type = pm::ScalarType::Float32;
            else if (*f == 'B' && b.itemsize == 1) v.type = pm::ScalarType::UInt8;
            else if (*f == '?' && b.itemsize == 1) v.type = pm::ScalarType::Bool;
        }
        if (b.ndim > 3) { v.type = pm::ScalarType::Other; return v; }
        v.data = b.buf;
        v.ndim = b.ndim;
        for (int i = 0; i < b.ndim; i++) {
            v.shape[(size_t)i] = (size_t)b.shape[i];
            v.strides[(size_t)i] = b.strides ? b.strides[i] : 0;
        }
        return v;
    }
};

// A sequence of exactly n real numbers.
template <size_t N> std::array<double, N> numbers(PyObject *o, const char *countMessage, const char *typeMessage) {
    std::array<double, N> out{};
    PyObject *seq = PySequence_Fast(o, countMessage);
    if (!seq) { PyErr_Clear(); throw pm::Error(countMessage); }
    Py_ssize_t n = PySequence_Fast_GET_SIZE(seq);
    if ((size_t)n != N) { Py_DECREF(seq); throw pm::Error(countMessage); }
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject *item = PySequence_Fast_GET_ITEM(seq, i);
        if (!isNumber(item)) { Py_DECREF(seq); throw pm::Error(typeMessage); }
        out[(size_t)i] = PyFloat_AsDouble(item);
        if (PyErr_Occurred()) { PyErr_Clear(); Py_DECREF(seq); throw pm::Error(typeMessage); }
    }
    Py_DECREF(seq);
    return out;
}

// ---- results ----------------------------------------------------------------------

PyObject *array(PyObject *buffer, const char *code, std::initializer_list<size_t> shape) {
    PyObject *dims = PyTuple_New((Py_ssize_t)shape.size());
    if (!dims) { Py_DECREF(buffer); throw PythonErrorSet{}; }
    Py_ssize_t i = 0;
    for (size_t d : shape) PyTuple_SET_ITEM(dims, i++, PyLong_FromSize_t(d));
    PyObject *out = arrayFactory ? PyObject_CallFunction(arrayFactory, "OsO", buffer, code, dims)
                                 : Py_BuildValue("(OsO)", buffer, code, dims);
    Py_DECREF(buffer);
    Py_DECREF(dims);
    if (!out) throw PythonErrorSet{};
    return out;
}

PyObject *doubles(const std::vector<double> &v, size_t rows, size_t cols) {
    PyObject *b = PyByteArray_FromStringAndSize((const char *)v.data(), (Py_ssize_t)(v.size() * sizeof(double)));
    if (!b) throw PythonErrorSet{};
    return array(b, "d", {rows, cols});
}

PyObject *checked(PyObject *o) { if (!o) throw PythonErrorSet{}; return o; }

PyObject *startupArray(const std::vector<pm::StartupRecord> &r) {
    std::vector<double> v;
    v.reserve(r.size() * 6);
    for (auto &x : r)
        v.insert(v.end(), {(double)x.token, (double)x.status, x.presentedTime, x.callbackTime,
                           (double)x.gpuDone, x.committedTime});
    return doubles(v, r.size(), 6);
}

int setItem(PyObject *d, const char *k, PyObject *v) {
    if (!v) return -1;
    int rc = PyDict_SetItemString(d, k, v);
    Py_DECREF(v);
    return rc;
}

PyObject *rect4(const pm::Rect4 &r) { return Py_BuildValue("(dddd)", r[0], r[1], r[2], r[3]); }

// ---- bindings ------------------------------------------------------------------------

PyObject *py_default_presentation(PyObject *, PyObject *) { return PyBool_FromLong(pm::defaultDisplayLink()); }

PyObject *py_cancel_timeline(PyObject *, PyObject *args) {
    // Deliberately bypass the engine mutex: playback holds it while the GIL is released.
    int cancel = 1;
    if (!PyArg_ParseTuple(args, "|p", &cancel)) return nullptr;
    pm::cancelTimeline(cancel != 0); Py_RETURN_NONE;
}
PyObject *py_update_timeline(PyObject *,PyObject *args) {
    PyObject *o;if(!PyArg_ParseTuple(args,"O",&o))return nullptr;
    return guarded([&]() -> PyObject * {Buffers hold;auto v=hold.view(o);
        // Independent control mutex: do not wait for playback's engine mutex.
        pm::updateTimeline(v);Py_RETURN_NONE;});
}
PyObject *py_play_timeline(PyObject *, PyObject *args) {
    PyObject *frames,*tracks,*keys=nullptr;
    if(!PyArg_ParseTuple(args,"OO|O",&frames,&tracks,&keys)) return nullptr;
    return guarded([&]() -> PyObject * {
        auto n=unsignedScalar(frames,"timeline frames",1000000);
        Buffers hold;auto view=hold.view(tracks);pm::ArrayView keyed;if(keys)keyed=hold.view(keys);pm::TimelineResult result{};
        engine<Hold::Playing>([&] {result=pm::playTimeline(n,view,keys?&keyed:nullptr);});
        return Py_BuildValue("{s:K,s:K,s:K,s:O,s:d,s:d,s:d,s:O,s:K,s:K,s:K,s:d,s:d,s:d}",
            "submitted",(unsigned long long)result.submitted,
            "firstToken",(unsigned long long)result.firstToken,
            "lastToken",(unsigned long long)result.lastToken,
            "cancelled",result.cancelled ? Py_True : Py_False,
            "expectedRefreshHz",result.expectedRefreshHz,
            "lastQueueMs",result.lastQueueMs,"lastFlipMs",result.lastFlipMs,
            "lastConfirmed",result.lastConfirmed ? Py_True : Py_False,
            "shown",(unsigned long long)result.shown,
            "late",(unsigned long long)result.late,
            "lateRefreshes",(unsigned long long)result.lateRefreshes,
            "firstLateSample",result.firstLateSample,
            "meanSampleMs",result.meanSampleMs,"longestIntervalMs",result.longestIntervalMs);
    });
}
PyObject *py_environment(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::EnvironmentInfo e;
        engine([&] { e=pm::environment(); });
        return Py_BuildValue("{s:s,s:s,s:s,s:s,s:O,s:O}",
            "engineVersion",e.engineVersion.c_str(),"platform",e.platform.c_str(),
            "osVersion",e.osVersion.c_str(),"gpuName",e.gpuName.c_str(),
            "gpuAvailable",e.gpuAvailable ? Py_True : Py_False,
            "debuggerAttached",e.debuggerAttached ? Py_True : Py_False);
    });
}
PyObject *py_version(PyObject *, PyObject *) { return PyUnicode_FromString(pm::version()); }

// ---- audio ----------------------------------------------------------------------------

// None is "at once" (NaN); anything else a finite time.
double whenArgument(PyObject *o, const char *name) {
    return (!o || o == Py_None) ? NAN : scalar(o, name);
}
PyObject *floats(const std::vector<float> &v, std::initializer_list<size_t> shape) {
    PyObject *b = PyByteArray_FromStringAndSize((const char *)v.data(), (Py_ssize_t)(v.size() * sizeof(float)));
    if (!b) throw PythonErrorSet{};
    return array(b, "f", shape);
}
PyObject *audioInfo(const pm::AudioInfo &i) {
    return checked(Py_BuildValue("{s:d,s:I,s:I,s:d,s:s,s:s,s:O,s:O,s:d,s:I,s:I,s:d,s:s,s:s,s:d}",
        "rate", i.rate, "channels", i.channels, "bufferFrames", i.bufferFrames, "outputLatency", i.outputLatency,
        "device", i.device.c_str(), "transport", i.transport.c_str(), "timed", i.timed ? Py_True : Py_False,
        "input", i.input ? Py_True : Py_False, "inputRate", i.inputRate, "inputChannels", i.inputChannels,
        "inputBufferFrames", i.inputBufferFrames, "inputLatency", i.inputLatency,
        "inputDevice", i.inputDevice.c_str(), "inputTransport", i.inputTransport.c_str(),
        "recordSeconds", i.recordSeconds));
}
const char *eventKind(pm::AudioEventKind k) {
    switch (k) {
    case pm::AudioEventKind::SoundStart: return "sound start";
    case pm::AudioEventKind::SoundEnd: return "sound end";
    case pm::AudioEventKind::RecordStart: return "recording start";
    case pm::AudioEventKind::RecordEnd: return "recording end";
    default: return "key";
    }
}
const char *eventStatus(pm::AudioEventStatus s) {
    switch (s) {
    case pm::AudioEventStatus::OnTime: return "on time";
    case pm::AudioEventStatus::Late: return "late";
    case pm::AudioEventStatus::Finished: return "finished";
    case pm::AudioEventStatus::Stopped: return "stopped";
    case pm::AudioEventStatus::Full: return "full";
    case pm::AudioEventStatus::Refused: return "refused";
    case pm::AudioEventStatus::Triggered: return "triggered";
    default: return "interrupted";
    }
}

PyObject *py_audio_devices(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        std::vector<pm::AudioDevice> list;
        audio([&] { list = pm::audioDevices(); });
        PyObject *out = checked(PyList_New(0));
        for (auto &d : list) {
            PyObject *item = Py_BuildValue("{s:L,s:s,s:s,s:I,s:I,s:d,s:O,s:O}", "id", (long long)d.id, "name", d.name.c_str(),
                "transport", d.transport.c_str(), "outputChannels", d.outputChannels, "inputChannels", d.inputChannels,
                "rate", d.rate, "defaultOutput", d.isDefaultOutput ? Py_True : Py_False,
                "defaultInput", d.isDefaultInput ? Py_True : Py_False);
            if (!item || PyList_Append(out, item) < 0) { Py_XDECREF(item); Py_DECREF(out); throw PythonErrorSet{}; }
            Py_DECREF(item);
        }
        return out;
    });
}

PyObject *py_open_audio(PyObject *, PyObject *args) {
    PyObject *device, *rate, *channels, *frames, *anyRoute, *input, *inputDevice, *inputChannels, *seconds;
    if (!PyArg_ParseTuple(args, "OOOOOOOOO", &device, &rate, &channels, &frames, &anyRoute, &input, &inputDevice,
                          &inputChannels, &seconds)) return nullptr;
    return guarded([&]() -> PyObject * {
        pm::AudioOptions o;
        o.device = device == Py_None ? -1 : (int64_t)unsignedScalar(device, "device", UINT32_MAX);
        o.rate = rate == Py_None ? 0 : scalar(rate, "rate");
        o.channels = (uint32_t)unsignedScalar(channels, "channels", 1024);
        o.bufferFrames = (uint32_t)unsignedScalar(frames, "bufferFrames", 1 << 20);
        o.anyRoute = truth(anyRoute, "anyRoute");
        o.input = truth(input, "input");
        o.inputDevice = inputDevice == Py_None ? -1 : (int64_t)unsignedScalar(inputDevice, "inputDevice", UINT32_MAX);
        o.inputChannels = (uint32_t)unsignedScalar(inputChannels, "inputChannels", 1024);
        o.recordSeconds = scalar(seconds, "recordSeconds");
        pm::AudioInfo info;
        audio([&] { info = pm::openAudio(o); });
        return audioInfo(info);
    });
}
PyObject *py_close_audio(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * { audio([] { pm::closeAudio(); }); Py_RETURN_NONE; });
}
PyObject *py_audio_status(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::AudioStatus s;
        audio([&] { s = pm::audioStatus(); });
        PyObject *info = s.open ? audioInfo(s.info) : (Py_INCREF(Py_None), Py_None);
        return checked(Py_BuildValue("{s:O,s:N,s:K,s:K,s:K,s:K,s:O,s:K}", "open", s.open ? Py_True : Py_False,
            "info", info, "sounds", (unsigned long long)s.sounds, "voices", (unsigned long long)s.voices,
            "clippedSamples", (unsigned long long)s.clippedSamples, "lostEvents", (unsigned long long)s.lostEvents,
            "recording", s.recording ? Py_True : Py_False, "recordedFrames", (unsigned long long)s.recordedFrames));
    });
}
PyObject *py_make_audio_stream(PyObject *,PyObject *args) {
    PyObject *f,*c;if(!PyArg_ParseTuple(args,"OO",&f,&c))return nullptr;
    return guarded([&]()->PyObject* {auto frames=unsignedScalar(f,"capacityFrames",16777216);auto channels=unsignedScalar(c,"channels",32);
        uint64_t id=0;audio([&]{id=pm::makeAudioStream(frames,(uint32_t)channels);});return PyLong_FromUnsignedLongLong(id);});
}
PyObject *py_refill_sound(PyObject *,PyObject *args) {
    PyObject *h,*samples,*e;if(!PyArg_ParseTuple(args,"OOO",&h,&samples,&e))return nullptr;
    return guarded([&]()->PyObject* {auto id=unsignedScalar(h,"sound",pm::kMaxId);Buffers hold;auto v=hold.view(samples);bool final=truth(e,"final");
        uint64_t n=0;audio([&]{n=pm::refillSound(id,v,final);});return PyLong_FromUnsignedLongLong(n);});
}
PyObject *py_audio_stream_status(PyObject *,PyObject *args) {
    PyObject *h;if(!PyArg_ParseTuple(args,"O",&h))return nullptr;
    return guarded([&]()->PyObject* {auto id=unsignedScalar(h,"sound",pm::kMaxId);pm::AudioStreamStatus s;audio([&]{s=pm::audioStreamStatus(id);});
        return checked(Py_BuildValue("{s:K,s:K,s:K,s:K,s:K,s:K,s:O}","capacity",(unsigned long long)s.capacity,"queued",(unsigned long long)s.queued,
            "free",(unsigned long long)s.free,"written",(unsigned long long)s.written,"consumed",(unsigned long long)s.consumed,
            "underflowFrames",(unsigned long long)s.underflowFrames,"sealed",s.sealed?Py_True:Py_False));});
}
PyObject *py_make_sound(PyObject *, PyObject *args) {
    PyObject *samples, *rate;
    if (!PyArg_ParseTuple(args, "OO", &samples, &rate)) return nullptr;
    return guarded([&]() -> PyObject * {
        Buffers hold;
        pm::ArrayView v = hold.view(samples);
        double r = rate == Py_None ? 0 : scalar(rate, "rate");
        uint64_t h = 0;
        audio([&] { h = pm::makeSound(v, r); });
        return PyLong_FromUnsignedLongLong(h);
    });
}
PyObject *py_close_sound(PyObject *, PyObject *args) {
    PyObject *h;
    if (!PyArg_ParseTuple(args, "O", &h)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t handle = unsignedScalar(h, "sound", pm::kMaxId);
        audio([&] { pm::closeSound(handle); });
        Py_RETURN_NONE;
    });
}
PyObject *py_play(PyObject *, PyObject *args) {
    PyObject *h, *when, *frame, *offset, *gain, *repeats;
    if (!PyArg_ParseTuple(args, "OOOOOO", &h, &when, &frame, &offset, &gain, &repeats)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t sound = unsignedScalar(h, "sound", pm::kMaxId);
        double t = whenArgument(when, "when");
        uint64_t token = frame == Py_None ? 0 : unsignedScalar(frame, "frame", pm::kMaxId);
        double off = scalar(offset, "offset"), g = scalar(gain, "gain");
        uint32_t n = (uint32_t)unsignedScalar(repeats, "repeats", UINT32_MAX);
        uint64_t voice = 0;
        audio([&] { voice = pm::play(sound, t, token, off, g, n); });
        return PyLong_FromUnsignedLongLong(voice);
    });
}
PyObject *py_stop_sound(PyObject *, PyObject *args) {
    PyObject *voice, *when;
    if (!PyArg_ParseTuple(args, "OO", &voice, &when)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t v = voice == Py_None ? 0 : unsignedScalar(voice, "voice", pm::kMaxId);
        double t = whenArgument(when, "when");
        audio([&] { pm::stopSound(v, t); });
        Py_RETURN_NONE;
    });
}
PyObject *py_modulate(PyObject *, PyObject *args) {
    PyObject *voice, *hz, *phase, *depth, *when;
    if (!PyArg_ParseTuple(args, "OOOOO", &voice, &hz, &phase, &depth, &when)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t v = unsignedScalar(voice, "voice", pm::kMaxId);
        double f = scalar(hz, "hz"), ph = scalar(phase, "phase"), d = scalar(depth, "depth");
        double t = whenArgument(when, "when");
        audio([&] { pm::modulate(v, f, ph, d, t); });
        Py_RETURN_NONE;
    });
}
PyObject *py_start_recording(PyObject *, PyObject *args) {
    PyObject *when;
    if (!PyArg_ParseTuple(args, "O", &when)) return nullptr;
    return guarded([&]() -> PyObject * {
        double t = whenArgument(when, "when");
        uint64_t id = 0;
        audio([&] { id = pm::startRecording(t); });
        return PyLong_FromUnsignedLongLong(id);
    });
}
PyObject *py_stop_recording(PyObject *, PyObject *args) {
    PyObject *when;
    if (!PyArg_ParseTuple(args, "O", &when)) return nullptr;
    return guarded([&]() -> PyObject * {
        double t = whenArgument(when, "when");
        audio([&] { pm::stopRecording(t); });
        Py_RETURN_NONE;
    });
}
PyObject *py_get_recording(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::Recording r;
        audio([&] { r = pm::getRecording(); });
        std::vector<float> rows((size_t)r.frames * r.channels);      // (frames, channels), row-major
        for (uint32_t c = 0; c < r.channels; c++)
            for (uint64_t i = 0; i < r.frames; i++) rows[(size_t)i * r.channels + c] = r.samples[(size_t)c * r.frames + i];
        PyObject *samples = floats(rows, {(size_t)r.frames, (size_t)r.channels});
        return checked(Py_BuildValue("(NddO)", samples, r.rate, r.firstSampleTime, r.recording ? Py_True : Py_False));
    });
}
PyObject *py_voice_key(PyObject *, PyObject *args) {
    PyObject *threshold, *when, *window, *minimum;
    if (!PyArg_ParseTuple(args, "OOOO", &threshold, &when, &window, &minimum)) return nullptr;
    return guarded([&]() -> PyObject * {
        double th = scalar(threshold, "threshold"), t = whenArgument(when, "when"), w = scalar(window, "window");
        uint32_t m = (uint32_t)unsignedScalar(minimum, "minimum", UINT32_MAX);
        uint64_t id = 0;
        audio([&] { id = pm::voiceKey(th, t, w, m); });
        return PyLong_FromUnsignedLongLong(id);
    });
}
PyObject *py_input_recent(PyObject *, PyObject *args) {
    PyObject *seconds;
    if (!PyArg_ParseTuple(args, "O", &seconds)) return nullptr;
    return guarded([&]() -> PyObject * {
        double s = scalar(seconds, "seconds");
        pm::InputRecent r;
        audio([&] { r = pm::inputRecent(s); });
        PyObject *samples = floats(r.samples, {r.samples.size()});
        return checked(Py_BuildValue("(Ndd)", samples, r.rate, r.endTime));
    });
}
PyObject *py_audio_results(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        std::vector<pm::AudioEvent> events;
        audio([&] { events = pm::audioResults(); });
        PyObject *out = checked(PyList_New(0));
        for (auto &e : events) {
            PyObject *item = Py_BuildValue("{s:s,s:K,s:d,s:d,s:s,s:d,s:d,s:K,s:d}", "kind", eventKind(e.kind),
                "id", (unsigned long long)e.id, "requested", e.requested, "time", e.time, "status", eventStatus(e.status),
                "frames", e.frames, "level", e.level, "frameToken", (unsigned long long)e.frameToken,
                "framePresented", e.framePresented);
            if (!item || PyList_Append(out, item) < 0) { Py_XDECREF(item); Py_DECREF(out); throw PythonErrorSet{}; }
            Py_DECREF(item);
        }
        return out;
    });
}

PyObject *py_set_array_factory(PyObject *, PyObject *fn) {
    if (!PyCallable_Check(fn)) { PyErr_SetString(PyExc_TypeError, "factory must be callable"); return nullptr; }
    Py_XDECREF(arrayFactory);
    Py_INCREF(fn);
    arrayFactory = fn;
    Py_RETURN_NONE;
}

PyObject *py_on_main_thread(PyObject *, PyObject *) { return PyBool_FromLong(pm::onMainThread()); }

PyObject *py_service_main_run_loop(PyObject *, PyObject *args) {
    double seconds = 0.05;
    if (!PyArg_ParseTuple(args, "|d", &seconds)) return nullptr;
    return guarded([&]() -> PyObject * {
        // No engine mutex: this runs on the main thread while a worker may be
        // inside an engine call that is waiting for exactly this servicing.
        std::exception_ptr error;
        Py_BEGIN_ALLOW_THREADS
        try { pm::serviceMainRunLoop(seconds); } catch (...) { error = std::current_exception(); }
        Py_END_ALLOW_THREADS
        if (error) std::rethrow_exception(error);
        if (PyErr_CheckSignals() < 0) throw PythonErrorSet{};
        Py_RETURN_NONE;
    });
}

PyObject *py_shutdown(PyObject *, PyObject *) {
    Py_BEGIN_ALLOW_THREADS
    {
        // At exit, on the main thread. A thread still inside the engine may be
        // waiting for the main thread, which would then never come: after a
        // second the engine is left as it is, and the process ends anyway.
        std::unique_lock<std::timed_mutex> calls(engineMutex, std::chrono::seconds(1));
        if (calls.owns_lock()) {
            std::unique_lock<std::shared_timed_mutex> alone(inputMutex, std::chrono::seconds(1));
            if (alone.owns_lock()) {
                // shutdown also destroys audio; serialize it with audio calls
                // that release the GIL while accessing the session.
                std::unique_lock<std::timed_mutex> audio(audioMutex, std::chrono::seconds(1));
                if (audio.owns_lock()) pm::shutdown();
            }
        }
    }
    Py_END_ALLOW_THREADS
    std::lock_guard<std::mutex> guard(warningMutex);
    pendingWarnings.clear();
    Py_RETURN_NONE;
}

PyObject *py_prepare_app(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * { engine([] { pm::prepareApp(); }); Py_RETURN_NONE; });
}

PyObject *py_open_session(PyObject *, PyObject *args) {
    PyObject *screen, *count, *refresh = Py_None, *readback = nullptr, *bits = nullptr, *link = nullptr, *capture = nullptr;
    if (!PyArg_ParseTuple(args, "OO|OOOOO", &screen, &count, &refresh, &readback, &bits, &link, &capture))
        return nullptr;
    return guarded([&]() -> PyObject * {
        pm::OpenOptions o;
        o.screenIndex = scalar(screen, "screen index");
        o.drawableCount = unsignedScalar(count, "maximum drawable count", 3);
        o.refreshHz = optionalScalar(refresh, "refreshHz");
        if (readback && readback != Py_None) o.readback = truth(readback, "readback");
        if (bits && bits != Py_None) o.bitDepth = unsignedScalar(bits, "bit depth", 16);
        if (link && link != Py_None) o.displayLink = truth(link, "display link");
        if(capture && capture!=Py_None)o.captureDisplay=truth(capture,"capture display");
        pm::OpenResult r{};
        engine([&] { r = pm::openSession(o); });
        return Py_BuildValue("(dddddK)", r.pixelWidth, r.pixelHeight, r.ifi, r.pointWidth, r.pointHeight,
                             (unsigned long long)r.sessionToken);
    });
}

PyObject *py_open_export(PyObject *,PyObject *args) {
    PyObject *width,*height,*rate,*readback;
    if(!PyArg_ParseTuple(args,"OOOO",&width,&height,&rate,&readback)) return nullptr;
    return guarded([&]() -> PyObject * {
        auto w=unsignedScalar(width,"export width",8192),h=unsignedScalar(height,"export height",8192);
        double hz=scalar(rate,"refreshHz");bool rb=truth(readback,"readback");pm::OpenResult r{};
        engine([&]{r=pm::openExport(w,h,hz,rb);});
        return Py_BuildValue("(dddddK)",r.pixelWidth,r.pixelHeight,r.ifi,r.pointWidth,r.pointHeight,(unsigned long long)r.sessionToken);
    });
}

PyObject *py_startup_history(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        std::vector<pm::StartupRecord> r;
        engine([&] { r = pm::startupHistory(); });
        return startupArray(r);
    });
}

PyObject *py_confirm_startup(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        std::vector<pm::StartupRecord> r;
        engine([&] { r = pm::confirmStartup(); });
        return startupArray(r);
    });
}

PyObject *py_close_session(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * { engine([] { pm::closeSession(); }); Py_RETURN_NONE; });
}

PyObject *py_flip(PyObject *, PyObject *args) {
    PyObject *when = nullptr;
    if (!PyArg_ParseTuple(args, "|O", &when)) return nullptr;
    return guarded([&]() -> PyObject * {
        double target = (when && when != Py_None) ? scalar(when, "target") : 0;
        pm::FlipResult r{};
        engine([&] { r = pm::flip(target); });
        return Py_BuildValue("(dOdddddK)", r.time, r.confirmed ? Py_True : Py_False, r.slipRefreshes,
                             r.gridPeriod, r.queueMs, r.callMs, r.returnTime, (unsigned long long)r.token);
    });
}

PyObject *py_flip_status(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::FlipStatus s{};
        engine([&] { s = pm::flipStatus(); });
        return Py_BuildValue("(OOK)", s.confirmed ? Py_True : Py_False, s.dropped ? Py_True : Py_False,
                             (unsigned long long)s.droppedFrames);
    });
}

PyObject *py_grid_anchor(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::GridAnchor g{};
        engine([&] { g = pm::gridAnchor(); });
        return Py_BuildValue("(ddd)", g.anchor, g.period, g.samples);
    });
}

PyObject *py_next_phase(PyObject *, PyObject *args) {
    PyObject *a, *p;
    if (!PyArg_ParseTuple(args, "OO", &a, &p)) return nullptr;
    return guarded([&]() -> PyObject * {
        double after = scalar(a, "time"), phase = scalar(p, "phase"), t = 0;
        engine([&] { t = pm::nextPhase(after, phase); });
        return PyFloat_FromDouble(t);
    });
}

PyObject *py_next_refresh(PyObject *, PyObject *args) {
    PyObject *a;
    if (!PyArg_ParseTuple(args, "O", &a)) return nullptr;
    return guarded([&]() -> PyObject * {
        double after = scalar(a, "time"), t = 0;
        engine([&] { t = pm::nextRefresh(after); });
        return PyFloat_FromDouble(t);
    });
}

PyObject *py_wait_to_draw(PyObject *, PyObject *args) {
    PyObject *t, *b;
    if (!PyArg_ParseTuple(args, "OO", &t, &b)) return nullptr;
    return guarded([&]() -> PyObject * {
        double target = scalar(t, "target presentation time"), budget = scalar(b, "drawing budget");
        pm::WaitToDrawResult r{};
        engine([&] { r = pm::waitToDraw(target, budget); });
        return Py_BuildValue("(ddd)", r.wokeAt, r.lead, r.deadline);
    });
}

PyObject *py_set_background_color(PyObject *, PyObject *args) {
    PyObject *c[4];
    if (!PyArg_ParseTuple(args, "OOOO", &c[0], &c[1], &c[2], &c[3])) return nullptr;
    return guarded([&]() -> PyObject * {
        double v[4];
        for (int i = 0; i < 4; i++) v[i] = scalar(c[i], "background colour component");
        engine([&] { pm::setBackgroundColor(v[0], v[1], v[2], v[3]); });
        Py_RETURN_NONE;
    });
}

PyObject *py_add_shapes(PyObject *, PyObject *args) {
    PyObject *o[5];
    if (!PyArg_ParseTuple(args, "OOOOO", &o[0], &o[1], &o[2], &o[3], &o[4])) return nullptr;
    return guarded([&]() -> PyObject * {
        Buffers hold;
        pm::ArrayView v[5];
        for (int i = 0; i < 5; i++) v[i] = hold.view(o[i]);
        engine([&] { pm::addShapes(v[0], v[1], v[2], v[3], v[4]); });
        Py_RETURN_NONE;
    });
}


PyObject *py_check_stimulus(PyObject *, PyObject *args) {
    PyObject *o; if(!PyArg_ParseTuple(args,"O",&o)) return nullptr;
    return guarded([&]() -> PyObject * { Buffers hold; auto v=hold.view(o);
        engine([&]{ pm::checkStimulus(v); }); Py_RETURN_NONE; });
}
PyObject *py_check_mask(PyObject *, PyObject *args) {
    PyObject *o;if(!PyArg_ParseTuple(args,"O",&o)) return nullptr;
    return guarded([&]() -> PyObject * {Buffers hold;auto v=hold.view(o);
        engine([&]{pm::checkMask(v);});Py_RETURN_NONE;});
}
std::string utf8(PyObject *o, const char *name);

// A dict of named options, as the engine takes them: str, or a sequence of numbers
// (the Python wrapper flattens numbers to a list).
std::vector<pm::Option> optionsOf(PyObject *dict) {
    if (!PyDict_Check(dict)) throw pm::Error(pm::kErrGeneral, "Options must be a dict.");
    std::vector<pm::Option> out;
    PyObject *key, *value;
    Py_ssize_t at = 0;
    while (PyDict_Next(dict, &at, &key, &value)) {
        pm::Option o;
        const char *name = PyUnicode_Check(key) ? PyUnicode_AsUTF8(key) : nullptr;
        if (!name) throw PythonErrorSet{};
        o.name = name;
        if (PyUnicode_Check(value)) {
            const char *s = PyUnicode_AsUTF8(value);
            if (!s) throw PythonErrorSet{};
            o.isText = true; o.text = s;
        } else {
            PyObject *seq = PySequence_Fast(value, "options are text or numbers");
            if (!seq) { PyErr_Clear(); throw pm::Error(pm::kErrGeneral, "Invalid option: " + o.name + " must be real numbers or text."); }
            for (Py_ssize_t i = 0; i < PySequence_Fast_GET_SIZE(seq); i++) {
                double v = PyFloat_AsDouble(PySequence_Fast_GET_ITEM(seq, i));
                if (v == -1 && PyErr_Occurred()) { PyErr_Clear(); Py_DECREF(seq);
                    throw pm::Error(pm::kErrGeneral, "Invalid option: " + o.name + " must be real numbers or text."); }
                o.numbers.push_back(v);
            }
            Py_DECREF(seq);
        }
        out.push_back(o);
    }
    return out;
}
template <size_t N> PyObject *tupleOf(const std::array<double, N> &p) {
    PyObject *t = checked(PyTuple_New(N));
    for (size_t i = 0; i < N; i++) PyTuple_SET_ITEM(t, i, PyFloat_FromDouble(p[i]));
    return t;
}
PyObject *py_make_stimulus(PyObject *, PyObject *args) {
    PyObject *kind, *options;
    if (!PyArg_ParseTuple(args, "OO", &kind, &options)) return nullptr;
    return guarded([&]() -> PyObject * { return tupleOf(pm::makeStimulus(utf8(kind, "kind"), optionsOf(options))); });
}
PyObject *py_stimulus_with(PyObject *, PyObject *args) {
    PyObject *recipe, *options;
    if (!PyArg_ParseTuple(args, "OO", &recipe, &options)) return nullptr;
    return guarded([&]() -> PyObject * { Buffers hold; auto v = hold.view(recipe);
        return tupleOf(pm::stimulusWith(v, optionsOf(options))); });
}
PyObject *py_make_mask(PyObject *, PyObject *args) {
    PyObject *kind, *options;
    if (!PyArg_ParseTuple(args, "OO", &kind, &options)) return nullptr;
    return guarded([&]() -> PyObject * { return tupleOf(pm::makeMask(utf8(kind, "kind"), optionsOf(options))); });
}
PyObject *py_key_names(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        const std::vector<pm::KeyName> &names = pm::keyNames();
        PyObject *list = checked(PyList_New((Py_ssize_t)names.size()));
        for (size_t i = 0; i < names.size(); i++) {
            PyObject *pair = Py_BuildValue("(is)", names[i].usage, names[i].name);
            if (!pair) { Py_DECREF(list); throw PythonErrorSet{}; }
            PyList_SET_ITEM(list, (Py_ssize_t)i, pair);
        }
        return list;
    });
}
PyObject *py_sound(PyObject *args, int which) {
    double a[5] = {NAN, NAN, NAN, NAN, NAN};
    const int needed = which == 1 ? 1 : which == 0 ? 3 : 2, most = which == 1 ? 3 : 5;
    Py_ssize_t n = PyTuple_Size(args);
    if (n < needed || n > most) { PyErr_SetString(PyExc_TypeError, "wrong number of arguments for a sound"); return nullptr; }
    return guarded([&]() -> PyObject * {
        for (Py_ssize_t i = 0; i < n; i++) {
            PyObject *v = PyTuple_GET_ITEM(args, i);
            a[i] = v == Py_None ? NAN : scalar(v, "sound argument");
        }
        auto at = [&](int i, double otherwise) { return i < n && !std::isnan(a[i]) ? a[i] : otherwise; };
        std::vector<double> x = which == 0 ? pm::tone(a[0], a[1], a[2], at(3, 0.5), at(4, 0.005))
                              : which == 1 ? pm::click(a[0], at(1, 0.001), at(2, 0.9))
                              : pm::whiteNoise(a[0], a[1], at(2, 0.3), n > 3 ? a[3] : NAN, at(4, 0.005));
        return doubles(x, x.size(), 1);
    });
}
PyObject *py_tone(PyObject *, PyObject *args) { return py_sound(args, 0); }
PyObject *py_click(PyObject *, PyObject *args) { return py_sound(args, 1); }
PyObject *py_white_noise(PyObject *, PyObject *args) { return py_sound(args, 2); }

PyObject *py_draw_masked_texture(PyObject *,PyObject *args) {
    PyObject *h,*p,*m,*c=nullptr;if(!PyArg_ParseTuple(args,"OOO|O",&h,&p,&m,&c))return nullptr;
    return guarded([&]() -> PyObject * {Buffers hold;auto v=hold.view(p);
        pm::ArrayView coverage;if(c)coverage=hold.view(c);
        auto source=unsignedScalar(h,"texture",pm::kMaxId),mask=unsignedScalar(m,"mask",pm::kMaxId);
        engine([&]{pm::drawMaskedTexture(source,v,mask,c ? &coverage : nullptr);});Py_RETURN_NONE;});
}
PyObject *py_draw_stimulus(PyObject *, PyObject *args) {
    PyObject *p,*r,*m,*c=nullptr; if(!PyArg_ParseTuple(args,"OOO|O",&p,&r,&m,&c)) return nullptr;
    return guarded([&]() -> PyObject * { Buffers hold; auto v=hold.view(p), d=hold.view(r);
        pm::ArrayView coverage;if(c) coverage=hold.view(c);
        auto mask=unsignedScalar(m,"mask",pm::kMaxId);
        engine([&]{ pm::drawStimulus(v,d,mask,c ? &coverage : nullptr); }); Py_RETURN_NONE; });
}
PyObject *py_make_texture(PyObject *, PyObject *args) {
    PyObject *img;
    if (!PyArg_ParseTuple(args, "O", &img)) return nullptr;
    return guarded([&]() -> PyObject * {
        Buffers hold;
        pm::ArrayView v = hold.view(img);
        uint64_t h = 0;
        engine([&] { h = pm::makeTexture(v); });
        return PyLong_FromUnsignedLongLong(h);
    });
}

PyObject *py_update_texture(PyObject *, PyObject *args) {
    PyObject *handle, *img, *left = nullptr, *top = nullptr;
    if (!PyArg_ParseTuple(args, "OO|OO", &handle, &img, &left, &top)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t h = unsignedScalar(handle, "texture handle", pm::kMaxId);
        Buffers hold;
        pm::ArrayView v = hold.view(img);
        if (left && top) {
            double x = scalar(left, "texture left"), y = scalar(top, "texture top");
            engine([&] { pm::updateTextureRegion(h, v, x, y); });
        } else if (left) {
            throw pm::Error("update_texture takes a handle and an image, and optionally left and top.");
        } else {
            engine([&] { pm::updateTexture(h, v); });
        }
        Py_RETURN_NONE;
    });
}

PyObject *py_draw_textures(PyObject *, PyObject *args) {
    PyObject *o[6];
    if (!PyArg_ParseTuple(args, "OOOOOO", &o[0], &o[1], &o[2], &o[3], &o[4], &o[5])) return nullptr;
    return guarded([&]() -> PyObject * {
        Buffers hold;
        pm::ArrayView v[6];
        for (int i = 0; i < 6; i++) v[i] = hold.view(o[i]);
        engine([&] { pm::drawTextures(v[0], v[1], v[2], v[3], v[4], v[5]); });
        Py_RETURN_NONE;
    });
}

PyObject *py_close_texture(PyObject *, PyObject *args) {
    PyObject *handle;
    if (!PyArg_ParseTuple(args, "O", &handle)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t h = unsignedScalar(handle, "texture handle", pm::kMaxId);
        engine([&] { pm::closeTexture(h); });
        Py_RETURN_NONE;
    });
}

PyObject *py_set_blend_mode(PyObject *, PyObject *args) {
    PyObject *mode;
    if (!PyArg_ParseTuple(args, "O", &mode)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t m = unsignedScalar(mode, "blend mode", 2);
        engine([&] { pm::setBlendMode(m); });
        Py_RETURN_NONE;
    });
}

PyObject *py_set_clip(PyObject *, PyObject *args) {
    PyObject *r = Py_None;
    if (!PyArg_ParseTuple(args, "|O", &r)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::optional<pm::Rect4> rect;
        if (r != Py_None) {
            const char *m = "The clip rect must be [left top right bottom] in whole pixels.";
            rect = numbers<4>(r, m, m);
        }
        engine([&] { pm::setClip(rect); });
        Py_RETURN_NONE;
    });
}

PyObject *py_open_offscreen(PyObject *, PyObject *args) {
    PyObject *w, *h, *color;
    if (!PyArg_ParseTuple(args, "OOO", &w, &h, &color)) return nullptr;
    return guarded([&]() -> PyObject * {
        double width = scalar(w, "offscreen width"), height = scalar(h, "offscreen height");
        const char *m = "Offscreen window colour must be four real numbers, RGBA.";
        pm::Rect4 rgba = numbers<4>(color, m, m);
        uint64_t handle = 0;
        engine([&] { handle = pm::openOffscreen(width, height, rgba); });
        return PyLong_FromUnsignedLongLong(handle);
    });
}

PyObject *py_set_target(PyObject *, PyObject *args) {
    PyObject *handle;
    if (!PyArg_ParseTuple(args, "O", &handle)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t h = unsignedScalar(handle, "target handle", pm::kMaxId);
        engine([&] { pm::setTarget(h); });
        Py_RETURN_NONE;
    });
}

PyObject *py_draw_polygon(PyObject *, PyObject *args) {
    PyObject *points, *color, *pen;
    if (!PyArg_ParseTuple(args, "OOO", &points, &color, &pen)) return nullptr;
    return guarded([&]() -> PyObject * {
        Buffers hold;
        pm::ArrayView v = hold.view(points);
        const char *m = "Polygon colour must be four real numbers, RGBA.";
        pm::Rect4 rgba = numbers<4>(color, m, m);
        double width = scalar(pen, "pen width");
        engine([&] { pm::drawPolygon(v, rgba, width); });
        Py_RETURN_NONE;
    });
}

PyObject *py_set_gamma(PyObject *, PyObject *args) {
    PyObject *o[3];
    if (!PyArg_ParseTuple(args, "OOO", &o[0], &o[1], &o[2])) return nullptr;
    return guarded([&]() -> PyObject * {
        double e[3];
        for (int c = 0; c < 3; c++) e[c] = scalar(o[c], "gamma exponent");
        engine([&] { pm::setGamma(e[0], e[1], e[2]); });
        Py_RETURN_NONE;
    });
}

PyObject *py_set_gamma_table(PyObject *, PyObject *args) {
    PyObject *table;
    if (!PyArg_ParseTuple(args, "O", &table)) return nullptr;
    return guarded([&]() -> PyObject * {
        Buffers hold;
        pm::ArrayView v = hold.view(table);
        engine([&] { pm::setGammaTable(v); });
        Py_RETURN_NONE;
    });
}

// A str argument as UTF-8.
std::string utf8(PyObject *o, const char *name) {
    const char *s = PyUnicode_Check(o) ? PyUnicode_AsUTF8(o) : nullptr;
    if (!s) {
        PyErr_Clear();
        throw pm::Error(std::string(name) + " must be a string.");
    }
    return s;
}

// ---- movies (MOVIES.md) -------------------------------------------------------------

pm::Rect4 four(PyObject *o, const char *what) {
    std::string m = std::string(what) + " must be four real numbers.";
    return numbers<4>(o, m.c_str(), m.c_str());
}
PyObject *py_open_movie(PyObject *, PyObject *args) {
    PyObject *path;
    if (!PyArg_ParseTuple(args, "O", &path)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::string p = utf8(path, "The movie path");
        pm::MovieInfo i;
        uint64_t h = 0;
        engine([&] { h = pm::openMovie(p, i); });
        return checked(Py_BuildValue("(K{s:d,s:d,s:d,s:d,s:d,s:O,s:d,s:d,s:s,s:d})", (unsigned long long)h,
            "width", i.width, "height", i.height, "frames", i.frames, "frameRate", i.frameRate,
            "duration", i.duration, "constantRate", i.constantRate ? Py_True : Py_False,
            "soundChannels", i.soundChannels, "soundRate", i.soundRate, "codec", i.codec.c_str(),"keyframeInterval",i.keyframeInterval));
    });
}
PyObject *py_transcode_movie(PyObject *,PyObject *args) {
    PyObject *a,*b,*c;if(!PyArg_ParseTuple(args,"OOO",&a,&b,&c))return nullptr;
    return guarded([&]()->PyObject* {
        auto source=utf8(a,"source"),destination=utf8(b,"destination"),codec=utf8(c,"codec");uint64_t frames=0;
        engine([&]{frames=pm::transcodeMovie(source,destination,codec);});return PyLong_FromUnsignedLongLong(frames);
    });
}
PyObject *py_prepare_movie(PyObject *,PyObject *args) {
    PyObject *h,*f,*b;if(!PyArg_ParseTuple(args,"OOO",&h,&f,&b))return nullptr;
    return guarded([&]()->PyObject* {
        auto handle=unsignedScalar(h,"movie",pm::kMaxId);auto frames=unsignedScalar(f,"frames",256);
        auto bytes=unsignedScalar(b,"maxBytes",2147483648ull);uint64_t count=0;
        engine([&]{count=pm::prepareMovie(handle,(uint32_t)frames,bytes);});return PyLong_FromUnsignedLongLong(count);
    });
}
PyObject *py_movie_frame_times(PyObject *, PyObject *args) {
    PyObject *h;
    if (!PyArg_ParseTuple(args, "O", &h)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t handle = unsignedScalar(h, "movie", pm::kMaxId);
        std::vector<double> t;
        engine([&] { t = pm::movieFrameTimes(handle); });
        return doubles(t, t.size(), 1);
    });
}
PyObject *py_draw_movie_frame(PyObject *, PyObject *args) {
    PyObject *h, *index, *src, *dst, *angle, *tint, *filter;
    if (!PyArg_ParseTuple(args, "OOOOOOO", &h, &index, &src, &dst, &angle, &tint, &filter)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t handle = unsignedScalar(h, "movie", pm::kMaxId), i = unsignedScalar(index, "frame", pm::kMaxId);
        pm::Rect4 s = four(src, "The source rect"), d = four(dst, "The destination rect"), t = four(tint, "The tint");
        double a = scalar(angle, "angle");
        int f = (int)unsignedScalar(filter, "filter", 1);
        engine([&] { pm::drawMovieFrame(handle, i, s, d, a, t, f); });
        Py_RETURN_NONE;
    });
}
PyObject *py_movie_sound(PyObject *, PyObject *args) {
    PyObject *h, *rate, *speed, *keep;
    if (!PyArg_ParseTuple(args, "OOOO", &h, &rate, &speed, &keep)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t handle = unsignedScalar(h, "movie", pm::kMaxId);
        double r = scalar(rate, "rate"), sp = scalar(speed, "speed");
        bool keepPitch = unsignedScalar(keep, "keep_pitch", 1) != 0;
        uint32_t channels = 1;
        std::vector<float> v;
        engine([&] { v = pm::movieSound(handle, r, sp, keepPitch, channels); });
        return floats(v, {v.size() / channels, (size_t)channels});      // (frames, channels), interleaved is row-major
    });
}
PyObject *py_play_movie(PyObject *, PyObject *args) {
    PyObject *h, *first, *count, *refreshes, *src, *dst, *when, *sound, *gain;
    if (!PyArg_ParseTuple(args, "OOOOOOOOO", &h, &first, &count, &refreshes, &src, &dst, &when, &sound, &gain))
        return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t handle = unsignedScalar(h, "movie", pm::kMaxId);
        uint64_t f = unsignedScalar(first, "first frame", pm::kMaxId), n = unsignedScalar(count, "frame count", pm::kMaxId);
        uint32_t r = (uint32_t)unsignedScalar(refreshes, "refreshes per frame", 1000);
        pm::Rect4 s = four(src, "The source rect"), d = four(dst, "The destination rect");
        double t = whenArgument(when, "when"), g = scalar(gain, "gain");
        uint64_t snd = unsignedScalar(sound, "sound", pm::kMaxId);
        pm::MovieResult m{};
        // With a sound, the movie starts it and may stop it: audio calls from other
        // threads wait until the movie ends.
        bool audioBusy = false;
        engine<Hold::Playing>([&] {
            std::unique_lock<std::timed_mutex> held(audioMutex, std::defer_lock);
            if (snd) audioBusy = pm::onMainThread() ? !held.try_lock_for(std::chrono::milliseconds(50)) : (held.lock(), false);
            if (!audioBusy) m = pm::playMovie(handle, f, n, r, s, d, t, snd, g);
        });
        if (audioBusy)
            throw pm::Error("PsychMetal audio is in use on another thread, and the main thread cannot wait "
                            "for it. Call it from the experiment's thread.");
        return checked(Py_BuildValue("{s:K,s:K,s:K,s:K,s:O,s:d,s:d,s:K,s:K,s:K,s:d,s:d,s:K,s:d,s:d,s:d}",
            "submitted", (unsigned long long)m.submitted, "firstToken", (unsigned long long)m.firstToken,
            "lastToken", (unsigned long long)m.lastToken, "frames", (unsigned long long)m.frames,
            "cancelled", m.cancelled ? Py_True : Py_False, "start", m.start, "firstPresented", m.firstPresented,
            "shown", (unsigned long long)m.shown, "late", (unsigned long long)m.late,
            "lateRefreshes", (unsigned long long)m.lateRefreshes, "expectedRefreshHz", m.expectedRefreshHz,
            "longestIntervalMs", m.longestIntervalMs, "voice", (unsigned long long)m.voice, "audioStartOffsetMs",m.audioStartOffsetMs,
            "audioEndOffsetMs",m.audioEndOffsetMs,"audioVideoDriftMs",m.audioVideoDriftMs));
    });
}
// Recording takes the audio lock as well: it taps the audio output, and must not
// do so while another thread opens or closes audio.
template <class F> void engineWithAudio(F &&fn) {
    bool audioBusy = false;
    engine([&] {
        std::unique_lock<std::timed_mutex> held(audioMutex, std::defer_lock);
        audioBusy = pm::onMainThread() ? !held.try_lock_for(std::chrono::milliseconds(50)) : (held.lock(), false);
        if (!audioBusy) fn();
    });
    if (audioBusy)
        throw pm::Error("PsychMetal audio is in use on another thread, and the main thread cannot wait "
                        "for it. Call it from the experiment's thread.");
}
PyObject *py_start_movie_recording(PyObject *, PyObject *args) {
    PyObject *path, *codec, *scale, *sound, *clock=nullptr;
    if (!PyArg_ParseTuple(args, "OOOO|O", &path, &codec, &scale, &sound, &clock)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::string p = utf8(path, "The movie path"), c = utf8(codec, "codec");
        double s = scalar(scale, "scale");
        bool withSound = unsignedScalar(sound, "sound", 1) != 0;
        bool logical=clock && unsignedScalar(clock,"virtual clock",1)!=0;
        engineWithAudio([&] { pm::startMovieRecording(p, c, s, withSound, logical); });
        Py_RETURN_NONE;
    });
}
PyObject *py_stop_movie_recording(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::MovieRecording r;
        engineWithAudio([&] { r = pm::stopMovieRecording(); });
        return checked(Py_BuildValue("{s:s,s:s,s:d,s:d,s:d,s:d,s:d,s:d,s:d,s:d,s:O,s:d,s:d,s:O}", "path", r.path.c_str(),
            "codec", r.codec.c_str(), "width", r.width, "height", r.height, "frames", r.frames,
            "refreshes", r.refreshes, "refreshHz", r.refreshHz, "duration", r.duration, "late", r.late,
            "unreported", r.unreported, "sound", r.sound ? Py_True : Py_False, "soundSeconds", r.soundSeconds,
            "soundLostSeconds", r.soundLostSeconds, "virtualClock", r.virtualClock ? Py_True : Py_False));
    });
}
PyObject *py_close_movie(PyObject *, PyObject *args) {
    PyObject *h;
    if (!PyArg_ParseTuple(args, "O", &h)) return nullptr;
    return guarded([&]() -> PyObject * {
        uint64_t handle = unsignedScalar(h, "movie", pm::kMaxId);
        engine([&] { pm::closeMovie(handle); });
        Py_RETURN_NONE;
    });
}

PyObject *py_create_shader(PyObject *,PyObject *args) {
    PyObject *o;if(!PyArg_ParseTuple(args,"O",&o))return nullptr;
    return guarded([&]() -> PyObject * {
        if(!PyUnicode_Check(o))throw pm::Error("Shader source must be a string.");
        Py_ssize_t n;const char *p=PyUnicode_AsUTF8AndSize(o,&n);if(!p)throw PythonErrorSet{};
        std::string source(p,n);uint64_t handle=0;engine([&]{handle=pm::createShader(source);});
        return PyLong_FromUnsignedLongLong(handle);
    });
}
PyObject *py_close_shader(PyObject *,PyObject *args) {
    PyObject *o;if(!PyArg_ParseTuple(args,"O",&o))return nullptr;
    return guarded([&]() -> PyObject * {auto h=unsignedScalar(o,"shader",pm::kMaxId);engine([&]{pm::closeShader(h);});Py_RETURN_NONE;});
}
PyObject *py_draw_shader(PyObject *,PyObject *args) {
    PyObject *h,*p,*r,*m,*c=nullptr;if(!PyArg_ParseTuple(args,"OOOO|O",&h,&p,&r,&m,&c))return nullptr;
    return guarded([&]() -> PyObject * {Buffers hold;auto params=hold.view(p),dst=hold.view(r);
        pm::ArrayView coverage;if(c)coverage=hold.view(c);
        auto handle=unsignedScalar(h,"shader",pm::kMaxId),mask=unsignedScalar(m,"mask",pm::kMaxId);
        engine([&]{pm::drawShader(handle,params,dst,mask,c?&coverage:nullptr);});Py_RETURN_NONE;});
}
PyObject *py_text_bounds(PyObject *, PyObject *args) {
    PyObject *text, *font, *size;
    if (!PyArg_ParseTuple(args, "OOO", &text, &font, &size)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::string s = utf8(text, "Text"), f = utf8(font, "Font");
        double px = scalar(size, "text size");
        pm::TextBounds b{};
        engine([&] { b = pm::textBounds(s, f, px); });
        return Py_BuildValue("(ddd)", b.width, b.height, b.ascent);
    });
}

PyObject *py_layout_text(PyObject *, PyObject *args) {
    PyObject *text, *font, *size, *wrap;
    if (!PyArg_ParseTuple(args, "OOOO", &text, &font, &size, &wrap)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::string s = utf8(text, "Text"), f = utf8(font, "Font");
        double px = scalar(size, "text size"), w = PyFloat_AsDouble(wrap);
        if (w == -1 && PyErr_Occurred()) throw PythonErrorSet{};
        pm::TextLayout l{};
        engine([&] { l = pm::layoutText(s, f, px, w); });
        PyObject *lines = checked(PyList_New((Py_ssize_t)l.lines.size()));
        for (size_t i = 0; i < l.lines.size(); i++) {
            PyObject *line = PyUnicode_FromStringAndSize(l.lines[i].data(), (Py_ssize_t)l.lines[i].size());
            if (!line) { Py_DECREF(lines); throw PythonErrorSet{}; }
            PyList_SET_ITEM(lines, (Py_ssize_t)i, line);
        }
        PyObject *sizes = PyList_New((Py_ssize_t)l.sizes.size());
        if (!sizes) { Py_DECREF(lines); throw PythonErrorSet{}; }
        for (size_t i = 0; i < l.sizes.size(); i++)
            PyList_SET_ITEM(sizes, (Py_ssize_t)i, Py_BuildValue("(dd)", l.sizes[i][0], l.sizes[i][1]));
        return Py_BuildValue("(NNd)", lines, sizes, l.ascent);
    });
}

PyObject *py_draw_text(PyObject *, PyObject *args) {
    PyObject *text, *font, *size, *ox, *oy, *color;
    if (!PyArg_ParseTuple(args, "OOOOOO", &text, &font, &size, &ox, &oy, &color)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::string s = utf8(text, "Text"), f = utf8(font, "Font");
        double px = scalar(size, "text size"), x = scalar(ox, "text x"), y = scalar(oy, "text y");
        const char *m = "Text colour must be four real numbers, RGBA.";
        pm::Rect4 rgba = numbers<4>(color, m, m);
        pm::TextBounds b{};
        engine([&] { b = pm::drawText(s, f, px, x, y, rgba); });
        return Py_BuildValue("(ddd)", b.width, b.height, b.ascent);
    });
}

PyObject *py_link_info(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::LinkInfo k{};
        engine([&] { k = pm::linkInfo(); });
        return Py_BuildValue("(ddddd)", k.lanes, k.laneGbps, k.payloadGbps, k.pixelGbps, k.compressed);
    });
}

PyObject *py_noise_values(PyObject *, PyObject *args) {
    PyObject *w, *h, *seed, *normal, *colour, *mean, *spread;
    if (!PyArg_ParseTuple(args, "OOOOOOO", &w, &h, &seed, &normal, &colour, &mean, &spread)) return nullptr;
    return guarded([&]() -> PyObject * {
        pm::NoiseRequest q;
        q.width = scalar(w, "width");
        q.height = scalar(h, "height");
        q.seed = scalar(seed, "seed");
        q.normal = scalar(normal, "normal flag") != 0.0;
        q.colour = scalar(colour, "colour flag") != 0.0;
        const char *m = "Noise mean must be a 3-element RGB vector.";
        q.mean = numbers<3>(mean, m, m);
        q.spread = scalar(spread, "spread");
        pm::checkNoiseRequest(q);
        size_t H = (size_t)q.height, W = (size_t)q.width, C = q.colour ? 3 : 1;
        PyObject *buf = checked(PyByteArray_FromStringAndSize(nullptr, (Py_ssize_t)(H * W * C * sizeof(double))));
        pm::MutableArrayView out;
        out.data = (double *)PyByteArray_AS_STRING(buf);
        out.ndim = q.colour ? 3 : 2;
        out.shape = {H, W, 3};
        out.strides = {(ptrdiff_t)(W * C * 8), (ptrdiff_t)(C * 8), 8};   // C order
        try {
            engine([&] { pm::noiseValues(q, out); });
        } catch (...) {
            Py_DECREF(buf);
            throw;
        }
        return q.colour ? array(buf, "d", {H, W, 3}) : array(buf, "d", {H, W});
    });
}

PyObject *py_create_image_pipeline(PyObject *,PyObject *args) {
    PyObject *o;if(!PyArg_ParseTuple(args,"O",&o))return nullptr;
    return guarded([&]()->PyObject* {Buffers hold;auto v=hold.view(o);uint64_t id=0;engine([&]{id=pm::createImagePipeline(v);});return PyLong_FromUnsignedLongLong(id);});
}
PyObject *py_process_image(PyObject *,PyObject *args) {
    PyObject *p,*s,*d;if(!PyArg_ParseTuple(args,"OOO",&p,&s,&d))return nullptr;
    return guarded([&]()->PyObject* {auto pipeline=unsignedScalar(p,"pipeline",pm::kMaxId),source=unsignedScalar(s,"source",pm::kMaxId),destination=unsignedScalar(d,"destination",pm::kMaxId);
        uint64_t id=0;engine([&]{id=pm::processImage(pipeline,source,destination);});return PyLong_FromUnsignedLongLong(id);});
}
PyObject *py_close_image_pipeline(PyObject *,PyObject *args) {
    PyObject *p;if(!PyArg_ParseTuple(args,"O",&p))return nullptr;
    return guarded([&]()->PyObject* {auto id=unsignedScalar(p,"pipeline",pm::kMaxId);engine([&]{pm::closeImagePipeline(id);});Py_RETURN_NONE;});
}
PyObject *py_hdr_info(PyObject *,PyObject *) {
    return guarded([&]()->PyObject* {pm::HDRInfo s;engine([&]{s=pm::hdrInfo();});
        return checked(Py_BuildValue("{s:O,s:d,s:d,s:d,s:s}","enabled",s.enabled?Py_True:Py_False,"currentHeadroom",s.currentHeadroom,
            "potentialHeadroom",s.potentialHeadroom,"exposure",s.exposure,"units","linear Display-P3; 1 = SDR reference white"));});
}
PyObject *py_set_hdr_exposure(PyObject *,PyObject *args) {
    PyObject *v;if(!PyArg_ParseTuple(args,"O",&v))return nullptr;
    return guarded([&]()->PyObject* {double stops=scalar(v,"exposure");engine([&]{pm::setHDRExposure(stops);});Py_RETURN_NONE;});
}
PyObject *py_get_image(PyObject *, PyObject *args) {
    PyObject *r = Py_None, *destination = Py_None;
    if (!PyArg_ParseTuple(args, "|OO", &r, &destination)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::optional<pm::Rect4> rect;
        if (r != Py_None) {
            const char *m = "GetImage rect must be [left top right bottom] in whole pixels inside the window.";
            rect = numbers<4>(r, m, m);
        }
        pm::ImageRegion g{};
        engine([&] { g = pm::checkImageRect(rect); });
        size_t H = g.height, W = g.width;
        if (destination != Py_None) {
            struct HeldBuffer { Py_buffer v{}; bool held=false;
                ~HeldBuffer() { if(held) PyBuffer_Release(&v); } } b;
            if(PyObject_GetBuffer(destination, &b.v, PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | PyBUF_WRITABLE)<0)
                throw PythonErrorSet{};
            b.held=true;
            const char *f=b.v.format ? b.v.format : "";
            if(*f=='@'||*f=='='||*f=='<') ++f; // supported targets are little-endian
            const bool deep=g.bits==10,hdr=g.bits==16;
            if(b.v.ndim!=3 || b.v.shape[0]!=(Py_ssize_t)H || b.v.shape[1]!=(Py_ssize_t)W || b.v.shape[2]!=3 ||
               b.v.itemsize!=(hdr?4:deep?2:1) || f[0]!=(hdr?'f':deep?'H':'B') || f[1]!=0)
                throw pm::Error("out must be writable C-contiguous RGB with the requested shape and native uint8/uint16/float32 dtype.");
            if(hdr) {
                pm::MutableFloatView v;v.data=(float*)b.v.buf;v.ndim=3;v.shape={H,W,3};v.strides={(ptrdiff_t)(W*12),12,4};
                engine([&]{pm::getImageFloat(g,v);});
            } else if(deep) {
                pm::MutableWordView v;v.data=(uint16_t*)b.v.buf;v.ndim=3;v.shape={H,W,3};
                v.strides={(ptrdiff_t)(W*6),6,2}; engine([&]{pm::getImage16(g,v);});
            } else {
                pm::MutableByteView v;v.data=(uint8_t*)b.v.buf;v.ndim=3;v.shape={H,W,3};
                v.strides={(ptrdiff_t)(W*3),3,1}; engine([&]{pm::getImage(g,v);});
            }
            Py_INCREF(destination);
            return destination;
        }
        if(g.bits==16) {
            PyObject *buffer=checked(PyByteArray_FromStringAndSize(nullptr,(Py_ssize_t)(H*W*12)));
            pm::MutableFloatView out;out.data=(float*)PyByteArray_AS_STRING(buffer);out.ndim=3;out.shape={H,W,3};out.strides={(ptrdiff_t)(W*12),12,4};
            try{engine([&]{pm::getImageFloat(g,out);});}catch(...){Py_DECREF(buffer);throw;}
            return array(buffer,"f",{H,W,3});
        }
        if (g.bits == 10) {      // uint16, 0..1023
            PyObject *words = checked(PyByteArray_FromStringAndSize(nullptr, (Py_ssize_t)(H * W * 3 * 2)));
            pm::MutableWordView out16;
            out16.data = (uint16_t *)PyByteArray_AS_STRING(words);
            out16.ndim = 3;
            out16.shape = {H, W, 3};
            out16.strides = {(ptrdiff_t)(W * 6), 6, 2};   // C order
            try {
                engine([&] { pm::getImage16(g, out16); });
            } catch (...) {
                Py_DECREF(words);
                throw;
            }
            return array(words, "H", {H, W, 3});
        }
        PyObject *buf = checked(PyByteArray_FromStringAndSize(nullptr, (Py_ssize_t)(H * W * 3)));
        pm::MutableByteView out;
        out.data = (uint8_t *)PyByteArray_AS_STRING(buf);
        out.ndim = 3;
        out.shape = {H, W, 3};
        out.strides = {(ptrdiff_t)(W * 3), 3, 1};   // C order
        try {
            engine([&] { pm::getImage(g, out); });
        } catch (...) {
            Py_DECREF(buf);
            throw;
        }
        return array(buf, "B", {H, W, 3});
    });
}

PyObject *py_modes(PyObject *, PyObject *args) {
    PyObject *s;
    if (!PyArg_ParseTuple(args, "O", &s)) return nullptr;
    return guarded([&]() -> PyObject * {
        double si = scalar(s, "screen index");
        std::vector<pm::DisplayMode> m;
        engine([&] { m = pm::modes(si); });
        std::vector<double> v;
        for (auto &x : m) v.insert(v.end(), {x.pointWidth, x.pointHeight, x.pixelWidth, x.pixelHeight, x.refreshHz});
        return doubles(v, m.size(), 5);
    });
}

PyObject *py_set_mode(PyObject *, PyObject *args) {
    PyObject *s, *w, *h, *rate = nullptr;
    if (!PyArg_ParseTuple(args, "OOO|O", &s, &w, &h, &rate)) return nullptr;
    return guarded([&]() -> PyObject * {
        double si = scalar(s, "screen index"), pw = scalar(w, "width"), ph = scalar(h, "height");
        double hz = rate ? scalar(rate, "refresh rate") : 0;
        engine([&] { pm::setMode(si, pw, ph, hz); });
        Py_RETURN_NONE;
    });
}

PyObject *py_set_cursor_visible(PyObject *, PyObject *args) {
    PyObject *show;
    if (!PyArg_ParseTuple(args, "O", &show)) return nullptr;
    return guarded([&]() -> PyObject * {
        bool b = scalar(show, "show cursor") != 0.0;
        engine([&] { pm::setCursorVisible(b); });
        Py_RETURN_NONE;
    });
}

PyObject *py_queue_flip(PyObject *, PyObject *args) {
    PyObject *when;
    if (!PyArg_ParseTuple(args, "O", &when)) return nullptr;
    return guarded([&]() -> PyObject * {
        double target = scalar(when, "presentation time");
        pm::QueueResult r{};
        engine([&] { r = pm::queueFlip(target); });
        return Py_BuildValue("(Kdd)", (unsigned long long)r.token, r.pending, r.capacity);
    });
}

PyObject *py_queue_results(PyObject *, PyObject *args) {
    PyObject *wait;
    if (!PyArg_ParseTuple(args, "O", &wait)) return nullptr;
    return guarded([&]() -> PyObject * {
        bool w = truth(wait, "wait");
        std::vector<pm::QueuedFrame> frames;
        engine([&] { frames = pm::queueResults(w); });
        std::vector<double> v;
        v.reserve(frames.size() * 4);
        for (auto &f : frames) v.insert(v.end(), {f.requested, f.presented, (double)f.status, (double)f.token});
        return doubles(v, frames.size(), 4);
    });
}

PyObject *py_queue_cancel(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        uint64_t n = 0;
        engine([&] { n = pm::queueCancel(); });
        return PyLong_FromUnsignedLongLong(n);
    });
}

PyObject *py_touch_events(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::TouchEvents e{};
        engine<Hold::Reading>([&] { e = pm::touchEvents(); });
        std::vector<double> v;
        v.reserve(e.events.size() * 5);
        for (auto &x : e.events) v.insert(v.end(), {x.time, (double)x.finger, (double)x.phase, x.x, x.y});
        PyObject *events = doubles(v, e.events.size(), 5);
        return Py_BuildValue("(NK)", events, (unsigned long long)e.dropped);
    });
}

PyObject *py_mouse_events(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::MouseEvents e{};
        engine<Hold::Reading>([&] { e = pm::mouseEvents(); });
        std::vector<double> v;
        v.reserve(e.events.size() * 5);
        for (auto &x : e.events) v.insert(v.end(), {x.time, (double)x.button, x.pressed ? 1.0 : 0.0, x.x, x.y});
        PyObject *events = doubles(v, e.events.size(), 5);
        return Py_BuildValue("(NK)", events, (unsigned long long)e.dropped);
    });
}

PyObject *py_mouse(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::MouseState m{};
        engine<Hold::Reading>([&] { m = pm::mouse(); });
        return Py_BuildValue("(dd(OOO))", m.x, m.y, m.buttons[0] ? Py_True : Py_False,
                             m.buttons[1] ? Py_True : Py_False, m.buttons[2] ? Py_True : Py_False);
    });
}

PyObject *py_set_mouse(PyObject *, PyObject *args) {
    PyObject *ox, *oy;
    if (!PyArg_ParseTuple(args, "OO", &ox, &oy)) return nullptr;
    return guarded([&]() -> PyObject * {
        double x = scalar(ox, "mouse x"), y = scalar(oy, "mouse y");
        engine([&] { pm::setMouse(x, y); });
        Py_RETURN_NONE;
    });
}

PyObject *py_keys(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::KeyState k{};
        engine<Hold::Reading>([&] { k = pm::keys(); });
        char raw[256];
        for (size_t i = 0; i < 256; i++) raw[i] = k.down[i] ? 1 : 0;
        PyObject *b = checked(PyByteArray_FromStringAndSize(raw, 256));
        PyObject *codes = array(b, "?", {256});
        return Py_BuildValue("(OdNd)", k.anyDown ? Py_True : Py_False, k.secs, codes, k.securePid);
    });
}

PyObject *py_kb_queue_status(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::KbQueueStatus s{};
        engine<Hold::Reading>([&] { s = pm::kbQueueStatus(); });
        PyObject *d = checked(PyDict_New());
        if (setItem(d, "created", PyBool_FromLong(s.created)) < 0 ||
            setItem(d, "running", PyBool_FromLong(s.running)) < 0 ||
            setItem(d, "pollInterval", PyFloat_FromDouble(s.pollInterval)) < 0 ||
            setItem(d, "lastScanInterval", PyFloat_FromDouble(s.lastScanInterval)) < 0 ||
            setItem(d, "maxScanInterval", PyFloat_FromDouble(s.maxScanInterval)) < 0 ||
            setItem(d, "scans", PyLong_FromUnsignedLongLong(s.scans)) < 0 ||
            setItem(d, "dropped", PyLong_FromUnsignedLongLong(s.dropped)) < 0 ||
            setItem(d, "secureInputPID", PyFloat_FromDouble(s.secureInputPID)) < 0 ||
            setItem(d, "eventTimestamps", PyBool_FromLong(s.eventTimestamps)) < 0 ||
            setItem(d, "eventStamped", PyLong_FromUnsignedLongLong(s.eventStamped)) < 0 ||
            setItem(d, "pollStamped", PyLong_FromUnsignedLongLong(s.pollStamped)) < 0 ||
            setItem(d, "maxEventDelayMs", PyFloat_FromDouble(s.maxEventDelayMs)) < 0) {
            Py_DECREF(d);
            throw PythonErrorSet{};
        }
        return d;
    });
}

PyObject *py_kb_queue_create(PyObject *, PyObject *args) {
    PyObject *mask, *interval;
    if (!PyArg_ParseTuple(args, "OO", &mask, &interval)) return nullptr;
    return guarded([&]() -> PyObject * {
        const char *m = "KbQueueCreate requires a 256-element mask and poll interval, no outputs.";
        std::array<double, 256> k = numbers<256>(mask, m, m);
        double iv = scalar(interval, "poll interval");
        engine([&] { pm::kbQueueCreate(k, iv); });
        Py_RETURN_NONE;
    });
}

PyObject *py_kb_queue_release(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * { engine([] { pm::kbQueueRelease(); }); Py_RETURN_NONE; });
}
PyObject *py_kb_queue_start(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * { engine([] { pm::kbQueueStart(); }); Py_RETURN_NONE; });
}
PyObject *py_kb_queue_stop(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * { engine([] { pm::kbQueueStop(); }); Py_RETURN_NONE; });
}
PyObject *py_kb_queue_flush(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * { engine([] { pm::kbQueueFlush(); }); Py_RETURN_NONE; });
}

PyObject *py_kb_queue_get_events(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::KbEvents e{};
        engine<Hold::Reading>([&] { e = pm::kbQueueGetEvents(); });
        std::vector<double> v;
        v.reserve(e.events.size() * 3);
        for (auto &x : e.events) v.insert(v.end(), {x.time, (double)x.key, x.pressed ? 1.0 : 0.0});
        PyObject *events = doubles(v, e.events.size(), 3);
        return Py_BuildValue("(NK)", events, (unsigned long long)e.dropped);
    });
}

PyObject *py_kb_queue_check(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::KbCheck c{};
        engine<Hold::Reading>([&] { c = pm::kbQueueCheck(); });
        std::vector<double> v;
        v.reserve(4 * 256);
        for (auto *a : {&c.firstPress, &c.firstRelease, &c.lastPress, &c.lastRelease}) v.insert(v.end(), a->begin(), a->end());
        PyObject *times = doubles(v, 4, 256);
        return Py_BuildValue("(ON)", c.pressed ? Py_True : Py_False, times);
    });
}

PyObject *py_now(PyObject *, PyObject *) { return PyFloat_FromDouble(pm::now()); }

PyObject *py_wait_until(PyObject *, PyObject *args) {
    PyObject *d;
    if (!PyArg_ParseTuple(args, "O", &d)) return nullptr;
    return guarded([&]() -> PyObject * {
        double deadline = scalar(d, "deadline"), t = 0;
        std::exception_ptr error;
        Py_BEGIN_ALLOW_THREADS          // the clock alone: no lock
        try { t = pm::waitUntil(deadline); } catch (...) { error = std::current_exception(); }
        Py_END_ALLOW_THREADS
        if (error) std::rethrow_exception(error);
        return PyFloat_FromDouble(t);
    });
}

PyObject *py_recent_frames(PyObject *, PyObject *args) {
    return guarded([&]() -> PyObject * {
        int count;
        if (!PyArg_ParseTuple(args, "i", &count)) throw PythonErrorSet{};
        std::vector<pm::FrameRecord> records;
        engine([&] { records = pm::recentFrames(static_cast<size_t>(count)); });
        std::vector<double> values;
        values.reserve(records.size() * 4);
        for (const auto &r : records)
            values.insert(values.end(), {(double)r.token, (double)r.status, r.presented, r.committedAt});
        return doubles(values, records.size(), 4);
    });
}

PyObject *py_diagnostic(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::DiagnosticReport r{};
        engine([&] { r = pm::diagnostic(); });
        std::vector<double> v;
        v.reserve(r.history.size() * 14);
        for (auto &x : r.history)
            v.insert(v.end(), {(double)x.token, x.projected, x.presented, (double)x.status, x.scheduledAt,
                               x.callback, (double)x.commandStatus, x.requestedTime, x.gpuStart, x.gpuEnd,
                               x.presentRequest, x.committedAt, x.drawableAcquireMs, x.encodeMs});
        PyObject *history = doubles(v, r.history.size(), 14);
        const pm::DiagnosticSummary &d = r.summary;
        PyObject *s = PyDict_New();
        if (!s) { Py_DECREF(history); throw PythonErrorSet{}; }
        bool ok = true;
        auto num = [&](const char *k, double x) { ok = ok && setItem(s, k, PyFloat_FromDouble(x)) == 0; };
        auto flag = [&](const char *k, bool x) { ok = ok && setItem(s, k, PyBool_FromLong(x)) == 0; };
        auto r4 = [&](const char *k, const pm::Rect4 &x) { ok = ok && setItem(s, k, rect4(x)) == 0; };
        // Same fields, same order, as the MATLAB Diagnostic struct.
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
        flag("readbackEnabled", d.readbackEnabled);
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
        flag("displayCaptured",d.displayCaptured);
        if (!ok) { Py_DECREF(history); Py_DECREF(s); throw PythonErrorSet{}; }
        return Py_BuildValue("(NN)", history, s);
    });
}

#define PM_METHOD(name, flags, doc) {#name, (PyCFunction)py_##name, flags, doc}
PyMethodDef methods[] = {
    PM_METHOD(default_presentation, METH_NOARGS, "Native platform default: true for display link, false for direct."),
    PM_METHOD(play_timeline, METH_VARARGS, "Native captured-scene playback: frames, N x 6 tracks."),
    PM_METHOD(update_timeline,METH_VARARGS,"Update active native timeline controls without waiting for playback."),
    PM_METHOD(cancel_timeline, METH_VARARGS, "cancel_timeline([cancel=True]): end native playback now or at its start; False clears the request. Safe from another thread."),
    PM_METHOD(environment, METH_NOARGS, "Engine, OS and GPU report; no window required."),
    PM_METHOD(audio_devices, METH_NOARGS, "Audio devices: list of dicts."),
    PM_METHOD(open_audio, METH_VARARGS, "open_audio(device, rate, channels, buffer_frames, any_route, input, input_device, input_channels, record_seconds) -> info."),
    PM_METHOD(close_audio, METH_NOARGS, "Close audio."),
    PM_METHOD(audio_status, METH_NOARGS, "Audio status dict."),
    PM_METHOD(make_audio_stream, METH_VARARGS, "make_audio_stream(capacityFrames,channels)."),
    PM_METHOD(refill_sound, METH_VARARGS, "refill_sound(sound,samples,final)."),
    PM_METHOD(audio_stream_status, METH_VARARGS, "audio_stream_status(sound)."),
    PM_METHOD(make_sound, METH_VARARGS, "make_sound(samples, rate) -> handle."),
    PM_METHOD(close_sound, METH_VARARGS, "close_sound(handle)."),
    PM_METHOD(play, METH_VARARGS, "play(sound, when, frame, offset, gain, repeats) -> voice."),
    PM_METHOD(stop_sound, METH_VARARGS, "stop_sound(voice or None, when)."),
    PM_METHOD(modulate, METH_VARARGS, "modulate(voice, hz, phase, depth, when)."),
    PM_METHOD(start_recording, METH_VARARGS, "start_recording(when) -> id."),
    PM_METHOD(stop_recording, METH_VARARGS, "stop_recording(when)."),
    PM_METHOD(get_recording, METH_NOARGS, "get_recording() -> (samples frames x channels, rate, first sample time, recording)."),
    PM_METHOD(voice_key, METH_VARARGS, "voice_key(threshold, when, window, minimum) -> id."),
    PM_METHOD(input_recent, METH_VARARGS, "input_recent(seconds) -> (samples, rate, end time)."),
    PM_METHOD(audio_results, METH_NOARGS, "Audio events not yet reported: list of dicts."),
    PM_METHOD(version, METH_NOARGS, "Engine version string."),
    PM_METHOD(set_array_factory, METH_O, "Install factory(buffer, typecode, shape) used to build result arrays."),
    PM_METHOD(on_main_thread, METH_NOARGS, "True on the process main thread."),
    PM_METHOD(service_main_run_loop, METH_VARARGS, "service_main_run_loop(seconds=0.05): service AppKit on the main thread."),
    PM_METHOD(shutdown, METH_NOARGS, "Release every native resource. Registered with atexit."),
    PM_METHOD(prepare_app, METH_NOARGS, "Engine PrepareApp."),
    PM_METHOD(make_stimulus, METH_VARARGS, "make_stimulus(kind, options) -> 15 parameters."),
    PM_METHOD(stimulus_with, METH_VARARGS, "stimulus_with(parameters, options) -> 15 parameters."),
    PM_METHOD(make_mask, METH_VARARGS, "make_mask(kind, options) -> 8 parameters."),
    PM_METHOD(layout_text, METH_VARARGS, "layout_text(text, font, size, wrap) -> (lines, sizes, ascent)."),
    PM_METHOD(key_names, METH_NOARGS, "key_names() -> [(HID usage, name)]."),
    PM_METHOD(tone, METH_VARARGS, "tone(frequency, seconds, rate[, amplitude, ramp]) -> samples."),
    PM_METHOD(click, METH_VARARGS, "click(rate[, seconds, amplitude]) -> samples."),
    PM_METHOD(white_noise, METH_VARARGS, "white_noise(seconds, rate[, amplitude, seed, ramp]) -> samples."),
    PM_METHOD(open_export, METH_VARARGS, "open_export(width,height,refresh_hz,readback)."),
    PM_METHOD(open_session, METH_VARARGS, "open_session(screen, drawables[, refresh_hz[, readback[, bit_depth[, display_link]]]])."),
    PM_METHOD(startup_history, METH_NOARGS, "Startup history, n x 6."),
    PM_METHOD(confirm_startup, METH_NOARGS, "Confirm two background presentations; returns startup history."),
    PM_METHOD(close_session, METH_NOARGS, "Close the window and release it."),
    PM_METHOD(flip, METH_VARARGS, "flip([when]) -> (time, confirmed, slip, period, queue_ms, call_ms, return_time, token)."),
    PM_METHOD(flip_status, METH_NOARGS, "flip_status() -> (confirmed, dropped, dropped_frames) as the display has reported so far."),
    PM_METHOD(queue_flip, METH_VARARGS, "queue_flip(when) -> (token, pending, capacity)."),
    PM_METHOD(queue_results, METH_VARARGS, "queue_results(wait) -> (n, 4) float64: requested, presented, status, token."),
    PM_METHOD(queue_cancel, METH_NOARGS, "queue_cancel() -> frames abandoned."),
    PM_METHOD(grid_anchor, METH_NOARGS, "grid_anchor() -> (anchor, period, samples)."),
    PM_METHOD(next_phase, METH_VARARGS, "next_phase(after, phase)."),
    PM_METHOD(next_refresh, METH_VARARGS, "next_refresh(after)."),
    PM_METHOD(wait_to_draw, METH_VARARGS, "wait_to_draw(target, budget) -> (woke_at, lead, deadline)."),
    PM_METHOD(set_background_color, METH_VARARGS, "set_background_color(r, g, b, a), components 0..1."),
    PM_METHOD(check_stimulus, METH_VARARGS, "Validate procedural stimulus parameters."),
    PM_METHOD(check_mask, METH_VARARGS, "Validate analytic mask recipe parameters."),
    PM_METHOD(draw_masked_texture, METH_VARARGS, "Draw a masked still image."),
    PM_METHOD(create_shader,METH_VARARGS,"Compile a fixed-ABI custom Metal fragment program."),
    PM_METHOD(close_shader,METH_VARARGS,"Release a custom shader handle; queued draws retain it."),
    PM_METHOD(draw_shader,METH_VARARGS,"Queue a custom shader with fixed parameters and coverage."),
    PM_METHOD(draw_stimulus, METH_VARARGS, "Draw procedural stimulus parameters, destination and mask."),
    PM_METHOD(add_shapes, METH_VARARGS, "add_shapes(kind (N,), param (N,), rect (N,4), color (N,4), extra (N,4)), float64."),
    PM_METHOD(make_texture, METH_VARARGS, "make_texture(image (H,W[,C])) -> handle."),
    PM_METHOD(update_texture, METH_VARARGS, "update_texture(handle, image[, left, top])."),
    PM_METHOD(draw_textures, METH_VARARGS,
              "draw_textures(handle (N,), src (N,4), dst (N,4), angle_rad (N,), tint (N,4), filter (N,)), float64."),
    PM_METHOD(close_texture, METH_VARARGS, "close_texture(handle)."),
    PM_METHOD(open_movie, METH_VARARGS, "open_movie(path) -> (handle, info)."),
    PM_METHOD(transcode_movie, METH_VARARGS, "transcode_movie(source, destination, codec) -> frames."),
    PM_METHOD(prepare_movie, METH_VARARGS, "prepare_movie(handle, frames, max_bytes) -> resident frames."),
    PM_METHOD(movie_frame_times, METH_VARARGS, "movie_frame_times(handle) -> frame times, seconds."),
    PM_METHOD(draw_movie_frame, METH_VARARGS, "draw_movie_frame(movie, index, src, dst, angle, tint, filter)."),
    PM_METHOD(movie_sound, METH_VARARGS, "movie_sound(movie, rate, speed, keep_pitch) -> float32 (frames, channels)."),
    PM_METHOD(play_movie, METH_VARARGS, "play_movie(movie, first, count, refreshes, src, dst, when, sound, gain)."),
    PM_METHOD(close_movie, METH_VARARGS, "close_movie(handle)."),
    PM_METHOD(start_movie_recording, METH_VARARGS, "start_movie_recording(path, codec, scale, sound)."),
    PM_METHOD(stop_movie_recording, METH_NOARGS, "stop_movie_recording() -> report."),
    PM_METHOD(set_blend_mode, METH_VARARGS, "set_blend_mode(mode): 0 source-over, 1 additive, 2 copy."),
    PM_METHOD(set_clip, METH_VARARGS, "set_clip([rect]): confine draws to [left, top, right, bottom]; no rect ends it."),
    PM_METHOD(open_offscreen, METH_VARARGS, "open_offscreen(width, height, rgba) -> texture handle."),
    PM_METHOD(set_target, METH_VARARGS, "set_target(handle): draw into that offscreen window; 0 is the window."),
    PM_METHOD(draw_polygon, METH_VARARGS, "draw_polygon(points (N,2) float64, rgba, pen): pen 0 fills."),
    PM_METHOD(set_gamma, METH_VARARGS, "set_gamma(r, g, b): display value = linear value ** exponent; 1, 1, 1 is off."),
    PM_METHOD(set_gamma_table, METH_VARARGS, "set_gamma_table(table (N,3) float64): display values for N linear values."),
    PM_METHOD(text_bounds, METH_VARARGS, "text_bounds(text, font, size) -> (width, height, ascent) in pixels."),
    PM_METHOD(draw_text, METH_VARARGS, "draw_text(text, font, size, x, y, rgba) -> (width, height, ascent)."),
    PM_METHOD(link_info, METH_NOARGS, "link_info() -> (lanes, lane_gbps, payload_gbps, pixel_gbps, compressed)."),
    PM_METHOD(create_image_pipeline, METH_VARARGS, "Prepare image-processing operations."),
    PM_METHOD(process_image, METH_VARARGS, "Process a texture on the GPU."),
    PM_METHOD(close_image_pipeline, METH_VARARGS, "Close a prepared pipeline."),
    PM_METHOD(hdr_info, METH_NOARGS, "HDR headroom and relative-linear output configuration."),
    PM_METHOD(set_hdr_exposure, METH_VARARGS, "Set HDR exposure in stops."),
    PM_METHOD(get_image, METH_VARARGS, "get_image([rect, out]) -> (H, W, 3) RGB of the last frame, uint8 or (10-bit) uint16; needs readback."),
    PM_METHOD(noise_values, METH_VARARGS, "noise_values(w, h, seed, normal, colour, mean3, spread) -> array 0..1."),
    PM_METHOD(modes, METH_VARARGS, "modes(screen) -> n x 5 (point w, point h, pixel w, pixel h, Hz)."),
    PM_METHOD(set_mode, METH_VARARGS, "set_mode(screen, point_w, point_h[, refresh_hz])."),
    PM_METHOD(set_cursor_visible, METH_VARARGS, "set_cursor_visible(flag)."),
    PM_METHOD(mouse, METH_NOARGS, "mouse() -> (x, y, (left, right, centre))."),
    PM_METHOD(mouse_events, METH_NOARGS, "mouse_events() -> ((n, 5) float64: time, button, pressed, x, y; dropped)."),
    PM_METHOD(touch_events, METH_NOARGS, "touch_events() -> ((n, 5) float64: time, finger, phase, x, y; dropped)."),
    PM_METHOD(set_mouse, METH_VARARGS, "set_mouse(x, y): move the cursor, in window pixels."),
    PM_METHOD(keys, METH_NOARGS, "keys() -> (any_down, secs, key_code bool[256], secure_pid)."),
    PM_METHOD(kb_queue_status, METH_NOARGS, "Keyboard queue status dict."),
    PM_METHOD(kb_queue_create, METH_VARARGS, "kb_queue_create(mask256, interval)."),
    PM_METHOD(kb_queue_release, METH_NOARGS, "Release the keyboard queue."),
    PM_METHOD(kb_queue_start, METH_NOARGS, "Start the keyboard queue."),
    PM_METHOD(kb_queue_stop, METH_NOARGS, "Stop the keyboard queue."),
    PM_METHOD(kb_queue_flush, METH_NOARGS, "Flush the keyboard queue."),
    PM_METHOD(kb_queue_get_events, METH_NOARGS, "kb_queue_get_events() -> (events n x 3, dropped)."),
    PM_METHOD(kb_queue_check, METH_NOARGS, "kb_queue_check() -> (pressed, times 4 x 256)."),
    PM_METHOD(now, METH_NOARGS, "Current time on the engine clock (seconds)."),
    PM_METHOD(wait_until, METH_VARARGS, "wait_until(deadline) -> time on return."),
    PM_METHOD(recent_frames, METH_VARARGS, "recent_frames(count) -> rows [token,status,presented,committed]. No GPU wait."),
    PM_METHOD(diagnostic, METH_NOARGS, "diagnostic() -> (history n x 16, summary dict)."),
    {nullptr, nullptr, 0, nullptr},
};

PyModuleDef module = {PyModuleDef_HEAD_INIT, "_psychmetal",
                      "PsychMetal engine binding. Use the psychmetal package, not this module.",
                      -1, methods, nullptr, nullptr, nullptr, nullptr};

}  // namespace

PyMODINIT_FUNC PyInit__psychmetal(void) {
    PyObject *m = PyModule_Create(&module);
    if (!m) return nullptr;
    ErrorType = PyErr_NewException("psychmetal.PsychMetalError", PyExc_RuntimeError, nullptr);
    if (!ErrorType) { Py_DECREF(m); return nullptr; }
    Py_INCREF(ErrorType);
    if (PyModule_AddObject(m, "PsychMetalError", ErrorType) < 0) {
        Py_DECREF(ErrorType);
        Py_DECREF(m);
        return nullptr;
    }
    pm::HostHooks hooks;
    hooks.warn = warnHook;
    pm::installHostHooks(hooks);
    return m;
}
