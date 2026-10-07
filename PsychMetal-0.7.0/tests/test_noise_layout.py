#!/usr/bin/env python3
"""pm::noiseValues (PsychMetalShared.cpp, linked as is) writes the same noise
whatever the layout of the array it is given: MATLAB's column-major, numpy's
row-major, reversed and with gaps, grey and colour, uniform and normal. The
order in which it visits pixels follows the layout, for speed, and must not
change a value."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = r'''
#include "PsychMetalEngine.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
// The value at (y, x, c) of noise written into an array laid out with these strides (in doubles).
struct Laid {
    std::vector<double> store; pm::MutableArrayView view; ptrdiff_t sy, sx, sc; double *origin;
    Laid(size_t H, size_t W, size_t C, ptrdiff_t sy_, ptrdiff_t sx_, ptrdiff_t sc_) : sy(sy_), sx(sx_), sc(sc_) {
        size_t span = (H - 1) * (size_t)std::llabs(sy) + (W - 1) * (size_t)std::llabs(sx) + (C - 1) * (size_t)std::llabs(sc) + 1;
        store.assign(span, -1.0);
        origin = store.data() + (sy < 0 ? (H - 1) * (size_t)-sy : 0) + (sx < 0 ? (W - 1) * (size_t)-sx : 0);
        view.data = origin; view.ndim = C > 1 ? 3 : 2; view.shape = {H, W, C};
        view.strides = {sy * (ptrdiff_t)sizeof(double), sx * (ptrdiff_t)sizeof(double), sc * (ptrdiff_t)sizeof(double)};
    }
    double at(size_t y, size_t x, size_t c) const { return origin[(ptrdiff_t)y * sy + (ptrdiff_t)x * sx + (ptrdiff_t)c * sc]; }
};
int main() {
    const size_t H = 37, W = 53;
    for (int colour = 0; colour < 2; colour++) for (int normal = 0; normal < 2; normal++) {
        const size_t C = colour ? 3 : 1;
        const ptrdiff_t h = (ptrdiff_t)H, w = (ptrdiff_t)W, c = (ptrdiff_t)C;
        pm::NoiseRequest q{(double)W, (double)H, 12345, normal != 0, colour != 0, {0.5, 0.4, 0.6}, 0.2};
        std::vector<Laid> layouts;
        layouts.emplace_back(H, W, C, 1, h, h * w);                // column-major, as MATLAB allocates
        layouts.emplace_back(H, W, C, w * c, c, 1);                // row-major, as numpy allocates
        layouts.emplace_back(H, W, C, -(w * c), c, 1);             // rows reversed
        layouts.emplace_back(H, W, C, w * c, -c, 1);               // columns reversed
        layouts.emplace_back(H, W, C, 2 * w * c, 2 * c, 1);        // every other row and column of a larger array
        layouts.emplace_back(H, W, C, 2, 2 * h, 2 * h * w);        // the same, column-major
        for (Laid &l : layouts) pm::noiseValues(q, l.view);
        size_t distinct = 0;
        for (size_t y = 0; y < H; y++) for (size_t x = 0; x < W; x++) for (size_t k = 0; k < C; k++) {
            double v = layouts[0].at(y, x, k);
            assert(v >= 0 && v <= 1);
            distinct += v != layouts[0].at(0, 0, 0);
            for (const Laid &l : layouts) assert(l.at(y, x, k) == v);
        }
        assert(distinct > H * W * C * 9 / 10);                     // noise, not a constant
        // Nothing is written between the elements of a view with gaps.
        size_t untouched = 0;
        for (double v : layouts[4].store) untouched += v == -1.0;
        assert(untouched == layouts[4].store.size() - H * W * C);
    }
    puts("PASS: noiseValues writes identical noise into column-major, row-major, reversed and gapped arrays, grey and colour, uniform and normal.");
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 'test.cpp').write_text(source)
    subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', '-iquote', str(root), str(p / 'test.cpp'),
                    str(root / 'PsychMetalShared.cpp'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
