// Fixed custom shader ABI, generated outside the presentation loop.
#ifndef PSYCHMETAL_CUSTOM_SHADER_H
#define PSYCHMETAL_CUSTOM_SHADER_H
#include <string>
namespace pm { namespace internal {
inline std::string customShaderSource(const std::string &base,const std::string &user) {
 return base+"\n#line 1 \"psychmetal-user.metal\"\n"+user+R"MSL(
#line 1 "psychmetal-wrapper.metal"
struct CU {float4 dst;float4 params[4];float4 viewport;float4 maskA,maskB;};
vertex PV cvmain(uint vid [[vertex_id]],constant CU &u [[buffer(0)]]) {
 float2 uv=float2(vid&1,vid>>1),pixel=mix(u.dst.xy,u.dst.zw,uv);
 PV o;o.p=float4(pixel.x/u.viewport.x*2-1,1-pixel.y/u.viewport.y*2,0,1);o.uv=uv;return o;
}
fragment float4 cfmain(PV in [[stage_in]],constant CU &u [[buffer(0)]],
                       texture2d<float> mask [[texture(0)]],sampler s [[sampler(0)]]) {
 float coverage=mask.sample(s,in.uv).r;
 if(u.maskA.x>=0)coverage*=pmMaskCoverage(in.uv*2-1,u.maskA,u.maskB);
 if(coverage<=0)discard_fragment();
 float4 color=psychmetal_main((in.uv-.5)*(u.dst.zw-u.dst.xy),in.uv,u.params);
 if(!all(isfinite(color)))discard_fragment();
 return float4(saturate(color.rgb),saturate(color.a)*coverage);
}
)MSL";
}
}}
#endif
