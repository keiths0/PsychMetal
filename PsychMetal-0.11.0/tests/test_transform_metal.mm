// Real offscreen Metal pixel checks for transforms and a shape's own turn
// (Translate, Rotate, Scale and the drawing commands' trailing angle): each
// is drawn on the GPU and compared with the shape that should result, drawn
// untransformed. Rectangles, so the antialiased edges must match too: a scaled
// shape's edge is still a pixel wide. No window needed.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include "../PsychMetalShaders.h"
struct S { float rect[4], color[4]; uint32_t kind; float param, pad[2], extra[4]; };
static_assert(sizeof(S) == 64, "as the engine's PMShape");
struct XF { float m[4], t[4]; };     // as the engine's PMXfUniform
static const int W = 96, H = 96;
static XF xf(float a, float b, float c, float d, float tx, float ty) {
    return {{a, b, c, d}, {tx, ty, std::sqrt(std::fabs(a * d - b * c)), 0}};
}
int main() { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { puts("SKIP: no Metal device available."); return 77; }
    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:PMMetalSource] options:nil error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"svmain"];
    pd.fragmentFunction = [lib newFunctionWithName:@"sfmain"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;     // no blending: the coverage itself
    id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
    assert(pipeline);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:W height:H mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> out = [dev newTextureWithDescriptor:td];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    const XF none = xf(1, 0, 0, 1, 0, 0);
    auto render = [&](S s, XF x) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        float size[2] = {(float)W, (float)H};
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBytes:&s length:sizeof(s) atIndex:0];
        [enc setVertexBytes:size length:sizeof(size) atIndex:1];
        [enc setVertexBytes:&x length:sizeof(x) atIndex:2];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        assert(cb.status == MTLCommandBufferStatusCompleted);
        std::vector<__fp16> v(W * H * 4);
        [out getBytes:v.data() bytesPerRow:W * 8 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        std::vector<double> a(W * H);
        for (int i = 0; i < W * H; i++) a[i] = v[i * 4 + 3];
        return a;
    };
    auto shape = [](uint32_t kind, float param, float l, float t, float r, float b, float turnDeg = 0) {
        S s{}; s.rect[0] = l; s.rect[1] = t; s.rect[2] = r; s.rect[3] = b;
        for (float &c : s.color) c = 1;
        s.kind = kind; s.param = param; s.pad[0] = (float)(turnDeg * M_PI / 180);
        return s;
    };
    auto same = [&](const std::vector<double> &got, const std::vector<double> &want, const char *what) {
        double covered = 0, worst = 0;
        for (int i = 0; i < W * H; i++) { covered += want[i]; worst = std::max(worst, std::fabs(got[i] - want[i])); }
        if (worst > .02 || covered < 50) {
            fprintf(stderr, "%s: differs by %g at worst (%g pixels covered)\n", what, worst, covered);
            return false;
        }
        return true;
    };
    // A rect's own turn, 90 degrees clockwise about its centre: the rect stood up.
    const auto upright = render(shape(0, 1, 40, 28, 56, 68), none);
    assert(same(render(shape(0, 1, 28, 40, 68, 56, 90), none), upright, "a rect's own 90-degree turn"));
    // The same by a transform: turned 90 degrees clockwise about (48, 48), x' = 96 - y, y' = x.
    assert(same(render(shape(0, 1, 28, 40, 68, 56), xf(0, 1, -1, 0, 96, 0)), upright, "Rotate 90 about the centre"));
    // A turned frame keeps its pen: a framed rect turned a half turn is itself.
    assert(same(render(shape(1, 3, 20, 30, 76, 66, 180), none), render(shape(1, 3, 20, 30, 76, 66), none), "a framed rect, half a turn"));
    // Translation, exactly.
    assert(same(render(shape(0, 1, 10.5f, 10, 30, 20.25f), xf(1, 0, 0, 1, 10, 5)), render(shape(0, 1, 20.5f, 15, 40, 25.25f), none), "Translate"));
    // Scale: twice as large, and the antialiased edge still one pixel of the target.
    assert(same(render(shape(0, 1, 10.25f, 10, 30, 20.5f), xf(2, 0, 0, 2, 0, 0)), render(shape(0, 1, 20.5f, 20, 60, 41), none), "Scale 2"));
    assert(same(render(shape(0, 1, 40, 40, 80, 82), xf(.5f, 0, 0, .5f, 0, 0)), render(shape(0, 1, 20, 20, 40, 41), none), "Scale 0.5"));
    // A frame's pen and a line's width scale with it, as the rest of the shape does.
    assert(same(render(shape(1, 2, 10, 10, 40, 30), xf(2, 0, 0, 2, 0, 0)), render(shape(1, 4, 20, 20, 80, 60), none), "a framed rect, scaled"));
    assert(same(render(shape(5, 3, 10, 20, 40, 20), xf(2, 0, 0, 2, 0, 0)), render(shape(5, 6, 20, 40, 80, 40), none), "a line, scaled"));
    // A line's own turn is about its midpoint.
    assert(same(render(shape(5, 4, 28, 48, 68, 48, 90), none), render(shape(5, 4, 48, 28, 48, 68), none), "a line's own turn"));
    // The own turn comes first, then the transform: a rect turned 90 about itself, then moved.
    assert(same(render(shape(0, 1, 18, 30, 58, 46, 90), xf(1, 0, 0, 1, 10, 10)), upright, "own turn, then Translate"));
    puts("PASS: transforms on the GPU: a shape's own turn, Rotate, Translate and Scale draw the shapes they should, edges and pens included.");
} }
