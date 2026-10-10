#include <metal_stdlib>
using namespace metal;
struct S{float4 rect;float4 color;uint kind;float param;float2 pad;float4 extra;};
struct SV{float4 p[[position]];float4 color;float2 local;float2 hs;float param;float3 gab;uint kind[[flat]];};
vertex SV svmain(uint vid[[vertex_id]],uint iid[[instance_id]],constant S*sh[[buffer(0)]],constant float2&size[[buffer(1)]]){
  float2 c[4]={float2(0,0),float2(1,0),float2(0,1),float2(1,1)};
  float2 f=c[vid];S s=sh[iid];SV o;float2 px;
  if(s.kind==5u){
    float2 p0=s.rect.xy,p1=s.rect.zw;float2 d=p1-p0;
    float len=max(length(d),1e-6);float2 u=d/len;
    float hw=s.param*0.5+1.0;float2 n=float2(-u.y,u.x)*hw;
    px=mix(p0,p1,f.x)+n*(f.y*2.0-1.0);
    o.local=float2(0.0,(f.y*2.0-1.0)*hw);
    o.hs=float2(len,s.param*0.5);
  }else{
    float2 lo=min(s.rect.xy,s.rect.zw);
    float2 hi=max(s.rect.xy,s.rect.zw);
    float2 ctr=(lo+hi)*0.5;float2 hs=(hi-lo)*0.5;
    float2 grown=hs+1.0;
    px=ctr+(f*2.0-1.0)*grown;
    o.local=(f*2.0-1.0)*grown;o.hs=hs;
  }
  o.p=float4(px.x/size.x*2.0-1.0,1.0-px.y/size.y*2.0,0,1);
  o.color=s.color;o.param=s.param;o.gab=s.extra.xyz;
  o.kind=s.kind;return o;}
uint pmHash(uint v){uint s=v*747796405u+2891336453u;
  uint w=((s>>((s>>28)+4u))^s)*277803737u;return (w>>22)^w;}
float pmUnit(uint k){return float(k)*2.3283064365386963e-10;}
float pmDeviate(uint base,uint ch,bool nrm){
  uint k=pmHash(base+ch*0x9E3779B9u);
  if(!nrm) return pmUnit(k)*2.0-1.0;
  float u1=pmUnit(k)*0.9999998+1e-7;
  float u2=pmUnit(pmHash(k+1u));
  return sqrt(-2.0*log(u1))*cos(6.28318530718*u2);}
fragment float4 sfmain(SV in[[stage_in]]){
  float2 p=in.local;float2 h=max(in.hs,float2(1e-6));float a=1.0;
  float3 rgb=in.color.rgb;
  if(in.kind==0u){
    float2 d=abs(p)-h;a=saturate(0.5-max(d.x,d.y));
  }else if(in.kind==1u){
    float2 d=abs(p)-h;float outer=saturate(0.5-max(d.x,d.y));
    float2 hi=max(h-in.param,float2(0.0));
    float2 di=abs(p)-hi;float inner=saturate(0.5-max(di.x,di.y));
    a=outer-inner;
  }else if(in.kind==2u||in.kind==4u){
    float r=length(p/h);float w=max(fwidth(r),1e-5);
    a=1.0-smoothstep(1.0-w,1.0+w,r);
  }else if(in.kind==3u){
    float r=length(p/h);float w=max(fwidth(r),1e-5);
    float outer=1.0-smoothstep(1.0-w,1.0+w,r);
    float2 hi=max(h-in.param,float2(1e-6));
    float ri=length(p/hi);float wi=max(fwidth(ri),1e-5);
    float inner=1.0-smoothstep(1.0-wi,1.0+wi,ri);
    a=outer-inner;
  }else if(in.kind==6u){
    float2 q=p/h;float sg=max(in.param,1e-3);
    a=exp(-dot(q,q)/(2.0*sg*sg));
    if(in.gab.x>0.0){
      float d=p.x*cos(in.gab.y)+p.y*sin(in.gab.y);   // clockwise on screen, as MakeStimulus
      float c=cos(6.28318530718*in.gab.x*d+in.gab.z);
      rgb=rgb*(0.5+0.5*c);
    }
  }else if(in.kind==7u){
    float2 q=p+h;
    int ix=int(floor(q.x)),iy=int(floor(q.y));
    int wp=int(2.0*h.x),hp=int(2.0*h.y);
    if(ix<0||iy<0||ix>=wp||iy>=hp){a=0.0;}else{
      uint sd=uint(in.gab.x);
      uint base=pmHash(pmHash(pmHash(sd)+uint(ix))+uint(iy));
      bool nrm=in.gab.y>0.5;
      if(in.gab.z>0.5){
        rgb=in.color.rgb+in.param*float3(pmDeviate(base,0u,nrm),
            pmDeviate(base,1u,nrm),pmDeviate(base,2u,nrm));
      }else{
        rgb=in.color.rgb+in.param*pmDeviate(base,0u,nrm);
      }
      rgb=saturate(rgb);a=1.0;
    }
  }else{
    a=saturate(h.y-abs(p.y)+0.5);
  }
  // Where a shape covers nothing, nothing is written: it matters when blending is off.
  a=saturate(a);if(a<=0.0)discard_fragment();
  return float4(rgb,in.color.a*a);}
