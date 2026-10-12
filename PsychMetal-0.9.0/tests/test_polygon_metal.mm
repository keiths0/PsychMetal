// Real offscreen Metal pixel checks for the polygon shader: filled by the
// even-odd rule and stroked, against the same rule computed here in double
// precision. No window needed.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include "../PsychMetalShaders.h"
struct U { float box[4], color[4], size[2]; uint32_t first, count; float pen, pad[3]; };
static_assert(sizeof(U) == 64, "as the engine's");
// The reference: coverage of the pixel whose centre is (px, py).
static double expected(const std::vector<float> &xy, double px, double py, double pen) {
    size_t n = xy.size() / 2;
    bool inside = false;
    double nearest = 1e30;
    for (size_t i = 0, j = n - 1; i < n; j = i++) {
        double ax = xy[2 * j], ay = xy[2 * j + 1], bx = xy[2 * i], by = xy[2 * i + 1];
        if ((ay > py) != (by > py) && px < (bx - ax) * (py - ay) / (by - ay) + ax) inside = !inside;
        double ex = bx - ax, ey = by - ay, wx = px - ax, wy = py - ay;
        double t = fmax(0, fmin(1, (wx * ex + wy * ey) / fmax(ex * ex + ey * ey, 1e-12)));
        double qx = wx - ex * t, qy = wy - ey * t;
        nearest = fmin(nearest, qx * qx + qy * qy);
    }
    double d = sqrt(nearest);
    auto sat = [](double v) { return fmax(0, fmin(1, v)); };
    return pen > 0 ? sat(pen * .5 + .5 - d) : (inside ? sat(.5 + d) : sat(.5 - d));
}
int main() { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) { puts("SKIP: no Metal device available."); return 77; }
    NSError *error = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:[NSString stringWithUTF8String:PMMetalSource] options:nil error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"gvmain"];
    pd.fragmentFunction = [lib newFunctionWithName:@"gfmain"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;     // no blending: the coverage itself
    id<MTLRenderPipelineState> pipeline = [d newRenderPipelineStateWithDescriptor:pd error:&error];
    assert(pipeline);
    const int W = 96, H = 80;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:W height:H mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> out = [d newTextureWithDescriptor:td];
    id<MTLCommandQueue> queue = [d newCommandQueue];
    id<MTLBuffer> points = [d newBufferWithLength:4096 * 8 options:MTLResourceStorageModeShared];
    auto render = [&](const std::vector<float> &xy, float pen, uint32_t first) {
        memcpy((float *)points.contents + 2 * first, xy.data(), xy.size() * sizeof(float));
        U u = {{0, 0, (float)W, (float)H}, {1, 1, 1, 1}, {(float)W, (float)H}, first, (uint32_t)(xy.size() / 2), pen, {0, 0, 0}};
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
        [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [enc setFragmentBuffer:points offset:0 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        assert(cb.status == MTLCommandBufferStatusCompleted);
        std::vector<__fp16> v(W * H * 4);
        [out getBytes:v.data() bytesPerRow:W * 8 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        return v;
    };
    auto check = [&](const std::vector<float> &xy, float pen, uint32_t first) {
        auto v = render(xy, pen, first);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                double want = expected(xy, x + .5, y + .5, pen);
                double got = v[(y * W + x) * 4 + 3];                  // alpha is the coverage
                if (fabs(got - want) > .004) { fprintf(stderr, "(%d,%d): %g, want %g\n", x, y, got, want); return false; }
            }
        return true;
    };
    std::vector<float> triangle = {10, 10, 80, 15, 30, 70};
    assert(check(triangle, 0, 0));                                     // filled
    assert(check(triangle, 4, 0));                                     // stroked 4 pixels wide
    std::vector<float> star = {48, 5, 60, 75, 10, 30, 86, 30, 36, 75};  // self-intersecting: a pentagram
    assert(check(star, 0, 100));                                       // even-odd, from an offset in the buffer
    auto v = render(star, 0, 0);
    assert(v[(40 * W + 48) * 4 + 3] == 0);                             // its centre is a hole
    puts("PASS: polygons on the GPU: even-odd fill, stroked outline and antialiased edges, pixel for pixel against the rule in double.");
} }
