// ORBITAL / original analytic worlds. D3D11 ps_5_0, no resources.
// gTune = (floor variant 0..2, animation rate 0..2, emission 0..2, tilt radians).
// Zero rate still moves. gTime.x is seconds; camera is never replaced.
// Suggested eye / at / vertical FOV degrees / camera speed / tune:
// 0: (0,3.8,-12) / (0,0,0) / 44 / TRACK .35 / (0,1,1,.22), ONE flyby.
// 1: (0,2.9,-13) / (0,0,0) / 46 / ORBIT .07 / (1,.8,1,-.18).
// 2: (0,1,-11) / (0,0,0) / 48 / TRACK .30 / (2,1,1,.15).
// Bounds centered at origin: 0 sphere R=5.7 (planet R=2.6),
// 1 sphere R=6.5 (opaque core R=1.48); 2 sphere R=5.3.
// Keep camera outside those bounds; slow track/orbit gives strong parallax.
// Transparent sheets composite in ray order, behind nearest opaque surface.
// Depth is nearest visible layer at .05/viewZ, sky is infinite (zero).

cbuffer Scene : register(b0)
{
    float4 gTime;
    float4 gCam;
    float4 gDir;
    float4 gTune;
    float4 gSync;
    float4 gVoice;
};
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
struct PSOut { float4 color : SV_Target; float depth : SV_Depth; };
static const float PI = 3.14159265359;
static const float FAR_T = 1e5;
static const float3 CYAN = float3(.12,.78,1.0);
static const float3 AMBER = float3(1.0,.43,.105);
static const float3 PINK = float3(.78,.095,.45);
static const float3 SUN = float3(-.57735,.57735,-.57735);