struct TU{float4 dst;float4 src;float4 tint;float2 size;float angle;float mono;};
struct TV{float4 p[[position]];float2 uv;float4 tint;uint mono[[flat]];};
vertex TV tvmain(uint vid[[vertex_id]],constant TU&u[[buffer(0)]]){
  float2 c[4]={float2(0,0),float2(1,0),float2(0,1),float2(1,1)};
  float2 f=c[vid];
  float2 ctr=(u.dst.xy+u.dst.zw)*0.5;
  float2 hs=(u.dst.zw-u.dst.xy)*0.5;
  float2 lo=(f*2.0-1.0)*hs;
  float ca=cos(u.angle),sa=sin(u.angle);
  float2 px=ctr+float2(lo.x*ca-lo.y*sa,lo.x*sa+lo.y*ca);
  TV o;o.p=float4(px.x/u.size.x*2.0-1.0,1.0-px.y/u.size.y*2.0,0,1);
  o.uv=mix(u.src.xy,u.src.zw,f);o.tint=u.tint;o.mono=uint(u.mono);return o;}
fragment float4 tfmain(TV in[[stage_in]],texture2d<float> t[[texture(0)]],sampler s[[sampler(0)]]){
  float4 v=t.sample(s,in.uv);
  if(in.mono==1u)v=float4(v.rrr,1.0);else if(in.mono==2u){if(v.r<=0.0)discard_fragment();v=float4(1.0,1.0,1.0,v.r);}
  // An offscreen window's colour is already multiplied by its alpha: the tint's alpha scales all of it.
  if(in.mono==3u)return float4(v.rgb*in.tint.rgb,v.a)*in.tint.a;
  return v*in.tint;}
