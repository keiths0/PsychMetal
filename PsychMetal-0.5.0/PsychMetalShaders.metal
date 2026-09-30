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
      float d=p.x*cos(in.gab.y)-p.y*sin(in.gab.y);
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
  return float4(rgb,in.color.a*saturate(a));}
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
  float4 v=t.sample(s,in.uv);if(in.mono)v=float4(v.rrr,1.0);return v*in.tint;}