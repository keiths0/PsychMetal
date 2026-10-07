// PsychMetalPython.cpp — the Python front end: module psychmetal._psychmetal,
// a thin binding of PsychMetalEngine.h using the plain CPython C API.
// SPDX-License-Identifier: MIT
//
// Build dependencies: a C++17 compiler and Python's headers. numpy is used at
// run time only: arrays arrive through the buffer protocol with their own
// strides (never copied), and arrays leave through a factory the psychmetal
// package installs (numpy.frombuffer), so this file needs no numpy headers.
//
// Every engine call releases the GIL and holds a module-wide mutex, so the
// engine sees one caller at a time and other Python threads keep running
// while Flip or Wait block. Releasing the GIL is also what lets the main
// thread service AppKit (serviceMainRunLoop) while a worker thread is inside
// an engine call that dispatch_syncs to it. Engine warnings are queued during
// the call and issued as Python warnings once the GIL is held again.
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include "PsychMetalEngine.h"

#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

PyObject *ErrorType = nullptr;       // psychmetal.PsychMetalError (RuntimeError), with .id
PyObject *arrayFactory = nullptr;    // factory(buffer, typecode, shape) -> array
std::mutex engineMutex;
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

// Run fn without the GIL, holding the engine mutex. Exceptions from the engine
// are carried back across the GIL boundary and rethrown with it held.
template <class F> void engine(F &&fn) {
    std::exception_ptr error;
    Py_BEGIN_ALLOW_THREADS
    {
        std::lock_guard<std::mutex> guard(engineMutex);
        try { fn(); } catch (...) { error = std::current_exception(); }
    }
    Py_END_ALLOW_THREADS
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

PyObject *py_version(PyObject *, PyObject *) { return PyUnicode_FromString(pm::version()); }

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
        std::lock_guard<std::mutex> guard(engineMutex);
        pm::shutdown();
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
    PyObject *screen, *count, *confirm, *sync, *capture, *refresh = Py_None, *readback = nullptr, *bits = nullptr;
    if (!PyArg_ParseTuple(args, "OOOOO|OOO", &screen, &count, &confirm, &sync, &capture, &refresh, &readback, &bits))
        return nullptr;
    return guarded([&]() -> PyObject * {
        pm::OpenOptions o;
        o.screenIndex = scalar(screen, "screen index");
        o.drawableCount = unsignedScalar(count, "maximum drawable count", 3);
        o.captureDisplay = truth(capture, "capture display");
        o.displaySync = truth(sync, "display sync");
        o.waitForConfirm = truth(confirm, "wait for confirmation");
        o.refreshHz = optionalScalar(refresh, "refreshHz");
        if (readback && readback != Py_None) o.readback = truth(readback, "readback");
        if (bits && bits != Py_None) o.bitDepth = unsignedScalar(bits, "bit depth", 10);
        pm::OpenResult r{};
        engine([&] { r = pm::openSession(o); });
        return Py_BuildValue("(dddddK)", r.pixelWidth, r.pixelHeight, r.ifi, r.pointWidth, r.pointHeight,
                             (unsigned long long)r.sessionToken);
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

PyObject *py_prepare_flip(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        uint64_t t = 0;
        engine([&] { t = pm::prepareFlip(); });
        return PyLong_FromUnsignedLongLong(t);
    });
}

PyObject *py_present_now(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::PresentResult r{};
        engine([&] { r = pm::presentNow(); });
        return Py_BuildValue("(dd)", r.time, r.callMs);
    });
}

PyObject *py_set_display_sync(PyObject *, PyObject *args) {
    PyObject *on;
    if (!PyArg_ParseTuple(args, "O", &on)) return nullptr;
    return guarded([&]() -> PyObject * {
        bool b = truth(on, "display sync");
        engine([&] { pm::setDisplaySync(b); });
        Py_RETURN_NONE;
    });
}