float hash31(float3 p)
{
    p = frac(p * .1031);
    p += dot(p, p.yzx + 33.33);
    return frac((p.x + p.y) * p.z);
}
float noise3(float3 p)
{
    float3 b = floor(p), f = frac(p);
    f = f*f*(3.0-2.0*f);
    return lerp(lerp(lerp(hash31(b), hash31(b+float3(1,0,0)), f.x),
                     lerp(hash31(b+float3(0,1,0)), hash31(b+float3(1,1,0)), f.x), f.y),
                lerp(lerp(hash31(b+float3(0,0,1)), hash31(b+float3(1,0,1)), f.x),
                     lerp(hash31(b+float3(0,1,1)), hash31(b+1.0), f.x), f.y), f.z);
}
float2 rotate2(float2 p, float a)
{
    float s, c; sincos(a,s,c);
    return float2(c*p.x-s*p.y, s*p.x+c*p.y);
}
float3 localPoint(float3 p)
{
    p.xy = rotate2(p.xy, -.32-clamp(gTune.w,-.8,.8));
    return p;
}
// Analytic interval also handles a camera inside a sphere.
float2 sphere(float3 ro, float3 rd, float radius)
{
    float b = dot(ro,rd), h = b*b-dot(ro,ro)+radius*radius;
    if (h < 0.0) return float2(FAR_T,-FAR_T);
    h = sqrt(h);
    return float2(-b-h,-b+h);
}
float firstHit(float2 hit)
{
    return hit.x > .001 ? hit.x : (hit.y > .001 ? hit.y : FAR_T);
}
// World-fixed far stars on cube faces; filtered footprints, no screen noise.
float3 sky(float3 d, float footprint)
{
    float3 a = abs(d);
    float2 uv; float face;
    if (a.x >= a.y && a.x >= a.z) { uv=d.yz/a.x; face=d.x>0?1.0:2.0; }
    else if (a.y >= a.z) { uv=d.xz/a.y; face=d.y>0?3.0:4.0; }
    else { uv=d.xy/a.z; face=d.z>0?5.0:6.0; }
    float2 st = uv*125.0, cell=floor(st), f=frac(st);
    float h=hash31(float3(cell,face));
    float2 center=.25+.5*float2(hash31(float3(cell,face+12.0)),hash31(float3(cell,face+31.0)));
    float w=max(.035,footprint*125.0);
    float star=exp(-dot(f-center,f-center)/(w*w)) * min(1.0,.008/(w*w));
    star *= smoothstep(.986,.999,h);
    float dust=pow(saturate(1.0-abs(d.y+.22*d.x-.13)*3.0),6.0);
    float n=noise3(d*7.0);
    return float3(.004,.007,.016) + dust*n*float3(.021,.012,.034)
         + lerp(float3(.42,.68,1.0),float3(1.0,.7,.4),h)*star*1.8;
}
float annulus(float r, float lo, float hi, float aa)
{
    return smoothstep(lo-aa,lo+aa,r)*(1.0-smoothstep(hi-aa,hi+aa,r));
}
// Fade frequencies beyond the ray footprint before evaluating narrow grooves.
float wave(float phase, float frequency, float width)
{
    return .5+.5*sin(phase)*saturate(1.0-frequency*width*.32);
}
float ringDensity(float r, float width)
{
    float bands=.38+.28*wave(r*39.0,39.0,width)+.30*wave(r*113.0,113.0,width);
    float gap=1.0-.94*exp(-pow((r-4.23)/max(.055,width),2.0));
    return bands*gap*annulus(r,3.22,5.55,max(.012,width));
}
float3 planet(float3 p, float3 rd, float time, float px)
{
    float3 n=p/2.6, q=n;
    q.xz=rotate2(q.xz,time*.095);
    float turbulence=noise3(q*8.0)+.38*noise3(q*23.0);
    float lat=q.y*33.0+(turbulence-.65)*3.0;
    float bands=.5+.5*sin(lat);
    float fine=wave(lat*3.6+q.x*5.0,120.0,px);
    float3 alb=lerp(float3(.12,.22,.31),float3(.83,.49,.22),bands);
    alb=lerp(alb,float3(.76,.72,.56),.32*fine);
    // A local oval storm travels with the rotating atmosphere.
    float2 storm=float2(q.x+.37,(q.y+.19)*2.8);
    float vortex=exp(-dot(storm,storm)*95.0)*smoothstep(.15,.6,-q.z);
    alb=lerp(alb,float3(.70,.16,.095),vortex*.85);
    float light=saturate(dot(n,SUN));
    float shadow=1.0;
    float ts=-p.y/SUN.y;
    if (ts>0.0) shadow=1.0-.83*ringDensity(length((p+SUN*ts).xz),.02);
    float rim=pow(1.0-saturate(dot(n,-rd)),3.5);
    float3 col=alb*(.10+.94*light*shadow);
    col+=CYAN*rim*(.12+.48*light)*(.97+.03*saturate(gSync.y));
    return col;
}
// Three differently oriented sheets; true plane intersections, no screen halos.
float3 sheetNormal(int id)
{
    if (id==0) return float3(0,1,0);
    if (id==1) return normalize(float3(.13,.24,1.0));
    return normalize(float3(-.64,1.0,.31));
}
float4 sheet(float3 p, float3 rd, int id, int mode, float time, float px)
{
    float3 normal=sheetNormal(id);
    float3 u=normalize(cross(normal,float3(1,0,0)));
    float3 v=cross(normal,u);
    float2 q=float2(dot(p,u),dot(p,v));
    float r=length(q), angle=atan2(q.y,q.x);
    float width=max(.008,px/max(.12,abs(dot(rd,normal))));
    float4 result=float4(0,0,0,0);
    if (mode==0) {
        float density=ringDensity(r,width);
        float3 c=lerp(float3(.22,.40,.48),float3(.85,.60,.31),wave(r*9.0,9.0,width));
        float shadow=firstHit(sphere(p+SUN*.01,SUN,2.6))<FAR_T ? .14:1.0;
        c*=shadow*(.52+.28*abs(dot(rd,normal)));
        c+=CYAN*.12*pow(wave(r*29.0,29.0,width),6.0);
        float alpha=1.0-exp(-density*.95/max(.18,abs(dot(rd,normal))));
        result=float4(c,alpha);
    } else {
        float lo=id==0?1.80:(id==1?1.58:3.7);
        float hi=id==0?5.05:(id==1?2.04:5.65);
        float mask=annulus(r,lo,hi,width);
        float spiral=angle*3.0-r*7.0+time*(1.7+float(id)*.37);
        float thread=pow(wave(r*75.0+sin(spiral)*1.2,80.0,width),9.0);
        float flow=.58+.42*sin(spiral);
        float temperature=saturate((r-lo)/(hi-lo));
        float3 c=lerp(AMBER,CYAN,temperature);
        if (id==1) c=lerp(AMBER,float3(1.0,.83,.48),.55);
        if (id==2) c=lerp(PINK,CYAN,.25+.25*sin(angle*2.0+time*.3));
        float gain=(.65+1.6*thread+.36*flow)*(1.0+.06*saturate(gVoice.y));
        float alpha=mask*(id==1?.90:(id==2?.48:.77));
        result=float4(c*gain,alpha);
    }
    return result;
}
// Finite helical strands, tapered ends, independently traveling waves.
// The .38 march factor bounds the slope of this warped tube field.
float2 filaments(float3 p, float time)
{
    float y=clamp(p.y,-3.8,3.8), taper=sqrt(max(.03,1.0-y*y/17.0));
    float best=FAR_T, material=0.0;
    [unroll] for (int k=0;k<5;k++) {
        float fk=float(k), phase=fk*(2.0*PI/5.0);
        float a=phase+y*.67+time*.24+.20*sin(y*1.3-time*.65+phase);
        float radius=(1.22+.28*sin(y*1.15+phase+time*.31))*taper;
        float2 center=radius*float2(cos(a),sin(a));
        center+=float2(.30*sin(y*.78+time*.28),.18*cos(y*.85-time*.32));
        float tube=.072+.035*taper;
        float d=length(float3(p.x-center.x,p.y-y,p.z-center.y))-tube;
        if (d<best) { best=d; material=fk; }
    }
    // A thin central spline, not a spherical core: asymmetric sculpture.
    float2 spine=float2(.30*sin(y*.78+time*.28),.18*cos(y*.85-time*.32));
    float d=length(float3(p.x-spine.x,p.y-y,p.z-spine.y))-.047;
    if (d<best) { best=d; material=5.0; }
    return float2(best,material);
}
float3 filamentColor(float3 p, float id, float time)
{
    float hue=.5+.5*sin(id*1.8+p.y*.72-time*.52);
    float3 c=lerp(CYAN,PINK,smoothstep(.28,.9,hue));
    c=lerp(c,AMBER,pow(.5+.5*sin(p.y*1.1+id*2.3+time*.43),8.0)*.85);
    float pulse=pow(.5+.5*sin(p.y*6.0-time*3.2+id*1.7),12.0);
    return c*(.58+1.05*pulse)*(1.0+.06*saturate(gSync.x));
}
PSOut main(VSOut input)
{
    PSOut o;
    float3 fw=normalize(gDir.xyz);
    float3 worldUp=abs(fw.y)>.98?float3(0,0,1):float3(0,1,0);
    float3 right=normalize(cross(worldUp,fw)), up=cross(fw,right);
    float2 uv=(input.uv*2.0-1.0)*float2(gTime.w,-1.0);
    uv=rotate2(uv,gDir.w);
    float3 worldRay=normalize(fw+(right*uv.x+up*uv.y)*gCam.w);
    float footprint=max(length(ddx(worldRay)),length(ddy(worldRay)));
    float3 ro=localPoint(gCam.xyz), rd=localPoint(worldRay);
    int mode=(int)clamp(floor(gTune.x),0.0,2.0);
    float time=gTime.x*(.55+.45*clamp(gTune.y,0.0,2.0));
    float exposure=.65+.35*clamp(gTune.z,0.0,2.0);
    float3 col=sky(worldRay,footprint);
    float nearest=FAR_T;

    [branch] if (mode<2) {
        float radius=mode==0?2.6:1.48;
        float t=firstHit(sphere(ro,rd,radius));
        if (t<FAR_T) {
            nearest=t;
            float3 p=ro+rd*t;
            col=mode==0?planet(p,rd,time,footprint*t):float3(.001,.002,.004);
        }
        // Ellipsoidal fragments on real orbital trajectories; analytic occlusion.
        [loop] for (int j=0;j<22;j++) {
            if (mode==0 && j>=5) break;
            float h=hash31(float3(float(j),7.0,2.0));
            float orbit=mode==0?5.55:(3.0+2.85*h);
            float a=float(j)*2.39996+time*(.085+.06*h);
            float3 center=float3(cos(a)*orbit,(mode==0?.11:1.15)*sin(a*2.0+float(j)),sin(a)*orbit);
            float size=(mode==0?.035:.065)+h*h*(mode==0?.075:.15);
            float3 axes=float3(size,size*(.55+.45*h),size*.76);
            float3 er=(ro-center)/axes, ed=rd/axes;
            float len=length(ed);
            float hit=firstHit(sphere(er,ed/len,1.0));
            t=hit<FAR_T?hit/len:FAR_T;
            if (t<nearest) {
                nearest=t;
                float3 p=ro+rd*t;
                float3 n=normalize((p-center)/(axes*axes));
                float light=saturate(dot(n,SUN));
                col=lerp(float3(.08,.13,.18),float3(.43,.33,.25),h)*(.3+light);
                if (mode==1) {
                    float inner=saturate(dot(n,-normalize(center)));
                    col+=AMBER*inner*.42+CYAN*pow(1.0-saturate(dot(n,-rd)),3.0)*.18;
                }
            }
        }
        float opaque=nearest;
        float distances[3]; int ids[3];
        [unroll] for (int k=0;k<3;k++) {
            float3 normal=sheetNormal(k);
            float denom=dot(rd,normal);
            float hit=abs(denom)>1e-5?-dot(ro,normal)/denom:FAR_T;
            distances[k]=(hit>.001 && hit<opaque && (mode==1 || k==0))?hit:FAR_T;
            ids[k]=k;
        }
        // Fixed three-element sorting network, far to near (invalid first).
        [unroll] for (int a=0;a<2;a++) {
            [unroll] for (int b=0;b<2;b++) {
                if (distances[b]<distances[b+1]) {
                    float swapT=distances[b]; distances[b]=distances[b+1]; distances[b+1]=swapT;
                    int swapID=ids[b]; ids[b]=ids[b+1]; ids[b+1]=swapID;
                }
            }
        }
        [unroll] for (int layer=0;layer<3;layer++) {
            t=distances[layer];
            if (t<FAR_T) {
                float4 ring=sheet(ro+rd*t,rd,ids[layer],mode,time,footprint*t);
                col=lerp(col,ring.rgb,ring.a);
                if (ring.a>.02) nearest=min(nearest,t);
            }
        }
        // Analytic atmosphere shell: only its segment in FRONT of opaque matter.
        if (mode==0) {
            float2 atmo=sphere(ro,rd,2.66);
            float start=max(.001,atmo.x), end=min(opaque,atmo.y);
            if (end>start) {
                float mid=(start+end)*.5;
                float3 p=ro+rd*mid;
                float light=.12+.88*saturate(dot(normalize(p),SUN));
                // A foreground ring attenuates the atmosphere as well.
                float visibility=1.0;
                float planeT=abs(rd.y)>1e-5?-ro.y/rd.y:FAR_T;
                if (planeT>0.0 && planeT<start) visibility=1.0-sheet(ro+rd*planeT,rd,0,0,time,footprint*planeT).a;
                col+=CYAN*(1.0-exp(-(end-start)*2.5))*light*.23*visibility;
                nearest=min(nearest,start);
            }
        }
    } else {
        float2 bound=sphere(ro,rd,5.3);
        float t=max(.001,bound.x), end=bound.y;
        float3 glow=0.0;
        [loop] for (int step=0;step<112;step++) {
            if (t>end) break;
            float3 p=ro+rd*t;
            float2 field=filaments(p,time);
            float eps=max(.0015,footprint*t*.42);
            if (field.x<eps) {
                float e=max(.002,eps*.6);
                float3 n=normalize(float3(
                    filaments(p+float3(e,0,0),time).x-filaments(p-float3(e,0,0),time).x,
                    filaments(p+float3(0,e,0),time).x-filaments(p-float3(0,e,0),time).x,
                    filaments(p+float3(0,0,e),time).x-filaments(p-float3(0,0,e),time).x));
                float facing=saturate(dot(n,-rd));
                float3 c=filamentColor(p,field.y,time);
                col=c*(.55+.45*facing)+float3(.35,.52,.58)*pow(facing,18.0)*.45;
                nearest=t;
                break;
            }
            float stride=max(eps*.4,field.x*.38);
            // Compact in-world corona, integrated only up to the first surface.
            glow+=filamentColor(p,field.y,time)*exp(-max(0.0,field.x)*36.0)*min(stride,.12)*1.7;
            t+=stride;
        }
        col+=min(glow,float3(.24,.24,.24));
    }
    o.color=float4(max(col,0.0)*exposure*gTime.z,1.0);
    float viewZ=nearest*max(dot(worldRay,fw),1e-4);
    o.depth=nearest<FAR_T?saturate(.05/max(viewZ,.05)):0.0;
    return o;
}