struct EV{float4 p[[position]];};
vertex EV evmain(uint vid[[vertex_id]]){
  float2 c[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
  EV o;o.p=float4(c[vid],0,1);return o;}
struct EU{float4 gamma;uint mode;uint n;uint2 pad;};
fragment float4 efmain(EV in[[stage_in]],texture2d<float> t[[texture(0)]],texture2d<float> lut[[texture(1)]],
    constant EU&u[[buffer(0)]]){
  float3 c=saturate(t.read(uint2(in.p.xy)).rgb);
  if(u.mode==1u){
    c=pow(c,u.gamma.rgb);
  }else if(u.mode==2u){
    float3 x=c*float(u.n-1u);float3 lo=floor(x);float3 f=x-lo;
    uint3 a=uint3(lo);uint3 b=min(a+uint3(1u),uint3(u.n-1u));
    c=float3(mix(lut.read(uint2(a.r,0u)).r,lut.read(uint2(b.r,0u)).r,f.r),
             mix(lut.read(uint2(a.g,0u)).g,lut.read(uint2(b.g,0u)).g,f.g),
             mix(lut.read(uint2(a.b,0u)).b,lut.read(uint2(b.b,0u)).b,f.b));
  }
  return float4(c,1.0);}
// Procedural stimuli: geometry/aperture size and carrier scale are independent.
struct PU { float4 dst, mean, wave, noise, aperture, viewport, maskA, maskB; };
struct PV { float4 p[[position]]; float2 uv; };
vertex PV pvmain(uint vid[[vertex_id]],constant PU&u[[buffer(0)]]) {
    float2 c[4]={float2(0,0),float2(1,0),float2(0,1),float2(1,1)};
    float2 px=mix(u.dst.xy,u.dst.zw,c[vid]); PV o;
    o.p=float4(px.x/u.viewport.x*2-1,1-px.y/u.viewport.y*2,0,1);o.uv=c[vid];return o;
}
// Recipes are snapshotted uniforms, not full-size CPU images or GPU resources.
// edge is an inward raised-cosine transition. Hard edges use fragment derivatives
// for antialiasing in screen pixels, independent of carrier/noise sampling.
float pmMaskCoverage(float2 q, float4 a, float4 b) {
    float2 delta=q-b.yz;
    float radius=a.w, edge=b.x, coverage;
    if(a.x==1) coverage=exp(-dot(delta,delta)/(2*a.y*a.y));
    else {
        // Edge 0 is exactly hard: a pixel is in or out by where its centre is, so
        // two images that meet at the edge are never mixed.
        float r=length(delta);
        float outer=edge>0 ? .5-.5*cos(3.141592653589793*clamp((radius-r)/edge,0.0,1.0)) : float(r<=radius);
        float inner=1;
        if(a.x==2 && a.z>0) inner=edge>0 ? .5-.5*cos(3.141592653589793*clamp((r-a.z)/edge,0.0,1.0)) : float(r>=a.z);
        coverage=outer*inner;
    }
    return b.w>0 ? 1-coverage : coverage;
}
fragment float4 pfmain(PV in[[stage_in]],constant PU&u[[buffer(0)]],texture2d<float> mask[[texture(0)]],sampler s[[sampler(0)]]) {
    float2 extent=u.dst.zw-u.dst.xy;
    float2 p=(in.uv-.5)*extent;
    float2 q=2*in.uv-1;
    float a=mask.sample(s,in.uv).r;
    if(u.aperture.y==1) a*=float(length(q)<=1);     // hard, as an edge-0 mask
    else if(u.aperture.y==2) a*=exp(-dot(q,q)/(2*u.aperture.z*u.aperture.z));
    if(u.maskA.x>=0) a*=pmMaskCoverage(q,u.maskA,u.maskB);
    if(a<=0) discard_fragment();
    float3 v;
    if(u.aperture.x==0) {
        float d=p.x*cos(u.wave.y)+p.y*sin(u.wave.y);
        v=float3(cos(6.28318530718*u.wave.x*d+u.wave.z));
    } else {
        uint2 xy=uint2(floor(max(in.uv*extent,float2(0))/u.noise.y));
        uint base=pmHash(pmHash(pmHash(uint(u.noise.x))+xy.x)+xy.y);
        v=float3(pmDeviate(base,0,u.noise.w>.5));
        if(u.noise.z>.5) v=float3(v.x,pmDeviate(base,1,u.noise.w>.5),pmDeviate(base,2,u.noise.w>.5));
    }
    return float4(saturate(u.mean.rgb*(1+u.wave.w*v)),u.mean.a*a);
}

// Still-image source sampling and destination-local analytic/image coverage.
struct MU {float4 dst,src,tint;float2 size;float angle,mono;float4 maskA,maskB;};
struct MV {float4 p [[position]];float2 uv,maskUV;};
vertex MV mvmain(uint vid [[vertex_id]],constant MU &u [[buffer(0)]]) {
    float2 f=float2(vid&1,vid>>1),local=(f*2-1)*(u.dst.zw-u.dst.xy)*.5;
    float ca=cos(u.angle),sa=sin(u.angle);
    float2 pixel=(u.dst.xy+u.dst.zw)*.5+float2(ca*local.x-sa*local.y,sa*local.x+ca*local.y);
    MV o;o.p=float4(pixel.x/u.size.x*2-1,1-pixel.y/u.size.y*2,0,1);
    o.uv=mix(u.src.xy,u.src.zw,f);o.maskUV=f;return o;
}
fragment float4 mfmain(MV in [[stage_in]],constant MU &u [[buffer(0)]],
                       texture2d<float> source [[texture(0)]],texture2d<float> mask [[texture(1)]],
                       sampler imageSampler [[sampler(0)]],sampler maskSampler [[sampler(1)]]) {
    float coverage=mask.sample(maskSampler,in.maskUV).r;
    if(u.maskA.x>=0)coverage*=pmMaskCoverage(in.maskUV*2-1,u.maskA,u.maskB);
    if(coverage<=0)discard_fragment();
    float4 v=source.sample(imageSampler,in.uv);
    if(u.mono==1)v=float4(v.rrr,1);
    if(u.mono==3)return float4(v.rgb*u.tint.rgb,v.a)*(u.tint.a*coverage);
    return float4(v.rgb*u.tint.rgb,v.a*u.tint.a*coverage);
}
