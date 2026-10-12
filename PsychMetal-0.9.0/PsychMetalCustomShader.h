// Fixed custom shader ABI, generated outside the presentation loop.
#ifndef PSYCHMETAL_CUSTOM_SHADER_H
#define PSYCHMETAL_CUSTOM_SHADER_H
#include <string>
namespace pm { namespace internal {
// The engine's wrapper comes before the user's source, which is compiled last,
// under its own file name. A user #define therefore cannot change the wrapper's
// clamping or discard, and compiler messages give the user's own line numbers.
// Names the engine source and wrapper define are taken; CUSTOM-SHADERS.md lists them.
inline std::string customShaderSource(const std::string &base,const std::string &user) {
 return base+R"MSL(
#line 1 "psychmetal-wrapper.metal"
float4 psychmetal_main(float2 pixel,float2 uv,constant float4 *parameters);
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
#line 1 "psychmetal-user.metal"
)MSL"+user+"\n";
}

// The compiler's messages about the user's file, without the engine's own
// diagnostics, so the user's error is never crowded out. Falls back to the
// whole log when no message names the user's file. At most 16 KiB.
inline std::string customShaderErrors(const std::string &log) {
 static const char kUser[]="psychmetal-user.metal:";
 std::string kept;bool keep=false;size_t at=0;
 while(at<log.size()) {
  size_t end=log.find('\n',at);if(end==std::string::npos)end=log.size();
  std::string line=log.substr(at,end-at);at=end+1;
  // A diagnostic starts "file:line:column: kind:"; its excerpt and caret lines follow.
  size_t colon=line.find(": ");
  bool header=colon!=std::string::npos && (line.compare(colon,9,": error: ")==0 ||
      line.compare(colon,11,": warning: ")==0 || line.compare(colon,8,": note: ")==0);
  if(header)keep=line.find(kUser)!=std::string::npos;
  if(keep)kept+=line+"\n";
 }
 std::string out=kept.empty()?log:kept;
 while(!out.empty() && (out.back()=='\n' || out.back()==' '))out.pop_back();
 if(out.size()>16384)out=out.substr(0,16384)+"\n...";
 return out;
}
}}
#endif
