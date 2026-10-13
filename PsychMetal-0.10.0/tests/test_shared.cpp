// What PsychMetalShared.cpp does for every front end, without a Mac or a GPU:
// text layout and its cache, recipes from named options, key names and sounds.
#include "../PsychMetalInternal.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
static int measured = 0;
// 10 pixels a character and a pixel of margin either end, 24 high, ascent 18.
static pm::TextBounds measure(const std::string &s, const std::string &, double) {
    ++measured;
    return {10.0 * (double)s.size() + 2, 24, 18};
}
static pm::Option number(const char *name, std::vector<double> v) { pm::Option o; o.name = name; o.numbers = v; return o; }
static pm::Option text(const char *name, const char *v) { pm::Option o; o.name = name; o.isText = true; o.text = v; return o; }
template <class F> static bool refused(F f) { try { f(); } catch (const pm::Error &) { return true; } return false; }
int main() {
    // Lines at newlines (\r\n and \r too), an empty one measured as nothing.
    pm::TextLayout l = pm::internal::layoutText("ab\r\n\rabcdef", "", 20, INFINITY, measure);
    assert(l.lines.size() == 3 && l.lines[0] == "ab" && l.lines[1].empty() && l.lines[2] == "abcdef");
    assert(l.sizes[0][0] == 22 && l.sizes[1][0] == 0 && l.sizes[2][1] == 24 && l.ascent == 18);
    // Wrapping: a word is 10n wide, a space 10. 65 pixels hold 'aa bbb' but not 'aa bbb cc'.
    l = pm::internal::layoutText("aa bbb  cc dddd", "", 20, 65, measure);
    assert(l.lines.size() == 3 && l.lines[0] == "aa bbb" && l.lines[1] == "cc" && l.lines[2] == "dddd");
    // The same text again is not measured again; sixteen others push it out.
    int before = measured;
    pm::internal::layoutText("aa bbb  cc dddd", "", 20, 65, measure);
    assert(measured == before);
    for (int i = 0; i < 16; i++) pm::internal::layoutText("t" + std::to_string(i), "", 20, INFINITY, measure);
    before = measured;
    pm::internal::layoutText("aa bbb  cc dddd", "", 20, 65, measure);
    assert(measured > before);
    assert(refused([] { pm::internal::layoutText("\n\n", "", 20, INFINITY, measure); }));
    // Recipes: defaults, options, and refusals with the option named.
    auto g = pm::makeStimulus("grating", {});
    assert(g[0] == 0 && g[1] == .5 && g[5] == .02 && g[14] == .35);
    auto n = pm::makeStimulus("noise", {number("mean", {.2, .3, .4}), number("seed", {7}), text("aperture", "gaussian"),
                                        number("sigma", {.5}), number("orientation", {370})});
    assert(n[0] == 1 && n[1] == .2 && n[3] == .4 && n[8] == 7 && n[13] == 2 && n[14] == .5 && n[6] == 10);
    assert(refused([] { pm::makeStimulus("plaid", {}); }));
    assert(refused([] { pm::makeStimulus("noise", {number("unknown", {1})}); }));
    assert(refused([] { pm::makeStimulus("noise", {number("contrast", {2})}); }));
    assert(refused([] { pm::makeStimulus("noise", {text("aperture", "star")}); }));
    pm::ArrayView base{}; base.data = g.data(); base.type = pm::ScalarType::Float64; base.ndim = 1; base.shape[0] = 15; base.strides[0] = 8;
    auto with = pm::stimulusWith(base, {number("phase", {90})});
    assert(with[7] == 90 && with[5] == g[5]);
    auto m = pm::makeMask("annulus", {number("inner", {.2}), number("center", {.1, -.1})});
    assert(m[0] == 2 && m[2] == .2 && m[3] == 1 && m[4] == .05 && m[5] == .1 && m[6] == -.1);
    assert(pm::makeMask("gaussian", {number("sigma", {.25})})[1] == .25);
    assert(refused([] { pm::makeMask("gaussian", {number("radius", {1})}); }));
    assert(refused([] { pm::makeMask("ellipse", {number("center", {1})}); }));
    // Key names, as KbName on macOS.
    const auto &k = pm::keyNames();
    auto name = [&](int usage) { for (auto &e : k) if (e.usage == usage) return std::string(e.name); return std::string(); };
    assert(name(4) == "a" && name(41) == "ESCAPE" && name(58) == "F1" && name(104) == "F13" && name(231) == "RightGUI");
    // Sounds: a tone's ramps, a click's onset, a seeded noise repeated.
    auto t = pm::tone(1000, .01, 48000, .5, .002);
    assert(t.size() == 480 && t[0] == 0 && std::fabs(t[240] - .5 * std::sin(2 * M_PI * 1000 * 240 / 48000.0)) < 1e-12);
    assert(std::fabs(t[479]) < .01);
    auto c = pm::click(48000);
    assert(c.size() == 48 && c[0] == .9);
    auto a = pm::whiteNoise(.1, 1000, .3, 5), b = pm::whiteNoise(.1, 1000, .3, 5), d = pm::whiteNoise(.1, 1000, .3, 6);
    assert(a == b && a != d && a.size() == 100);
    auto tiny = pm::whiteNoise(.1, 1000, std::numeric_limits<double>::denorm_min(), 5);
    for (double v : tiny) assert(std::isfinite(v));
    auto silent = pm::whiteNoise(.1, 1000, 0, 5);
    for (double v : silent) assert(v == 0);
    assert(refused([] { pm::whiteNoise(.1, 1000, -.3, 5); }));
    assert(refused([] { pm::tone(1000, 0, 48000); }));
    assert(refused([] { pm::whiteNoise(1, 1000, .3, -1); }));
    std::puts("PASS: shared layout (newlines, wrapping, its cache), recipes from named options, key names and sounds.");
}
