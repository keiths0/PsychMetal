// Real offscreen Metal pixel checks for arcs (shape kind 8): a filled wedge and a
// framed band, against the geometry computed here in double precision; a
// negative sweep against the same arc given forwards; and a full sweep against
// the filled and framed oval it must equal. No window needed.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
#include "../PsychMetalShaders.h"
struct S { float rect[4], color[4]; uint32_t kind; float param, pad[2], extra[4]; };
static_assert(sizeof(S) == 64, "as the engine's PMShape");
static const int W = 96, H = 96;
int main() { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) { puts("SKIP: no Metal device available."); return 77; }
    NSError *error = nil;
    id<MTLLibrary> lib = [d newLibraryWithSource:[NSString stringWithUTF8String:PMMetalSource] options:nil error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"svmain"];
    pd.fragmentFunction = [lib newFunctionWithName:@"sfmain"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;     // no blending: the coverage itself
    id<MTLRenderPipelineState> pipeline = [d newRenderPipelineStateWithDescriptor:pd error:&error];
    assert(pipeline);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:W height:H mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> out = [d newTextureWithDescriptor:td];
    id<MTLCommandQueue> queue = [d newCommandQueue];
    auto render = [&](S s) {
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = out; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        float size[2] = {(float)W, (float)H};
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBytes:&s length:sizeof(s) atIndex:0];
        [enc setVertexBytes:size length:sizeof(size) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        assert(cb.status == MTLCommandBufferStatusCompleted);
        std::vector<__fp16> v(W * H * 4);
        [out getBytes:v.data() bytesPerRow:W * 8 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        std::vector<double> a(W * H);
        for (int i = 0; i < W * H; i++) a[i] = v[i * 4 + 3];
        return a;
    };
    auto shape = [](uint32_t kind, float pen, float l, float t, float r, float b, double startDeg, double sweepDeg) {
        S s{}; s.rect[0] = l; s.rect[1] = t; s.rect[2] = r; s.rect[3] = b;
        for (float &c : s.color) c = 1;
        s.kind = kind; s.param = pen;
        s.extra[0] = (float)(startDeg * M_PI / 180); s.extra[1] = (float)(sweepDeg * M_PI / 180);
        return s;
    };
    // Where the pixel whose centre is (x, y) lies against an arc of the circle of
    // radius R about (48, 48): its distance inside the circle's edge (or band) and
    // inside the arc's ends, in pixels; negative outside.
    const double cx = 48, cy = 48, R = 40;
    auto check = [&](const std::vector<double> &a, double startDeg, double sweepDeg, double pen, const char *what) {
        int inside = 0, outside = 0;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                double px = x + .5 - cx, py = y + .5 - cy, rho = std::hypot(px, py);
                double radial = pen > 0 ? std::min(R - rho, rho - (R - pen)) : R - rho;
                double t = std::fmod(std::atan2(px, -py) - startDeg * M_PI / 180, 2 * M_PI);
                if (t < 0) t += 2 * M_PI;
                double sweep = sweepDeg * M_PI / 180;
                double angular = (t <= sweep ? std::min(t, sweep - t) : -std::min(t - sweep, 2 * M_PI - t)) * rho;
                double got = a[y * W + x];
                if (radial > 1.5 && angular > 1.5) {
                    if (got < .99) { fprintf(stderr, "%s: (%d,%d) inside, coverage %g\n", what, x, y, got); return false; }
                    inside++;
                } else if (radial < -1.5 || angular < -1.5) {
                    if (got > .01) { fprintf(stderr, "%s: (%d,%d) outside, coverage %g\n", what, x, y, got); return false; }
                    outside++;
                }
            }
        assert(inside > 50 && outside > 50);
        return true;
    };
    assert(check(render(shape(8, 0, 8, 8, 88, 88, 30, 120)), 30, 120, 0, "wedge 30+120"));
    assert(check(render(shape(8, 0, 8, 8, 88, 88, 200, 250)), 200, 250, 0, "wedge over half a turn"));
    assert(check(render(shape(8, 6, 8, 8, 88, 88, 300, 100)), 300, 100, 6, "band 6 pixels, across the top"));
    // A negative sweep is the same arc given from its other end.
    auto backwards = render(shape(8, 4, 8, 8, 88, 88, 0, -90)), forwards = render(shape(8, 4, 8, 8, 88, 88, 270, 90));
    for (int i = 0; i < W * H; i++) assert(std::fabs(backwards[i] - forwards[i]) < 1e-3);
    // A whole turn is the oval: filled (kind 2) and framed (kind 3), on an ellipse.
    auto wedge = render(shape(8, 0, 4, 20, 92, 76, 10, 360)), oval = render(shape(2, 0, 4, 20, 92, 76, 0, 0));
    auto band = render(shape(8, 5, 4, 20, 92, 76, 10, 360)), frame = render(shape(3, 5, 4, 20, 92, 76, 0, 0));
    for (int i = 0; i < W * H; i++) assert(std::fabs(wedge[i] - oval[i]) < 1e-3 && std::fabs(band[i] - frame[i]) < 1e-3);
    puts("PASS: arcs on the GPU: wedges and bands where the geometry puts them, a negative sweep, and a whole turn equal to the oval.");
} }
