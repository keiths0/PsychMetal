#!/usr/bin/env python3
"""The engine's cache of rendered text and polygons (findMask and keepMask,
extracted from PsychMetalEngine.mm): when a new mask does not fit, the ones
wanted longest ago make way, so what is drawn on every frame stays while text
that changes passes through. And measuring text renders nothing."""
from pathlib import Path
import re, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'PsychMetalEngine.mm').read_text()
a = s.index('#define PM_MASK_COUNT'); b = s.index('// Queue a mask with its top left at a whole pixel')
source = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <map>
#include <memory>
#include <string>
struct PMTextureResource { size_t width, height; };
using PMTextureRef = std::shared_ptr<PMTextureResource>;
struct PMMask { PMTextureRef mask; double width, height, ascent; uint64_t used; };
static std::map<std::string, PMMask> maskCache;
static size_t maskCacheBytes;
static uint64_t maskUses;
static PMMask unkeptMask;
''' + s[a:b] + r'''
static PMMask make(size_t w, size_t h) { PMMask m{}; m.mask = std::make_shared<PMTextureResource>(PMTextureResource{w, h}); m.width = (double)w; return m; }
static size_t held() { size_t n = 0; for (auto &e : maskCache) n += e.second.mask->width * e.second.mask->height; return n; }
int main() {
    assert(!findMask("fixed"));
    const PMMask &kept = keepMask("fixed", make(100, 10));
    assert(kept.width == 100 && findMask("fixed") == &kept && maskCacheBytes == 1000);
    // A counter redrawn with new text on every frame, beside instructions that do not change:
    // the instructions are wanted on every frame and are never the ones to go.
    for (int frame = 0; frame < 5000; frame++) {
        assert(findMask("fixed"));
        std::string text = "frame " + std::to_string(frame);
        assert(!findMask(text));
        keepMask(text, make(60, 10));
        assert(maskCache.size() <= PM_MASK_COUNT && maskCacheBytes == held());
    }
    assert(maskCache.size() == PM_MASK_COUNT && findMask("fixed") == &kept);
    assert(findMask("frame 4999") && findMask("frame 4745") && !findMask("frame 4744"));   // the newest 255 remain
    // The byte limit: masks of 60 MB each, of which four fit beside what is there.
    PMTextureRef old = findMask("frame 4999")->mask;        // a queued draw's own reference
    for (int i = 0; i < 6; i++) {
        assert(findMask("fixed"));
        keepMask("big " + std::to_string(i), make(60u << 20, 1));
        assert(maskCacheBytes <= PM_MASK_BYTES && maskCacheBytes == held());
    }
    assert(findMask("big 5") && findMask("big 2") && !findMask("big 1") && findMask("fixed") == &kept);
    assert(old->width == 60);                               // an evicted mask lives while a draw holds it
    // A mask too large to keep is handed back and held only until the next one.
    const PMMask &huge = keepMask("huge", make(65u << 20, 1));
    assert(&huge == &unkeptMask && !findMask("huge") && maskCacheBytes == held());
    puts("PASS: mask cache: the masks wanted longest ago make way, by count and by bytes; fixed text survives 5000 changing lines; a mask too large is not kept.");
}
'''
with tempfile.TemporaryDirectory() as d:
    p = Path(d); (p / 'test.cpp').write_text(source)
    subprocess.run(['clang++', '-std=c++17', '-fsanitize=address,undefined', str(p / 'test.cpp'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
# Measuring lays the line out and makes no mask: neither the renderer nor a texture is reached from textBounds.
a = s.index('pm::TextBounds pm::textBounds('); body = s[a:s.index('\n}\n', a)]
assert 'layoutText(' in body and 'findMask(' in body and not re.search(r'textFor\(|makeMaskTexture\(|keepMask\(', body)
layout = s[s.index('static PMTextLine layoutText('):s.index('static const PMMask &textFor(')]
assert not re.search(r'makeMaskTexture\(|keepMask\(|CGBitmapContextCreate', layout)
print('PASS: textBounds lays a line out without rendering it.')