PyObject *py_set_prefetch_drawable(PyObject *, PyObject *args) {
    PyObject *on;
    if (!PyArg_ParseTuple(args, "O", &on)) return nullptr;
    return guarded([&]() -> PyObject * {
        bool b = truth(on, "prefetch flag");
        engine([&] { pm::setPrefetchDrawable(b); });
        Py_RETURN_NONE;
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
PyObject *py_draw_stimulus(PyObject *, PyObject *args) {
    PyObject *p,*r,*m; if(!PyArg_ParseTuple(args,"OOO",&p,&r,&m)) return nullptr;
    return guarded([&]() -> PyObject * { Buffers hold; auto v=hold.view(p), d=hold.view(r);
        auto mask=unsignedScalar(m,"mask",pm::kMaxId);
        engine([&]{ pm::drawStimulus(v,d,mask); }); Py_RETURN_NONE; });
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

PyObject *py_get_image(PyObject *, PyObject *args) {
    PyObject *r = Py_None;
    if (!PyArg_ParseTuple(args, "|O", &r)) return nullptr;
    return guarded([&]() -> PyObject * {
        std::optional<pm::Rect4> rect;
        if (r != Py_None) {
            const char *m = "GetImage rect must be [left top right bottom] in whole pixels inside the window.";
            rect = numbers<4>(r, m, m);
        }
        pm::ImageRegion g{};
        engine([&] { g = pm::checkImageRect(rect); });
        size_t H = g.height, W = g.width;
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
    PyObject *s, *w, *h;
    if (!PyArg_ParseTuple(args, "OOO", &s, &w, &h)) return nullptr;
    return guarded([&]() -> PyObject * {
        double si = scalar(s, "screen index"), pw = scalar(w, "width"), ph = scalar(h, "height");
        engine([&] { pm::setMode(si, pw, ph); });
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

PyObject *py_mouse_events(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::MouseEvents e{};
        engine([&] { e = pm::mouseEvents(); });
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
        engine([&] { m = pm::mouse(); });
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
        engine([&] { k = pm::keys(); });
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
        engine([&] { s = pm::kbQueueStatus(); });
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
        engine([&] { e = pm::kbQueueGetEvents(); });
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
        engine([&] { c = pm::kbQueueCheck(); });
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
        engine([&] { t = pm::waitUntil(deadline); });
        return PyFloat_FromDouble(t);
    });
}

PyObject *py_diagnostic(PyObject *, PyObject *) {
    return guarded([&]() -> PyObject * {
        pm::DiagnosticReport r{};
        engine([&] { r = pm::diagnostic(); });
        std::vector<double> v;
        v.reserve(r.history.size() * 16);
        for (auto &x : r.history)
            v.insert(v.end(), {(double)x.token, x.projected, x.presented, (double)x.status, x.scheduledAt,
                               x.callback, (double)x.commandStatus, x.requestedTime, x.gpuStart, x.gpuEnd,
                               x.presentRequest, x.presentCallMs, x.committedAt, x.drawableAcquireMs,
                               x.encodeMs, x.prefetchMs});
        PyObject *history = doubles(v, r.history.size(), 16);
        const pm::DiagnosticSummary &d = r.summary;
        PyObject *s = PyDict_New();
        if (!s) { Py_DECREF(history); throw PythonErrorSet{}; }
        bool ok = true;
        auto num = [&](const char *k, double x) { ok = ok && setItem(s, k, PyFloat_FromDouble(x)) == 0; };
        auto flag = [&](const char *k, bool x) { ok = ok && setItem(s, k, PyBool_FromLong(x)) == 0; };
        auto text = [&](const char *k, const std::string &x) { ok = ok && setItem(s, k, PyUnicode_FromString(x.c_str())) == 0; };
        auto r4 = [&](const char *k, const pm::Rect4 &x) { ok = ok && setItem(s, k, rect4(x)) == 0; };
        // Same fields, same order, as the MATLAB Diagnostic struct.
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
        if (!ok) { Py_DECREF(history); Py_DECREF(s); throw PythonErrorSet{}; }
        return Py_BuildValue("(NN)", history, s);
    });
}

#define PM_METHOD(name, flags, doc) {#name, (PyCFunction)py_##name, flags, doc}
PyMethodDef methods[] = {
    PM_METHOD(version, METH_NOARGS, "Engine version string."),
    PM_METHOD(set_array_factory, METH_O, "Install factory(buffer, typecode, shape) used to build result arrays."),
    PM_METHOD(on_main_thread, METH_NOARGS, "True on the process main thread."),
    PM_METHOD(service_main_run_loop, METH_VARARGS, "service_main_run_loop(seconds=0.05): service AppKit on the main thread."),
    PM_METHOD(shutdown, METH_NOARGS, "Release every native resource. Registered with atexit."),
    PM_METHOD(prepare_app, METH_NOARGS, "Engine PrepareApp."),
    PM_METHOD(open_session, METH_VARARGS, "open_session(screen, drawables, wait_confirm, display_sync, capture[, refresh_hz[, readback[, bit_depth]]])."),
    PM_METHOD(startup_history, METH_NOARGS, "Startup history, n x 6."),
    PM_METHOD(confirm_startup, METH_NOARGS, "Confirm two background presentations; returns startup history."),
    PM_METHOD(close_session, METH_NOARGS, "Close the window and release it."),
    PM_METHOD(flip, METH_VARARGS, "flip([when]) -> (time, confirmed, slip, period, queue_ms, call_ms, return_time, token)."),
    PM_METHOD(flip_status, METH_NOARGS, "flip_status() -> (confirmed, dropped, dropped_frames) as the display has reported so far."),
    PM_METHOD(queue_flip, METH_VARARGS, "queue_flip(when) -> (token, pending, capacity)."),
    PM_METHOD(queue_results, METH_VARARGS, "queue_results(wait) -> (n, 4) float64: requested, presented, status, token."),
    PM_METHOD(queue_cancel, METH_NOARGS, "queue_cancel() -> frames abandoned."),
    PM_METHOD(prepare_flip, METH_NOARGS, "prepare_flip() -> token."),
    PM_METHOD(present_now, METH_NOARGS, "present_now() -> (time, call_ms)."),
    PM_METHOD(set_display_sync, METH_VARARGS, "set_display_sync(flag)."),
    PM_METHOD(set_prefetch_drawable, METH_VARARGS, "set_prefetch_drawable(flag)."),
    PM_METHOD(grid_anchor, METH_NOARGS, "grid_anchor() -> (anchor, period, samples)."),
    PM_METHOD(next_phase, METH_VARARGS, "next_phase(after, phase)."),
    PM_METHOD(next_refresh, METH_VARARGS, "next_refresh(after)."),
    PM_METHOD(wait_to_draw, METH_VARARGS, "wait_to_draw(target, budget) -> (woke_at, lead, deadline)."),
    PM_METHOD(set_background_color, METH_VARARGS, "set_background_color(r, g, b, a), components 0..1."),
    PM_METHOD(check_stimulus, METH_VARARGS, "Validate procedural stimulus parameters."),
    PM_METHOD(draw_stimulus, METH_VARARGS, "Draw procedural stimulus parameters, destination and mask."),
    PM_METHOD(add_shapes, METH_VARARGS, "add_shapes(kind (N,), param (N,), rect (N,4), color (N,4), extra (N,4)), float64."),
    PM_METHOD(make_texture, METH_VARARGS, "make_texture(image (H,W[,C])) -> handle."),
    PM_METHOD(update_texture, METH_VARARGS, "update_texture(handle, image[, left, top])."),
    PM_METHOD(draw_textures, METH_VARARGS,
              "draw_textures(handle (N,), src (N,4), dst (N,4), angle_rad (N,), tint (N,4), filter (N,)), float64."),
    PM_METHOD(close_texture, METH_VARARGS, "close_texture(handle)."),
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
    PM_METHOD(get_image, METH_VARARGS, "get_image([rect]) -> (H, W, 3) RGB of the last frame, uint8 or (10-bit) uint16; needs readback."),
    PM_METHOD(noise_values, METH_VARARGS, "noise_values(w, h, seed, normal, colour, mean3, spread) -> array 0..1."),
    PM_METHOD(modes, METH_VARARGS, "modes(screen) -> n x 5 (point w, point h, pixel w, pixel h, Hz)."),
    PM_METHOD(set_mode, METH_VARARGS, "set_mode(screen, point_w, point_h)."),
    PM_METHOD(set_cursor_visible, METH_VARARGS, "set_cursor_visible(flag)."),
    PM_METHOD(mouse, METH_NOARGS, "mouse() -> (x, y, (left, right, centre))."),
    PM_METHOD(mouse_events, METH_NOARGS, "mouse_events() -> ((n, 5) float64: time, button, pressed, x, y; dropped)."),
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
