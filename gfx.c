/* ==========================================================================
   C R T k a f a   -   D 3 D 1 1   E N G I N E
   --------------------------------------------------------------------------
   Single translation unit, no C runtime (/NODEFAULTLIB, /ENTRY:entry).
   The only DLLs are ones that ship with Windows, and d3d11.dll is loaded by
   hand rather than imported, so a machine without it gets our message
   instead of the loader's.

   Scene geometry is a pixel shader and the edit is a table. A new look is a
   .hlsl file plus a row in shots.h - not a new rasteriser path in C, and not
   another term added to a camera integral.
   ========================================================================== */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <xmmintrin.h>
#include <string.h>

/* --------------------------------------------------------------------------
   no-CRT glue
   -------------------------------------------------------------------------- */
int _fltused = 1;

#pragma function(memset)
void *memset(void *d, int c, size_t n)
{
    unsigned char *p = (unsigned char *)d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

#pragma function(memcpy)
void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *a = (unsigned char *)d;
    const unsigned char *b = (const unsigned char *)s;
    while (n--) *a++ = *b++;
    return d;
}

/* /O2 emits calls to this for some struct copies even though nothing in the
   source says memmove. Without it the link fails with an unresolved symbol
   that points at no line of code - and without the pragma the compiler
   refuses to let us define it at all (C2169). */
#pragma function(memmove)
void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *a = (unsigned char *)d;
    const unsigned char *b = (const unsigned char *)s;
    if (a == b || n == 0) return d;
    if (a < b) { while (n--) *a++ = *b++; }
    else       { a += n; b += n; while (n--) *--a = *--b; }
    return d;
}

/* --------------------------------------------------------------------------
   maths, without libm
   -------------------------------------------------------------------------- */
#define PI_  3.14159265359f
#define TAU_ 6.28318530718f

static float fsin_(float x)
{
    float y, z;
    x -= TAU_ * (float)(int)(x / TAU_);
    if (x >  PI_) x -= TAU_;
    if (x < -PI_) x += TAU_;
    /* Fold before evaluating. The former seventh-order polynomial evaluated
       at +/-pi jumped by 0.1504 every wrap, including inside audio voices. */
    if (x >  PI_ * 0.5f) x =  PI_ - x;
    if (x < -PI_ * 0.5f) x = -PI_ - x;
    z = x * x;
    y = x * (1.0f + z * (-0.166666667f + z * (0.00833333333f + z *
              (-0.000198412698f + z * (2.75573192e-6f - z * 2.50521084e-8f)))));
    return y;
}
static float fcos_(float x) { return fsin_(x + PI_ * 0.5f); }
static float fsqrt_(float x)
{
    return _mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(x)));
}

/* The synth and camera use this folded polynomial. The isolated audio harness
   must select its D3D backend to match this implementation, not the old LUT. */
#define lsin fsin_

#include "song_data.h"        /* the baked note tables */
#include "synth.h"            /* and the synth that reads them */
#include "shaders.h"          /* fxc /Fh output, built by buildgfx.bat */
#include "shots.h"            /* the edit */
#include "cats_mesh.h"        /* the cat, 24 baked frames of a run cycle */
#include "tardis_mesh.h"      /* a single-frame, distant blue-box callback */
#include "c64_font.h"         /* the boot screen, the author's own words */

/* --------------------------------------------------------------------------
   sizes
   -------------------------------------------------------------------------- */
#define VH       360          /* virtual height, fixed. width follows aspect */
#define VW_MIN   480          /* 4:3                                          */
#define VW_MAX   1280         /* 32:9                                         */

/* One row of the song, in seconds, derived from the synth's own constants so
   there is a single source of truth. Better still, the clock below does not
   use it at all in the normal case: the row index comes from the number of
   samples the sound card has actually played. */
#define SEC_PER_ROW ((float)SPR / (float)SRATE)

static int g_vw = 640, g_vh = VH;
static int g_ow = 1280, g_oh = 720;

/* --------------------------------------------------------------------------
   d3d
   -------------------------------------------------------------------------- */
static ID3D11Device           *g_dev;
static ID3D11DeviceContext    *g_ctx;
static IDXGISwapChain1        *g_sc;
static ID3D11RenderTargetView *g_backRTV;

/* Two scene targets: a dissolve renders the outgoing and the incoming shot
   in the same frame and the post pass mixes them. */
static ID3D11Texture2D          *g_sceneTex[2];
static ID3D11RenderTargetView   *g_sceneRTV[2];
static ID3D11ShaderResourceView *g_sceneSRV[2];

static ID3D11Texture2D        *g_depthTex;
static ID3D11DepthStencilView *g_depthDSV;
static ID3D11DepthStencilState *g_dsSdf;    /* the background always wins */
static ID3D11DepthStencilState *g_dsMesh;   /* meshes test, reversed Z    */

static ID3D11ShaderResourceView *g_catPos;  /* over g_rcatV, no copy */
static ID3D11ShaderResourceView *g_catIdx;  /* over g_rcatI          */
static ID3D11ShaderResourceView *g_tarPos;  /* over g_tarV           */
static ID3D11ShaderResourceView *g_tarIdx;  /* over g_tarI           */
static ID3D11ShaderResourceView *g_tarColor;
static ID3D11ShaderResourceView *g_spinPos, *g_spinIdx, *g_spinColor;
static ID3D11RasterizerState    *g_rsRigid; /* imported meshes, two-sided */
static ID3D11VertexShader       *g_vsMesh;
static ID3D11PixelShader        *g_psMesh;
static ID3D11Buffer             *g_cbMesh;
static ID3D11Buffer             *g_cbFont;   /* uploaded once, never again */

/* Bloom: two half resolution targets, ping-ponged through a bright pass and
   two blur passes. Half res and one level only - at 180 lines a second level
   stopped being a glow and started being fog. */
static ID3D11Texture2D          *g_bloomTex[2];
static ID3D11RenderTargetView   *g_bloomRTV[2];
static ID3D11ShaderResourceView *g_bloomSRV[2];
static ID3D11PixelShader        *g_psBloom;
static ID3D11Buffer             *g_cbBloom;
static int                       g_bw, g_bh;

typedef struct { float step[4], param[4]; } BloomCB;

typedef struct { float model[4], anim[4], misc[4]; } MeshCB;

static ID3D11VertexShader *g_vsFull;
static ID3D11PixelShader  *g_psScene[SC_COUNT];
static ID3D11PixelShader  *g_psPost;
static ID3D11Buffer       *g_cbScene;
static ID3D11Buffer       *g_cbPost;
static ID3D11SamplerState *g_sampPoint;
static ID3D11SamplerState *g_sampLinear;

/* Unbinding takes a real array of nulls. Passing NULL for the array is not
   how you clear a slot, and the scene texture stays bound as an input while
   we try to render into it - which D3D resolves by giving you a black frame
   and a warning nobody sees in a build with no debug layer. */
static ID3D11ShaderResourceView *const g_nullSRV[3] = { 0, 0, 0 };
static ID3D11RenderTargetView   *const g_nullRTV[1] = { 0 };

/* gSync.xyz are the three bands, gSync.w the master peak; gVoice carries
   the four per-instrument envelopes a scene might want to single out. */
typedef struct {
    float t[4], cam[4], dir[4], tune[4];
    float sync[4], voice[4], caption[4];
} SceneCB;
typedef struct {
    float res[4], crt[4], grade[4], fx[4];
    float ramp[4][4];   /* the section palette, already crossfaded */
    float tone[4];      /* x hue kept, y quantiser steps           */
} PostCB;

/* --------------------------------------------------------------------------
   state
   -------------------------------------------------------------------------- */
static HWND            g_hwnd;
static int             g_full     = 0;
static int             g_paused   = 0;
static int             g_running  = 1;
static int             g_sizing   = 0;
static int             g_warp     = 0;
static WINDOWPLACEMENT g_place    = { sizeof(WINDOWPLACEMENT) };
static LONG_PTR        g_style    = 0;
static double          g_row      = 0.0;   /* the clock, in song rows */
static int             g_wasPaused = 0;
static __int64         g_lastPlayed = -1;  /* to notice the device going away */
static int             g_audioStall = 0;
static LARGE_INTEGER   g_qpcFreq, g_qpcLast;

static void fatal(const WCHAR *msg)
{
    MessageBoxW(0, msg, L"CRTkafa", MB_OK | MB_ICONERROR);
    ExitProcess(1);
}

/* --------------------------------------------------------------------------
   device
   --------------------------------------------------------------------------
   d3d11.dll is resolved at runtime on purpose. As a normal import, a machine
   without it would never reach our code at all: the loader would put up "The
   code execution cannot proceed because d3d11.dll was not found" and quit.
   Loading it by hand is the only way our own message ever appears. dxgi.dll
   needs no such care - we reach the factory through the device's own
   adapter, so we never call a dxgi export directly.
   -------------------------------------------------------------------------- */
typedef HRESULT (WINAPI *PFN_D3D11CreateDevice_)(
    IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
    const D3D_FEATURE_LEVEL *, UINT, UINT,
    ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);

static int createDevice(void)
{
    static const D3D_FEATURE_LEVEL want[] = {
        D3D_FEATURE_LEVEL_11_0
    };
    PFN_D3D11CreateDevice_ create;
    D3D_FEATURE_LEVEL got = (D3D_FEATURE_LEVEL)0;
    HMODULE lib;
    HRESULT hr;
    UINT flags = D3D11_CREATE_DEVICE_SINGLETHREADED;

    lib = LoadLibraryA("d3d11.dll");
    if (!lib)
        fatal(L"This demo needs Direct3D 11.\n\n"
              L"d3d11.dll was not found. This build requires Windows 10 or "
              L"newer. Repair Windows system components and update your graphics driver.");

    create = (PFN_D3D11CreateDevice_)GetProcAddress(lib, "D3D11CreateDevice");
    if (!create)
        fatal(L"This demo needs Direct3D 11.\n\n"
              L"d3d11.dll is present but does not export D3D11CreateDevice.");

    hr = create(0, D3D_DRIVER_TYPE_HARDWARE, 0, flags,
                want, 1, D3D11_SDK_VERSION, &g_dev, &got, &g_ctx);

    if (hr < 0) {
        /* No usable GPU. WARP is the software rasteriser that ships with
           Windows: feature level 11_0, and slow enough that the virtual
           resolution is halved to keep it moving. Seeing the demo badly
           beats not seeing it. */
        hr = create(0, D3D_DRIVER_TYPE_WARP, 0, flags,
                    want, 1, D3D11_SDK_VERSION, &g_dev, &got, &g_ctx);
        if (hr < 0)
            fatal(L"No Direct3D 11 capable device was found.\n\n"
                  L"Updating the graphics driver usually fixes this. The "
                  L"software fallback could not be created either.");
        g_warp = 1;
    }
    if (got < D3D_FEATURE_LEVEL_11_0)
        fatal(L"This device is below Direct3D feature level 11.0 and cannot "
              L"run the demo.");
    return 1;
}

/* --------------------------------------------------------------------------
   swap chain
   -------------------------------------------------------------------------- */
static int createSwapChain(HWND hwnd)
{
    IDXGIDevice1  *dxdev = 0;
    IDXGIAdapter  *adap  = 0;
    IDXGIFactory2 *fac   = 0;
    DXGI_SWAP_CHAIN_DESC1 sd;
    RECT rc;
    HRESULT hr;

    GetClientRect(hwnd, &rc);
    g_ow = rc.right - rc.left;  if (g_ow < 16) g_ow = 16;
    g_oh = rc.bottom - rc.top;  if (g_oh < 16) g_oh = 16;

    if (ID3D11Device_QueryInterface(g_dev, &IID_IDXGIDevice1, (void **)&dxdev) < 0)
        return 0;
    if (IDXGIDevice1_GetAdapter(dxdev, &adap) < 0) return 0;
    if (IDXGIAdapter_GetParent(adap, &IID_IDXGIFactory2, (void **)&fac) < 0)
        return 0;

    memset(&sd, 0, sizeof(sd));
    sd.Width       = (UINT)g_ow;
    sd.Height      = (UINT)g_oh;
    sd.Format      = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.Scaling     = DXGI_SCALING_STRETCH;
    /* Flip model. The combined D3D11CreateDeviceAndSwapChain call can only
       produce the old blt model, where DWM copies the backbuffer every frame
       - extra latency, extra bandwidth, and borderless fullscreen never gets
       independent flip. That is why the device and the chain are separate. */
    sd.SwapEffect  = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.AlphaMode   = DXGI_ALPHA_MODE_IGNORE;

    hr = IDXGIFactory2_CreateSwapChainForHwnd(fac, (IUnknown *)g_dev, hwnd,
                                              &sd, 0, 0, &g_sc);

    /* DXGI installs its own hook on our window and will try to handle
       Alt+Enter itself, fighting the F key and flipping display modes behind
       our back. This tells it to keep its hands off. */
    IDXGIFactory2_MakeWindowAssociation(fac, hwnd,
        DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);

    IDXGIFactory2_Release(fac);
    IDXGIAdapter_Release(adap);
    IDXGIDevice1_Release(dxdev);
    return hr >= 0;
}

static void releaseBackbuffer(void)
{
    if (g_backRTV) { ID3D11RenderTargetView_Release(g_backRTV); g_backRTV = 0; }
}

static int createBackbuffer(void)
{
    ID3D11Texture2D *tex = 0;
    HRESULT hr;
    if (IDXGISwapChain1_GetBuffer(g_sc, 0, &IID_ID3D11Texture2D, (void **)&tex) < 0)
        return 0;
    hr = ID3D11Device_CreateRenderTargetView(g_dev, (ID3D11Resource *)tex, 0,
                                             &g_backRTV);
    /* GetBuffer hands us a reference we own. Holding it is what makes the
       next ResizeBuffers fail with DXGI_ERROR_INVALID_CALL, and that failure
       is the classic "resizing the window breaks everything" bug. */
    ID3D11Texture2D_Release(tex);
    return hr >= 0;
}

/* --------------------------------------------------------------------------
   the low resolution scene targets
   --------------------------------------------------------------------------
   Fixed height, width from the aspect ratio: the camera widens on an
   ultrawide instead of the picture being letterboxed. The chunky pixels are
   not a compromise, they are the look - ordered dither and scanlines only
   read as themselves when a virtual pixel is several real ones.
   -------------------------------------------------------------------------- */
static void releaseSceneTargets(void)
{
    int i;
    for (i = 0; i < 2; i++) {
        if (g_sceneSRV[i]) { ID3D11ShaderResourceView_Release(g_sceneSRV[i]); g_sceneSRV[i] = 0; }
        if (g_sceneRTV[i]) { ID3D11RenderTargetView_Release(g_sceneRTV[i]);   g_sceneRTV[i] = 0; }
        if (g_sceneTex[i]) { ID3D11Texture2D_Release(g_sceneTex[i]);          g_sceneTex[i] = 0; }
    }
    for (i = 0; i < 2; i++) {
        if (g_bloomSRV[i]) { ID3D11ShaderResourceView_Release(g_bloomSRV[i]); g_bloomSRV[i] = 0; }
        if (g_bloomRTV[i]) { ID3D11RenderTargetView_Release(g_bloomRTV[i]);   g_bloomRTV[i] = 0; }
        if (g_bloomTex[i]) { ID3D11Texture2D_Release(g_bloomTex[i]);          g_bloomTex[i] = 0; }
    }
    if (g_depthDSV) { ID3D11DepthStencilView_Release(g_depthDSV); g_depthDSV = 0; }
    if (g_depthTex) { ID3D11Texture2D_Release(g_depthTex);        g_depthTex = 0; }
}

static int createSceneTargets(int ow, int oh)
{
    D3D11_TEXTURE2D_DESC td;
    int w, i, lo;

    g_vh = g_warp ? VH / 2 : VH;
    lo   = g_warp ? VW_MIN / 2 : VW_MIN;
    w = (int)(((float)g_vh * (float)ow) / (float)oh + 0.5f);
    if (w < lo)     w = lo;
    if (w > VW_MAX) w = VW_MAX;
    g_vw = w & ~1;

    releaseSceneTargets();

    memset(&td, 0, sizeof(td));
    td.Width  = (UINT)g_vw;
    td.Height = (UINT)g_vh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;   /* the scene is HDR */
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;

    for (i = 0; i < 2; i++) {
        if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &g_sceneTex[i]) < 0) return 0;
        if (ID3D11Device_CreateRenderTargetView(g_dev,
                (ID3D11Resource *)g_sceneTex[i], 0, &g_sceneRTV[i]) < 0) return 0;
        if (ID3D11Device_CreateShaderResourceView(g_dev,
                (ID3D11Resource *)g_sceneTex[i], 0, &g_sceneSRV[i]) < 0) return 0;
    }

    /* Depth, so a mesh and the distance field behind it can occlude each
       other. It follows the aspect-driven resize like everything else. */
    memset(&td, 0, sizeof(td));
    td.Width  = (UINT)g_vw;
    td.Height = (UINT)g_vh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_D32_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &g_depthTex) < 0) return 0;
    if (ID3D11Device_CreateDepthStencilView(g_dev, (ID3D11Resource *)g_depthTex,
                                            0, &g_depthDSV) < 0) return 0;

    g_bw = g_vw / 2; g_bh = g_vh / 2;
    memset(&td, 0, sizeof(td));
    td.Width  = (UINT)g_bw;
    td.Height = (UINT)g_bh;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    for (i = 0; i < 2; i++) {
        if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &g_bloomTex[i]) < 0) return 0;
        if (ID3D11Device_CreateRenderTargetView(g_dev,
                (ID3D11Resource *)g_bloomTex[i], 0, &g_bloomRTV[i]) < 0) return 0;
        if (ID3D11Device_CreateShaderResourceView(g_dev,
                (ID3D11Resource *)g_bloomTex[i], 0, &g_bloomSRV[i]) < 0) return 0;
    }
    return 1;
}

/* --------------------------------------------------------------------------
   pipeline objects
   -------------------------------------------------------------------------- */
/* An immutable typed buffer laid straight over a const array in a header.
   pSysMem points at the array itself, so there is no copy and no allocation -
   which is the only reason a program with no C runtime can have meshes at
   all. The view holds a reference, so the buffer is released immediately. */
static ID3D11ShaderResourceView *makeBuf(const void *data, unsigned bytes,
                                         DXGI_FORMAT fmt, unsigned elems)
{
    D3D11_BUFFER_DESC bd;
    D3D11_SUBRESOURCE_DATA sd;
    D3D11_SHADER_RESOURCE_VIEW_DESC vd;
    ID3D11Buffer *buf = 0;
    ID3D11ShaderResourceView *srv = 0;

    memset(&bd, 0, sizeof(bd));
    bd.ByteWidth = bytes;
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    bd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    memset(&sd, 0, sizeof(sd));
    sd.pSysMem = data;
    if (ID3D11Device_CreateBuffer(g_dev, &bd, &sd, &buf) < 0) return 0;

    memset(&vd, 0, sizeof(vd));
    vd.Format = fmt;
    vd.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
    vd.Buffer.FirstElement = 0;
    vd.Buffer.NumElements = elems;
    ID3D11Device_CreateShaderResourceView(g_dev, (ID3D11Resource *)buf, &vd, &srv);
    ID3D11Buffer_Release(buf);
    return srv;
}

static int createPipeline(void)
{
    D3D11_BUFFER_DESC bd;
    D3D11_SAMPLER_DESC sd;

    if (ID3D11Device_CreateVertexShader(g_dev, g_vsFullscreen,
            sizeof(g_vsFullscreen), 0, &g_vsFull) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psEyeBlob,
            sizeof(g_psEyeBlob), 0, &g_psScene[SC_EYE]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psSceneBlob,
            sizeof(g_psSceneBlob), 0, &g_psScene[SC_CATHEDRAL]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psLogoBlob,
            sizeof(g_psLogoBlob), 0, &g_psScene[SC_LOGO]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psReactorBlob,
            sizeof(g_psReactorBlob), 0, &g_psScene[SC_REACTOR]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psOrbitalBlob,
            sizeof(g_psOrbitalBlob), 0, &g_psScene[SC_ORBITAL]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psVoidBlob,
            sizeof(g_psVoidBlob), 0, &g_psScene[SC_VOID]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psHorizonBlob,
            sizeof(g_psHorizonBlob), 0, &g_psScene[SC_HORIZON]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psKaleidoBlob,
            sizeof(g_psKaleidoBlob), 0, &g_psScene[SC_KALEIDO]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psFramesBlob,
            sizeof(g_psFramesBlob), 0, &g_psScene[SC_FRAMES]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psPlinthBlob,
            sizeof(g_psPlinthBlob), 0, &g_psScene[SC_PLINTH]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psDriveBlob,
            sizeof(g_psDriveBlob), 0, &g_psScene[SC_DRIVE]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psCorridorBlob,
            sizeof(g_psCorridorBlob), 0, &g_psScene[SC_CORRIDOR]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psPowerOffBlob,
            sizeof(g_psPowerOffBlob), 0, &g_psScene[SC_POWEROFF]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psBurstBlob,
            sizeof(g_psBurstBlob), 0, &g_psScene[SC_BURST]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psBloomBlob,
            sizeof(g_psBloomBlob), 0, &g_psBloom) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psC64Blob,
            sizeof(g_psC64Blob), 0, &g_psScene[SC_C64]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psSignBlob,
            sizeof(g_psSignBlob), 0, &g_psScene[SC_SIGNOFF]) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psPostBlob,
            sizeof(g_psPostBlob), 0, &g_psPost) < 0) return 0;

    memset(&bd, 0, sizeof(bd));
    bd.ByteWidth = sizeof(SceneCB);
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (ID3D11Device_CreateBuffer(g_dev, &bd, 0, &g_cbScene) < 0) return 0;
    bd.ByteWidth = sizeof(PostCB);
    if (ID3D11Device_CreateBuffer(g_dev, &bd, 0, &g_cbPost) < 0) return 0;

    memset(&sd, 0, sizeof(sd));
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    if (ID3D11Device_CreateSamplerState(g_dev, &sd, &g_sampPoint) < 0) return 0;
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    if (ID3D11Device_CreateSamplerState(g_dev, &sd, &g_sampLinear) < 0) return 0;

    /* ---- the mesh path ---------------------------------------------- */
    if (ID3D11Device_CreateVertexShader(g_dev, g_vsMeshBlob,
            sizeof(g_vsMeshBlob), 0, &g_vsMesh) < 0) return 0;
    if (ID3D11Device_CreatePixelShader(g_dev, g_psMeshBlob,
            sizeof(g_psMeshBlob), 0, &g_psMesh) < 0) return 0;

    bd.ByteWidth = sizeof(MeshCB);
    if (ID3D11Device_CreateBuffer(g_dev, &bd, 0, &g_cbMesh) < 0) return 0;
    bd.ByteWidth = sizeof(BloomCB);
    if (ID3D11Device_CreateBuffer(g_dev, &bd, 0, &g_cbBloom) < 0) return 0;

    /* The font and the boot text: immutable, bound at b1, and uploaded once.
       It has no business in b0, which is rewritten every frame for every
       shot. */
    {
        D3D11_BUFFER_DESC fd;
        D3D11_SUBRESOURCE_DATA fs;
        static unsigned int fontBlob[24 * 4 + 40 * 4];
        int k;
        for (k = 0; k < 24 * 4; k++)
            fontBlob[k] = (k < (int)(sizeof(g_c64Font) / sizeof(g_c64Font[0])))
                        ? g_c64Font[k] : 0u;
        for (k = 0; k < 40 * 4; k++)
            fontBlob[24 * 4 + k] =
                (k < (int)(sizeof(g_c64Text) / sizeof(g_c64Text[0])))
                ? g_c64Text[k] : 0u;
        memset(&fd, 0, sizeof(fd));
        fd.ByteWidth = sizeof(fontBlob);
        fd.Usage = D3D11_USAGE_IMMUTABLE;
        fd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        memset(&fs, 0, sizeof(fs));
        fs.pSysMem = fontBlob;
        if (ID3D11Device_CreateBuffer(g_dev, &fd, &fs, &g_cbFont) < 0) return 0;
    }

    /* 396 vertices x 3 shorts x 24 frames, straight out of the header. */
    g_catPos = makeBuf(g_rcatV, (unsigned)sizeof(g_rcatV),
                       DXGI_FORMAT_R16_SINT, RCAT_NV * 3 * RCAT_NF);
    g_catIdx = makeBuf(g_rcatI, (unsigned)sizeof(g_rcatI),
                       DXGI_FORMAT_R16_UINT, RCAT_NT * 3);
    g_tarPos = makeBuf(g_tarV, (unsigned)sizeof(g_tarV),
                       DXGI_FORMAT_R16_SINT, TAR_NV * 3);
    g_tarIdx = makeBuf(g_tarI, (unsigned)sizeof(g_tarI),
                       DXGI_FORMAT_R16_UINT, TAR_NT * 3);
    /* The spinning mesh is named OCAT (Oiiaioooooiai) in cats_mesh.h. */
    g_spinPos = makeBuf(g_ocatV, (unsigned)sizeof(g_ocatV),
                        DXGI_FORMAT_R16_SINT, OCAT_NV * 3);
    g_spinIdx = makeBuf(g_ocatI, (unsigned)sizeof(g_ocatI),
                        DXGI_FORMAT_R16_UINT, OCAT_NT * 3);
    {
        static unsigned char tarRGBA[TAR_NT * 4], spinRGBA[OCAT_NT * 4];
        int i, c;
        for (i = 0; i < TAR_NT; i++) {
            for (c = 0; c < 3; c++)
                tarRGBA[i * 4 + c] = g_tarPal[g_tarM[i] * 3 + c];
            tarRGBA[i * 4 + 3] = 255;
        }
        for (i = 0; i < OCAT_NT; i++) {
            for (c = 0; c < 3; c++)
                spinRGBA[i * 4 + c] = g_ocatC[i * 3 + c];
            spinRGBA[i * 4 + 3] = 255;
        }
        g_tarColor = makeBuf(tarRGBA, (unsigned)sizeof(tarRGBA),
                             DXGI_FORMAT_R8G8B8A8_UNORM, TAR_NT);
        g_spinColor = makeBuf(spinRGBA, (unsigned)sizeof(spinRGBA),
                              DXGI_FORMAT_R8G8B8A8_UNORM, OCAT_NT);
    }
    if (!g_catPos || !g_catIdx || !g_tarPos || !g_tarIdx || !g_tarColor ||
        !g_spinPos || !g_spinIdx || !g_spinColor) return 0;
    {
        D3D11_RASTERIZER_DESC rd;
        memset(&rd, 0, sizeof(rd));
        rd.FillMode = D3D11_FILL_SOLID;
        rd.CullMode = D3D11_CULL_NONE;
        rd.DepthClipEnable = TRUE;
        if (ID3D11Device_CreateRasterizerState(g_dev, &rd, &g_rsRigid) < 0)
            return 0;
    }

    /* The one way this fails silently: the fullscreen distance-field pass
       must be ALWAYS. It is the background and always wins. With GREATER, a
       sky pixel writes 0 against a cleared 0, the test fails, and the sky
       disappears. */
    {
        D3D11_DEPTH_STENCIL_DESC dd;
        memset(&dd, 0, sizeof(dd));
        dd.DepthEnable = TRUE;
        dd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
        dd.DepthFunc = D3D11_COMPARISON_ALWAYS;
        if (ID3D11Device_CreateDepthStencilState(g_dev, &dd, &g_dsSdf) < 0) return 0;
        dd.DepthFunc = D3D11_COMPARISON_GREATER;   /* reversed Z: near is big */
        if (ID3D11Device_CreateDepthStencilState(g_dev, &dd, &g_dsMesh) < 0) return 0;
    }
    return 1;
}


static void upload(ID3D11Buffer *cb, const void *src, int bytes)
{
    D3D11_MAPPED_SUBRESOURCE m;
    if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)cb, 0,
                                D3D11_MAP_WRITE_DISCARD, 0, &m) < 0) return;
    memcpy(m.pData, src, (size_t)bytes);
    ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)cb, 0);
}

static void setViewport(int w, int h)
{
    D3D11_VIEWPORT vp;
    vp.TopLeftX = 0.0f; vp.TopLeftY = 0.0f;
    vp.Width = (float)w; vp.Height = (float)h;
    vp.MinDepth = 0.0f; vp.MaxDepth = 1.0f;
    ID3D11DeviceContext_RSSetViewports(g_ctx, 1, &vp);
}

/* --------------------------------------------------------------------------
   what the music is doing
   --------------------------------------------------------------------------
   Read at the same sample index that decides which row is on screen, so the
   two cannot disagree - and so the demo never has to know what the driver's
   latency is.

   Draining the whole span since the last read is not an optimisation. A
   60 fps frame advances 2.87 grains, so reading one grain would skip two of
   every three and lose any transient that landed in them. Peak-combining is
   idempotent, so re-reading a grain above 172 fps is harmless.
   -------------------------------------------------------------------------- */
static void syncRead(__int64 played, SyncFrame *o)
{
    __int64 k = played >> 8, f = g_syncR;
    memset(o, 0, sizeof(*o));
    if (f > k) f = k;                                  /* paused, or rewound */
    if (k - f > SYNC_FRAMES - 1) f = k - (SYNC_FRAMES - 1);
    for (; f <= k; f++) {
        const SyncFrame *sf = &g_sync[f & SYNC_MASK];
        #define PK(m) if (sf->m > o->m) o->m = sf->m;
        PK(kick) PK(snare) PK(hat) PK(gtr) PK(solo) PK(org) PK(bass) PK(level)
        #undef PK
    }
    g_syncR = k + 1;
}

/* A one-pole that needs no exp and is unconditionally stable for any dt,
   which matters because dt spikes hard on an alt-tab. */
static float follow(float cur, float tgt, float dt, float atkT, float relT)
{
    float T = (tgt > cur) ? atkT : relT;
    return cur + (tgt - cur) * (dt / (T + dt));
}

/* Three bands, and each drives a different SCALE of thing: low moves big
   slow shapes, mid moves mid-sized ones, high moves fine texture. That is
   what makes the image share the music's frequency structure rather than
   merely reacting to it.

   The low band's 420 ms release is the whole argument against the beat
   throb this replaces. Against a 454 ms beat it is still falling when the
   next kick lands, so it can only ever be a slowly breathing offset - it is
   physically incapable of strobing. */
/* Flash cuts scaled to taste, or to a viewer who needs them gone. */
static float g_flashScale = 1.0f;

static float g_bLow = 0.0f, g_bMid = 0.0f, g_bHigh = 0.0f;
static SyncFrame g_syncNow;

static void syncFollow(const SyncFrame *sf, float dt)
{
    float lo = sf->kick > sf->bass  ? sf->kick : sf->bass;
    float mi = sf->gtr  > sf->solo  ? sf->gtr  : sf->solo;
    float hi = sf->hat  > sf->snare ? sf->hat  : sf->snare;
    if (sf->org > mi) mi = sf->org;
    g_bLow  = follow(g_bLow,  lo, dt, 0.008f, 0.420f);
    g_bMid  = follow(g_bMid,  mi, dt, 0.020f, 0.180f);
    g_bHigh = follow(g_bHigh, hi, dt, 0.002f, 0.070f);
}

/* --------------------------------------------------------------------------
   the edit
   -------------------------------------------------------------------------- */
static int findShot(double row)
{
    int i, best = 0;
    for (i = 0; i < NSHOTS; i++) {
        if ((double)g_shots[i].start <= row) best = i;
        else break;
    }
    return best;
}

typedef struct { float eye[3], dir[3], roll, fov; } Cam;

/* What the camera is doing, evaluated from the shot alone. Nothing here
   accumulates across shots, and that is exactly why a cut is possible: the
   next shot's camera owes the previous one nothing. */
static void evalCam(const Shot *s, float lt, Cam *c)
{
    /* The shot's axis: from the camera towards what it is looking at. Every
       behaviour is expressed against this, so aiming a shot is one idea
       instead of two - an earlier version let `at` mean a direction for some
       behaviours and a point for others, and two shots ended up staring at
       the sky because of it. */
    float ax = s->at[0] - s->eye[0];
    float ay = s->at[1] - s->eye[1];
    float az = s->at[2] - s->eye[2];
    float n  = fsqrt_(ax * ax + ay * ay + az * az);
    float fx, fy, fz;

    if (n > 1e-5f) { ax /= n; ay /= n; az /= n; }
    else           { ax = 0.0f; ay = 0.0f; az = 1.0f; }
    fx = ax; fy = ay; fz = az;

    c->eye[0] = s->eye[0]; c->eye[1] = s->eye[1]; c->eye[2] = s->eye[2];
    c->fov = s->fov; c->roll = s->roll;

    switch (s->cam) {
    case CAM_HOLD:
        break;                          /* genuinely still. no drift at all */

    case CAM_DRIFT:
        c->eye[0] += fsin_(lt * 0.31f) * 0.22f;
        c->eye[1] += fsin_(lt * 0.24f) * 0.14f;
        c->eye[2] += fsin_(lt * 0.19f) * 0.30f;
        break;

    case CAM_PUSH:
        c->eye[0] += ax * s->speed * lt;
        c->eye[1] += ay * s->speed * lt;
        c->eye[2] += az * s->speed * lt;
        break;

    case CAM_PULL:
        c->eye[0] -= ax * s->speed * lt;
        c->eye[1] -= ay * s->speed * lt;
        c->eye[2] -= az * s->speed * lt;
        /* backing away keeps the subject framed, so re-aim at it */
        fx = s->at[0] - c->eye[0];
        fy = s->at[1] - c->eye[1];
        fz = s->at[2] - c->eye[2];
        break;

    case CAM_TRACK: {                   /* sideways, across the look axis */
        float rx = az, rz = -ax;
        float m = fsqrt_(rx * rx + rz * rz);
        if (m > 1e-5f) { rx /= m; rz /= m; }
        c->eye[0] += rx * s->speed * lt;
        c->eye[2] += rz * s->speed * lt;
        fx = s->at[0] - c->eye[0];      /* the subject stays in frame */
        fy = s->at[1] - c->eye[1];
        fz = s->at[2] - c->eye[2];
        break;
    }

    case CAM_CRANE:
        c->eye[1] += s->speed * lt;
        fx = s->at[0] - c->eye[0];
        fy = s->at[1] - c->eye[1];
        fz = s->at[2] - c->eye[2];
        break;

    case CAM_ORBIT: {
        /* eye is the starting offset from the target: rotate it and keep
           looking at the middle. No atan2 needed. */
        float ox = s->eye[0] - s->at[0], oz = s->eye[2] - s->at[2];
        float a = s->speed * lt, ca = fcos_(a), sa = fsin_(a);
        c->eye[0] = s->at[0] + ox * ca - oz * sa;
        c->eye[2] = s->at[2] + ox * sa + oz * ca;
        fx = s->at[0] - c->eye[0];
        fy = s->at[1] - c->eye[1];
        fz = s->at[2] - c->eye[2];
        break;
    }

    case CAM_WHIP: {
        /* The look sweeps hard away from the shot axis and eases out, so it
           can hand off into a cut instead of just stopping. The sweep is
           relative to where the shot was aimed, never absolute. */
        /* CLAMPED, and it has to be. u is lt*speed with nothing bounding
           it, and e = 1-(1-u)^2 peaks at 1 when u reaches 1 and then comes
           back DOWN - at u=2 it is zero again and past that it goes negative.
           So an unclamped whip sweeps out, swings back through where it
           started, and then over-rotates the other way. An ease that is only
           an ease over its own domain has to be told where its domain ends. */
        float u = lt * s->speed;
        if (u > 1.0f) u = 1.0f;
        float e = 1.0f - (1.0f - u) * (1.0f - u);
        /* 0.35 radians, not 1.9. This is geometry, not taste: the only
           scene the demo whips is the tunnel, whose bore radius is 1.65, and
           a look angle of theta off the bore meets the wall at z = 1.65/tan
           theta - 4.5 units at 20 degrees, 1.65 at 45, behind the camera by
           109. At 1.9 radians (108.9 degrees) there is a tunnel in frame for
           the first 9% of the shot and a wall for the rest, at any speed,
           clamped or not. Clamping u fixed a genuine bug - past u=1 the ease
           came back down and reversed - but it did not fix this frame, and a
           brighter picture is not the same thing as a picture with a tunnel
           in it. 0.35 is about 20 degrees, which is the largest sweep that
           keeps the bore in shot. The violence lives in the roll below, which
           reads at any amplitude. */
        float a = e * 0.35f, ca = fcos_(a), sa = fsin_(a);
        fx = ax * ca - az * sa;
        fz = ax * sa + az * ca;
        fy = ay;
        c->roll += e * 0.22f;
        break;
    }
    }

    c->dir[0] = fx; c->dir[1] = fy; c->dir[2] = fz;
}

/* Mesh actors are drawn AFTER the distance field, into the same
   depth buffer, so the two occlude each other properly.

   The animation frame is fractional and comes from the song row, not from
   lt - that is what puts a footfall on a beat. At 3 frames per row a full
   24-frame cycle takes 8 rows, which is two beats, which is a lope; the
   forward travel in from/to has to agree with it or the feet skate, and the
   cat is 1.718 units long so a cycle should cover about 3.44 units of that.
*/
static void drawActor(const Shot *s, double row, float lt)
{
    MeshCB mc;
    ID3D11ShaderResourceView *srv[2];
    ID3D11ShaderResourceView *color = 0;
    unsigned nv = RCAT_NV, nt = RCAT_NT, nf = RCAT_NF;
    float qs = RCAT_QS;
    int rigid;
    float u, frame;

    if (s->actor == ACT_NONE) return;

    rigid = s->actor == ACT_TARDIS || s->actor == ACT_SPIN_CAT;
    srv[0] = g_catPos; srv[1] = g_catIdx;
    if (s->actor == ACT_TARDIS) {
        nv = TAR_NV; nt = TAR_NT; nf = 1; qs = TAR_QS;
        srv[0] = g_tarPos; srv[1] = g_tarIdx; color = g_tarColor;
    } else if (s->actor == ACT_SPIN_CAT) {
        nv = OCAT_NV; nt = OCAT_NT; nf = 1; qs = OCAT_QS;
        srv[0] = g_spinPos; srv[1] = g_spinIdx; color = g_spinColor;
    }

    u = (s->actRate > 0.0f || s->actor == ACT_SPIN_CAT)
      ? (float)(row - (double)s->start) : 0.0f;
    frame = (s->actor == ACT_CAT_STILL) ? 2.0f
          : u * s->actRate;
    /* the shot's own progress, for the from -> to travel */
    {
        float span = (float)(SONG_ROWS - s->start);
        float t01;
        int i;
        (void)lt;
        /* End at this shot's next cut, including the one-bar run at 77.
           Look up by start row so dissolve draws of the previous shot and
           diagnostic copies of a Shot use the same duration. */
        for (i = 0; i < NSHOTS; i++) {
            if (g_shots[i].start > s->start) {
                span = (float)(g_shots[i].start - s->start);
                break;
            }
        }
        if (span < 1.0f) span = 1.0f;
        t01 = (float)(row - (double)s->start) / span;
        if (t01 > 1.0f) t01 = 1.0f;
        if (t01 < 0.0f) t01 = 0.0f;
        memset(&mc, 0, sizeof(mc));
        for (i = 0; i < 3; i++)
            mc.model[i] = s->from[i] + (s->to[i] - s->from[i]) * t01;
        mc.model[3] = s->actScale > 0.0f ? s->actScale : 1.0f;
    }
    mc.anim[0] = rigid ? 0.0f : frame;
    mc.anim[1] = (float)nf;
    mc.anim[2] = qs;
    /* Spin rate is radians per song row; zero holds the original pose. */
    mc.anim[3] = (s->actor == ACT_SPIN_CAT) ? frame : 0.0f;
    mc.misc[0] = (float)nv;
    mc.misc[1] = 0.0f;                       /* wireframe */
    mc.misc[2] = 0.0f;                       /* shatter   */
    /* The organ lifts it, but the BASE has to stand on its own: the rule in
       this file is base + k*s and never base*s, so muting the synth must
       leave every frame deliberate. At a base of 0.10 the cat was a black
       shape on a dark floor and simply vanished. */
    mc.misc[3] = rigid
               ? 0.0f
               : (0.42f + g_syncNow.org * 0.30f);
    upload(g_cbMesh, &mc, sizeof(mc));

    ID3D11DeviceContext_VSSetShaderResources(g_ctx, 0, 2, srv);
    ID3D11DeviceContext_PSSetShaderResources(g_ctx, 2, 1, &color);
    if (rigid) ID3D11DeviceContext_RSSetState(g_ctx, g_rsRigid);
    ID3D11DeviceContext_VSSetShader(g_ctx, g_vsMesh, 0, 0);
    ID3D11DeviceContext_PSSetShader(g_ctx, g_psMesh, 0, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(g_ctx, 0, 1, &g_cbScene);
    ID3D11DeviceContext_VSSetConstantBuffers(g_ctx, 1, 1, &g_cbMesh);
    ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 0, 1, &g_cbScene);
    ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 1, 1, &g_cbMesh);
    ID3D11DeviceContext_OMSetDepthStencilState(g_ctx, g_dsMesh, 0);
    ID3D11DeviceContext_Draw(g_ctx, nt * 3, 0);

    {   /* leave nothing bound: the scene targets become inputs next */
        ID3D11ShaderResourceView *const nul[2] = { 0, 0 };
        ID3D11DeviceContext_VSSetShaderResources(g_ctx, 0, 2, nul);
        ID3D11DeviceContext_PSSetShaderResources(g_ctx, 2, 1, nul);
        if (rigid) ID3D11DeviceContext_RSSetState(g_ctx, 0);
        ID3D11DeviceContext_VSSetShader(g_ctx, g_vsFull, 0, 0);
    }
}

/* `row` is the absolute song row being rendered, and it is a parameter
   rather than the g_row global on purpose. The live and video paths both
   call renderFrame(g_row, ...) so the two agree there - but the OFFLINE self
   test renders arbitrary rows and never touches g_row, so anything reading
   the global was drawing a different moment than the post pass was, and the
   diagnostic was not testing what ships. The actor animation had that split
   already; the matte would have inherited it. */
static void drawScene(const Shot *s, double row, float lt, float matte,
                      ID3D11RenderTargetView *rtv)
{
    SceneCB sc;
    Cam c;

    evalCam(s, lt, &c);

    memset(&sc, 0, sizeof(sc));
    sc.t[0] = lt;
    sc.t[1] = 0.0f;
    sc.t[2] = 1.0f;
    sc.t[3] = (float)g_vw / (float)g_vh;
    sc.cam[0] = c.eye[0]; sc.cam[1] = c.eye[1]; sc.cam[2] = c.eye[2];
    sc.cam[3] = c.fov;
    sc.dir[0] = c.dir[0]; sc.dir[1] = c.dir[1]; sc.dir[2] = c.dir[2];
    sc.dir[3] = c.roll;
    sc.tune[0] = s->tune[0]; sc.tune[1] = s->tune[1];
    sc.tune[2] = s->tune[2]; sc.tune[3] = s->tune[3];
    /* The sign-off is the one thing in the demo that has to be legible, and
       it lives in the bottom-left corner - which is exactly where the matte
       eats the picture. So it gets told how far up the visible bottom edge
       currently is and places itself above that, rather than at a fixed
       height that happens to work for one matte setting. Type inside a
       title-safe area, which is the same thing every broadcast designer has
       done since the fifties.

       Handed in rather than looked up here, and that is not tidiness: the
       row this function receives is the STUTTERED one, and the post pass
       draws the bar from the true row. Two matteAt() calls could disagree
       the moment a sign-off shot ever got a stutter. One value, computed
       once, cannot. */
    if (s->scene == SC_SIGNOFF) sc.tune[3] = matte;
    sc.sync[0] = g_bLow; sc.sync[1] = g_bMid; sc.sync[2] = g_bHigh;
    sc.sync[3] = g_syncNow.level;
    sc.voice[0] = g_syncNow.gtr;  sc.voice[1] = g_syncNow.solo;
    sc.voice[2] = g_syncNow.org;  sc.voice[3] = g_syncNow.hat;
    // Each inscription gets one appearance, on a monitor inside the scene.
    if (s->scene == SC_PLINTH) {
        int label = s->start == BAR(14) ? 1 :
                    s->start == BAR(51) ? 2 : s->start == BAR(85) ? 3 : 0;
        if (label) {
            float v = lt < .35f ? lt/.35f : lt < 2.7f ? 1.0f : (3.15f-lt)/.45f;
            if (v < 0) v = 0; if (v > 1) v = 1;
            sc.caption[0] = (float)label; sc.caption[1] = v;
        }
    }
    upload(g_cbScene, &sc, sizeof(sc));

    ID3D11DeviceContext_PSSetShaderResources(g_ctx, 0, 2, g_nullSRV);
    ID3D11DeviceContext_ClearDepthStencilView(g_ctx, g_depthDSV,
                                              D3D11_CLEAR_DEPTH, 0.0f, 0);
    ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 1, &rtv, g_depthDSV);
    ID3D11DeviceContext_OMSetDepthStencilState(g_ctx, g_dsSdf, 0);
    setViewport(g_vw, g_vh);
    ID3D11DeviceContext_IASetPrimitiveTopology(g_ctx,
        D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_IASetInputLayout(g_ctx, 0);
    ID3D11DeviceContext_VSSetShader(g_ctx, g_vsFull, 0, 0);
    ID3D11DeviceContext_PSSetShader(g_ctx, g_psScene[s->scene], 0, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 0, 1, &g_cbScene);
    if (s->scene == SC_C64)
        ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 1, 1, &g_cbFont);
    ID3D11DeviceContext_Draw(g_ctx, 3, 0);

    drawActor(s, row, lt);
}

#ifdef OFFLINE
static const char *grName(int g)
{
    switch (g) {
    case GR_COLD:     return "cold    ";
    case GR_WARM:     return "warm    ";
    case GR_NEON:     return "neon    ";
    case GR_BLEACH:   return "bleach  ";
    case GR_PHOSPHOR: return "phosphor";
    }
    return "?";
}
#endif

/* Which palette a shot is cut in: its scene's own look if it has one, and
   otherwise whatever the music is doing at the row the shot starts. Keyed on
   the START row and not on the playhead, so a grade change never lands in the
   middle of a held shot - the schedule and the edit are both written against
   the same bar lines, so in practice they always agree anyway, and this
   makes that guaranteed rather than lucky. */
static const Grade *gradeFor(const Shot *s)
{
    unsigned char g = g_sceneGrade[s->scene];
    if (g == GR_FOLLOW) {
        int i;
        g = g_gradeKeys[0].grade;
        for (i = 0; i < GRADE_KEYS; i++)
            if (g_gradeKeys[i].row <= s->start) g = g_gradeKeys[i].grade;
    }
    return &g_grades[g < GR_COUNT ? g : 0];
}

static void renderFrame(double row, ID3D11RenderTargetView *dest,
                        int ow, int oh)
{
    const Shot *s;
    PostCB pc;
    ID3D11SamplerState *samps[2];
    int si = findShot(row);
    double srow = row;
    float matte = matteAt(row);
    float lt, flash = 0.0f, fade = 1.0f, mix = 0.0f, whip = 0.0f;

    s  = &g_shots[si];
    lt = (float)(row - (double)s->start) * SEC_PER_ROW;

    /* The stutter, if this shot has one. Everything downstream of here reads
       the quantised row, so the scene, the camera and the actor judder as one
       picture - while `row`, which the edit and the matte are addressed in,
       is untouched and the cut still lands exactly where it was written. */
    if (s->stutter > 0.0f) {
        double q  = (double)s->stutter;
        double dr = row - (double)s->start;
        dr = q * (double)(__int64)(dr / q);      /* dr >= 0, so this is floor */
        srow = (double)s->start + dr;
        lt   = (float)dr * SEC_PER_ROW;
    }

    /* The transition INTO this shot. It is a property of the shot, so a hard
       cut is simply a shot whose transRows is zero - which is most of them,
       and should be. */
    if (s->transRows > 0) {
        double p = (row - (double)s->start) / (double)s->transRows;
        if (p >= 0.0 && p < 1.0) {
            float u = (float)p;
            switch (s->trans) {
            /* LINEAR, not squared, and that is a photosensitivity decision
               rather than a taste one.

               Measured on the rendered video: a squared decay from full white
               over one row is about 16% of full scale per frame, and the
               guideline counts every transition over 10% affecting more than
               a quarter of the screen. So one flash was being counted as six
               events, and the wind-up at 2:21 - three flash cuts inside seven
               bars - came out at seven transitions in a second against a
               limit of three.

               A linear ramp over the shot's transition window spreads the
               same energy at a constant rate: at the two rows the flash cuts
               now use, that is 6.6% per frame. One up-transition on the cut,
               where it belongs, and nothing on the way down. */
            case TR_FLASH:    flash = (1.0f - u) * 0.90f * g_flashScale; break;
            case TR_BLACK:    fade  = u * u;                   break;
            case TR_DISSOLVE: mix   = 1.0f - u;                break;
            case TR_WHIPIN:   whip  = 1.0f - u;                break;
            default: break;
            }
        }
    }

    drawScene(s, srow, lt, matte, g_sceneRTV[0]);

    if (mix > 0.002f && si > 0) {
        const Shot *prev = &g_shots[si - 1];
        drawScene(prev, row, (float)(row - (double)prev->start) * SEC_PER_ROW,
                  matte, g_sceneRTV[1]);
    }

    /* Unbind the render targets before the scene textures become inputs. */
    ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 1, g_nullRTV, 0);

    /* ---- bloom: bright pass down, then blur across, then blur down ---- */
    {
        BloomCB bc;
        ID3D11ShaderResourceView *one[1];
        int pass;

        ID3D11DeviceContext_PSSetShader(g_ctx, g_psBloom, 0, 0);
        ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 0, 1, &g_cbBloom);
        ID3D11DeviceContext_PSSetSamplers(g_ctx, 1, 1, &g_sampLinear);

        /* Downsample first, then both blurs on their native half-res grid.
           Targets 0 -> 1 -> 0; the composite must sample target 0. */
        for (pass = 0; pass < 3; pass++) {
            int dst = (pass == 0) ? 0 : (pass & 1);
            int srcW = (pass == 0) ? g_vw : g_bw;
            int srcH = (pass == 0) ? g_vh : g_bh;

            memset(&bc, 0, sizeof(bc));
            bc.step[0] = 1.0f / (float)srcW;
            bc.step[1] = 1.0f / (float)srcH;
            bc.param[0] = 0.62f;      /* threshold */
            bc.param[1] = 0.35f;      /* knee      */
            bc.param[3] = (float)pass;
            upload(g_cbBloom, &bc, sizeof(bc));

            one[0] = (pass == 0) ? g_sceneSRV[0] : g_bloomSRV[1 - dst];
            ID3D11DeviceContext_PSSetShaderResources(g_ctx, 0, 1, g_nullSRV);
            ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 1, &g_bloomRTV[dst], 0);
            setViewport(g_bw, g_bh);
            ID3D11DeviceContext_PSSetShaderResources(g_ctx, 0, 1, one);
            ID3D11DeviceContext_Draw(g_ctx, 3, 0);
            ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 1, g_nullRTV, 0);
        }
        ID3D11DeviceContext_PSSetShaderResources(g_ctx, 0, 1, g_nullSRV);
    }

    memset(&pc, 0, sizeof(pc));
    pc.res[0] = (float)g_vw;  pc.res[1] = (float)g_vh;
    pc.res[2] = (float)ow;    pc.res[3] = (float)oh;
    pc.crt[0] = 0.22f;        /* scanline depth                */
    pc.crt[1] = 0.30f;        /* aperture grille depth         */
    pc.crt[2] = 0.35f;        /* keep edges and small inscriptions legible */
    pc.crt[3] = 0.12f;        /* preserve foreground parallax at the edges */
    /* THE TEXTURAL LAYER. One to three percent, on the transient band only.
       This is meant to be felt and never seen: if a viewer can point at the
       screen and say "that was the snare", it is too much. Done here rather
       than in eleven shaders so there is one place to turn it down. */
    pc.crt[2] += g_bHigh * 0.18f;                  /* aberration, 0.2 px    */
    pc.crt[0] += g_bLow  * 0.015f;                 /* scanline depth        */
    /* The palette. Crossfaded through a dissolve so the two shots are graded
       into each other as well as mixed - a hard palette switch underneath a
       crossfade reads as a glitch rather than as a transition. The dither and
       the exposure fold into the two knobs that already existed, so the music
       still breathes on top of whatever the section's look is. */
    {
        const Grade *ga = gradeFor(s), *gb = ga;
        float k = 0.0f, dith, expo;
        int r2, c2;
        if (mix > 0.002f && si > 0) { gb = gradeFor(&g_shots[si - 1]); k = mix; }
        for (r2 = 0; r2 < 4; r2++)
            for (c2 = 0; c2 < 4; c2++)
                pc.ramp[r2][c2] = ga->ramp[r2][c2] * (1.0f - k)
                                + gb->ramp[r2][c2] * k;
        pc.tone[0] = ga->hueKeep * (1.0f - k) + gb->hueKeep * k;
        pc.tone[1] = ga->steps   * (1.0f - k) + gb->steps   * k;
        dith = ga->dither   * (1.0f - k) + gb->dither   * k;
        expo = ga->exposure * (1.0f - k) + gb->exposure * k;
        pc.grade[0] = dith + g_bHigh * 0.05f;      /* dither amount         */
        pc.grade[1] = expo + g_bLow * 0.030f;      /* exposure breathes     */
    }
    pc.grade[2] = mix;
    /* Leave through the 3D world, not a flat power-off card. */
    if (row > (double)SONG_ROWS - 16.0) {
        float end = (float)(((double)SONG_ROWS - row) / 16.0);
        if (end < 0.0f) end = 0.0f;
        fade *= end * end * (3.0f - 2.0f * end);
    }
    pc.grade[3] = fade;
    pc.fx[0] = flash;
    pc.fx[1] = whip;
    /* How much of the glow comes back. The organ and the solo push it a
       little: the brightest passages of the music are the ones where the
       picture should feel like it is running hot. */
    pc.fx[2] = 0.55f + g_bMid * 0.20f;
    pc.fx[3] = matte;
    upload(g_cbPost, &pc, sizeof(pc));

    ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 1, &dest, 0);
    setViewport(ow, oh);
    ID3D11DeviceContext_PSSetShader(g_ctx, g_psPost, 0, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 0, 1, &g_cbPost);
    {
        ID3D11ShaderResourceView *three[3];
        three[0] = g_sceneSRV[0]; three[1] = g_sceneSRV[1];
        /* Last pass writes target 0: threshold -> V -> H. */
        three[2] = g_bloomSRV[0];
        ID3D11DeviceContext_PSSetShaderResources(g_ctx, 0, 3, three);
    }
    samps[0] = g_sampPoint; samps[1] = g_sampLinear;
    ID3D11DeviceContext_PSSetSamplers(g_ctx, 0, 2, samps);
    ID3D11DeviceContext_Draw(g_ctx, 3, 0);

    /* All THREE, not two. t2 held a view of a bloom target, and the next
       frame's blur pass binds that same texture as a render target - which is
       the exact SRV/RTV collision every other unbind in this file exists to
       avoid. D3D11 resolves it by silently dropping the SRV, so it costs a
       frame of bloom rather than crashing, which is why it survived. */
    ID3D11DeviceContext_PSSetShaderResources(g_ctx, 0, 3, g_nullSRV);
}

/* --------------------------------------------------------------------------
   window
   -------------------------------------------------------------------------- */
static void resizeSwapChain(int w, int h)
{
    if (!g_sc || w < 1 || h < 1) return;
    ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 0, 0, 0);
    releaseBackbuffer();                    /* every reference, or this fails */
    if (IDXGISwapChain1_ResizeBuffers(g_sc, 0, (UINT)w, (UINT)h,
                                      DXGI_FORMAT_UNKNOWN, 0) < 0) {
        /* The old buffers survive a failed resize; restore their view. */
        if (createBackbuffer()) return;
        audioCleanup();
        fatal(L"The back buffer could not be restored after resizing.");
    }
    g_ow = w; g_oh = h;
    if (!createBackbuffer() || !createSceneTargets(g_ow, g_oh)) {
        audioCleanup();
        fatal(L"The render targets could not be created after resizing.");
    }
}

static void updatePause(void)
{
    int paused = g_paused || g_sizing;
    if (paused == g_wasPaused) return;
    if (g_audioOk) {
        MMRESULT result = paused ? waveOutPause(g_wo) : waveOutRestart(g_wo);
        if (result != MMSYSERR_NOERROR) audioCleanup();
    }
    g_wasPaused = paused;
    g_audioStall = 0;
    QueryPerformanceCounter(&g_qpcLast);
}

static void setFullscreen(int on)
{
    MONITORINFO mi = { sizeof(MONITORINFO) };
    HMONITOR mon;

    if (on == g_full) return;
    g_full = on;

    if (on) {
        g_style = GetWindowLongPtrW(g_hwnd, GWL_STYLE);
        GetWindowPlacement(g_hwnd, &g_place);
        /* The monitor the window is ON, not the primary one. Getting this
           wrong is why so many demos jump to the wrong screen. */
        mon = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
        GetMonitorInfoW(mon, &mi);
        SetWindowLongPtrW(g_hwnd, GWL_STYLE,
                          g_style & ~(LONG_PTR)WS_OVERLAPPEDWINDOW);
        SetWindowPos(g_hwnd, HWND_TOP,
                     mi.rcMonitor.left, mi.rcMonitor.top,
                     mi.rcMonitor.right - mi.rcMonitor.left,
                     mi.rcMonitor.bottom - mi.rcMonitor.top,
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        ShowCursor(FALSE);
    } else {
        SetWindowLongPtrW(g_hwnd, GWL_STYLE, g_style);
        SetWindowPlacement(g_hwnd, &g_place);
        SetWindowPos(g_hwnd, 0, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        ShowCursor(TRUE);
    }
}

static LRESULT CALLBACK wndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_CLOSE:
    case WM_DESTROY:
        g_running = 0;
        PostQuitMessage(0);
        return 0;

    case WM_KEYDOWN:
        if (w == VK_ESCAPE) { g_running = 0; PostQuitMessage(0); return 0; }
        if ((w == 'F' || w == 'G') && (l & ((LPARAM)1 << 30))) return 0;
        if (w == 'F') { setFullscreen(!g_full); return 0; }
        /* Flash cuts off, half, full. The demo is legible without them - they
           punctuate the edit rather than carrying it - so this costs a viewer
           who needs it nothing but the punctuation. */
        if (w == 'G') {
            g_flashScale = (g_flashScale > 0.75f) ? 0.35f
                         : (g_flashScale > 0.10f) ? 0.0f : 1.0f;
            return 0;
        }
        return 0;

    case WM_SYSCOMMAND:
        /* No screensaver and no display blanking in the middle of a demo. */
        if ((w & 0xFFF0) == SC_SCREENSAVE || (w & 0xFFF0) == SC_MONITORPOWER)
            return 0;
        break;

    case WM_ACTIVATE:
        /* Focus loss stops the whole thing, picture and sound, and it
           resumes on the frame it left. */
        g_paused = (LOWORD(w) == WA_INACTIVE);
        updatePause();
        return 0;

    case WM_GETMINMAXINFO:
        ((MINMAXINFO *)l)->ptMinTrackSize.x = 480;
        ((MINMAXINFO *)l)->ptMinTrackSize.y = 320;
        return 0;

    case WM_ENTERSIZEMOVE:
        /* Dragging the border runs a modal loop that owns the message pump.
           We stop resizing the chain per WM_SIZE while it is up and do it
           once at the end. */
        g_sizing = 1;
        updatePause();
        return 0;

    case WM_EXITSIZEMOVE: {
        RECT rc;
        GetClientRect(h, &rc);
        resizeSwapChain(rc.right - rc.left, rc.bottom - rc.top);
        g_sizing = 0;
        updatePause();
        return 0;
    }

    case WM_SIZE:
        if (w == SIZE_MINIMIZED) return 0;       /* 0x0, never resize to it */
        if (!g_sizing) resizeSwapChain(LOWORD(l), HIWORD(l));
        return 0;

    case WM_DPICHANGED: {
        /* Use the rectangle Windows suggests, or the window is the wrong
           size on the new monitor. */
        RECT *rc = (RECT *)l;
        SetWindowPos(h, 0, rc->left, rc->top,
                     rc->right - rc->left, rc->bottom - rc->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    }
    return DefWindowProcW(h, m, w, l);
}

/* --------------------------------------------------------------------------
   entry
   -------------------------------------------------------------------------- */
#ifdef OFFLINE
static void offlineMain(void);
#endif
#ifdef VIDEO
static void videoMain(void);
#endif

void entry(void)
{
    WNDCLASSEXW wc;
    MSG msg;

    /* Denormals off. The reverb tails in the synth run into them, and a
       denormal stall in the audio callback is a click. */
    _mm_setcsr(_mm_getcsr() | 0x8040);

    /* DPI first, before any window exists. Without it DWM bitmap-stretches
       the window on a scaled display and every pixel of the CRT pass is
       blurred by something we do not control. */
    {
        HMODULE u32 = GetModuleHandleA("user32.dll");
        typedef BOOL (WINAPI *PFN_SPDAC)(HANDLE);
        PFN_SPDAC set = (PFN_SPDAC)GetProcAddress(u32,
                            "SetProcessDpiAwarenessContext");
        if (set) set((HANDLE)-4);     /* PER_MONITOR_AWARE_V2 */
        else {
            typedef BOOL (WINAPI *PFN_SPDA)(void);
            PFN_SPDA old = (PFN_SPDA)GetProcAddress(u32, "SetProcessDPIAware");
            if (old) old();
        }
    }

    if (!createDevice()) ExitProcess(1);

#ifdef OFFLINE
    offlineMain();                  /* never returns: no window, no sound */
#endif
#ifdef VIDEO
    videoMain();                    /* never returns: frames to stdout */
#endif

    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = GetModuleHandleW(0);
    wc.hCursor = LoadCursorW(0, (LPCWSTR)IDC_ARROW);
    wc.hbrBackground = 0;   /* we paint every pixel every frame; a brush here
                               would only add an erase flicker, and it was the
                               last thing that needed gdi32 */
    wc.lpszClassName = L"CRTkafa";
    RegisterClassExW(&wc);

    /* Created hidden on purpose - see the pre-warm below. */
    g_hwnd = CreateWindowExW(0, L"CRTkafa", L"CRTkafa",
                             WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720,
                             0, 0, wc.hInstance, 0);
    if (!g_hwnd) fatal(L"The window could not be created.");

    if (!createSwapChain(g_hwnd)) fatal(L"The swap chain could not be created.");
    if (!createBackbuffer())      fatal(L"The back buffer could not be created.");
    if (!createPipeline())        fatal(L"The shaders could not be created.");
    if (!createSceneTargets(g_ow, g_oh))
        fatal(L"The render targets could not be created.");

    /* Warm every shader before the audience sees anything. fxc precompiles
       to DXBC but the driver still JITs to native ISA on the FIRST DRAW with
       a given shader, not at CreatePixelShader - so without this the match
       cut at bar 9 and the hard cut into white at bar 18, the two most
       carefully placed moments in the demo, each eat a first-draw hitch.
       One frame per scene, into the scene target, thrown away. */
    {
        int sc;
        Shot warm;
        memset(&warm, 0, sizeof(warm));
        warm.at[2] = 1.0f; warm.fov = 0.62f;
        for (sc = 0; sc < SC_COUNT; sc++) {
            warm.scene = (unsigned char)sc;
            drawScene(&warm, 0.0, 0.0f, 0.0f, g_sceneRTV[0]);
        }
        /* and once through the post pass with a dissolve live, which is the
           only path that binds the second scene target */
        renderFrame(0.0, g_backRTV, g_ow, g_oh);
    }

    setFullscreen(1);
    /* Only now does the window appear. Creating it visible at 1280x720 and
       resizing afterwards showed the audience a window full of stale desktop,
       then a jump to fullscreen, then finally frame zero. */
    ShowWindow(g_hwnd, SW_SHOW);
    SetForegroundWindow(g_hwnd);
    SetFocus(g_hwnd);

    audioInit();     /* from here on the song, not the wall clock, is time */
    g_wasPaused = 0;
    updatePause();

    QueryPerformanceFrequency(&g_qpcFreq);
    QueryPerformanceCounter(&g_qpcLast);

    while (g_running) {
        LARGE_INTEGER now;
        double dt;

        while (PeekMessageW(&msg, 0, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) { g_running = 0; break; }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (!g_running) break;

        updatePause();
        if (g_paused || g_sizing) {
            /* Stopped means stopped, picture and sound both, and it resumes
               on the frame it left. */
            WaitMessage();
            QueryPerformanceCounter(&g_qpcLast);
            continue;
        }

        QueryPerformanceCounter(&now);
        dt = (double)(now.QuadPart - g_qpcLast.QuadPart) /
             (double)g_qpcFreq.QuadPart;
        g_qpcLast = now;
        if (dt < 0.0) dt = 0.0;
        if (dt > 0.25) dt = 0.25;

        audioPump();

        /* THE CLOCK. Every cut in the demo is placed on a row of the song, so
           the row index has to come from the music itself - the number of
           samples the card has actually played - and not from a wall clock
           that would slowly slide out of time with it. The QPC path below is
           only for a machine with no working sound device. */
        {
            __int64 played = audioPlayedSamples();
            /* Losing the device mid-run - bluetooth dropping, an interface
               unplugged, the audio re-routed - usually does NOT return an
               error: waveOutGetPosition just keeps reporting the last
               position. The clock then stops and the picture freezes while
               the process is perfectly healthy. So watch for a position that
               has stopped advancing and fall back to the wall clock, seeded
               from the last good row. A demo that keeps playing silently is
               recoverable; one that freezes on screen is not. */
            if (played >= 0 && played == g_lastPlayed) {
                if (++g_audioStall > 30) played = -1;    /* half a second */
            } else {
                g_audioStall = 0;
                g_lastPlayed = played;
            }
            if (played >= 0) {
                g_row = (double)played / (double)SPR;
                syncRead(played, &g_syncNow);
            } else {
                audioCleanup();
                memset(&g_syncNow, 0, sizeof(g_syncNow));
                g_row += dt / (double)SEC_PER_ROW;
            }
        }
        /* Live playback ends once the card has played the complete song.
           Offline timeline functions retain their explicit loop semantics. */
        if (g_row >= (double)SONG_ROWS) {
            const float black[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
            ID3D11DeviceContext_ClearRenderTargetView(g_ctx, g_backRTV, black);
            IDXGISwapChain1_Present(g_sc, 1, 0);
            break;
        }
        syncFollow(&g_syncNow, (float)dt);

        renderFrame(g_row, g_backRTV, g_ow, g_oh);
        IDXGISwapChain1_Present(g_sc, 1, 0);
    }

    audioCleanup();
    ExitProcess(0);
}

/* --------------------------------------------------------------------------
   offline verification
   --------------------------------------------------------------------------
   No window, no swap chain, no sound: render straight into an offscreen
   target, copy it back and write bitmaps. This is how the renderer is
   checked without ever putting anything on screen.
   -------------------------------------------------------------------------- */
#ifdef OFFLINE
/* Sized for the OUTPUT width, not the virtual one. It held VW_MAX*3 and the
   first bitmap written at 1920 wide ran past the end into the next object
   in BSS. */
#define BMP_MAXW 3840
static unsigned char g_bmpRow[BMP_MAXW * 3];

static void dumpBmp(const char *name, const unsigned char *bgra, int w, int h,
                    int pitch)
{
    HANDLE f = CreateFileA(name, GENERIC_WRITE, 0, 0, CREATE_ALWAYS, 0, 0);
    unsigned char hdr[54];
    DWORD wr;
    int x, y, pad = (4 - ((w * 3) & 3)) & 3;
    unsigned int img = (unsigned int)(w * 3 + pad) * (unsigned int)h;

    if (f == INVALID_HANDLE_VALUE) return;
    if (w > BMP_MAXW) { CloseHandle(f); return; }

    memset(hdr, 0, sizeof(hdr));
    hdr[0] = 'B'; hdr[1] = 'M';
    *(unsigned int *)(hdr + 2)  = img + 54;
    *(unsigned int *)(hdr + 10) = 54;
    *(unsigned int *)(hdr + 14) = 40;
    *(int *)(hdr + 18) = w;
    *(int *)(hdr + 22) = h;
    *(unsigned short *)(hdr + 26) = 1;
    *(unsigned short *)(hdr + 28) = 24;
    *(unsigned int *)(hdr + 34) = img;
    WriteFile(f, hdr, 54, &wr, 0);

    for (y = h - 1; y >= 0; y--) {
        const unsigned char *src = bgra + (size_t)y * (size_t)pitch;
        for (x = 0; x < w; x++) {
            g_bmpRow[x * 3 + 0] = src[x * 4 + 0];
            g_bmpRow[x * 3 + 1] = src[x * 4 + 1];
            g_bmpRow[x * 3 + 2] = src[x * 4 + 2];
        }
        WriteFile(f, g_bmpRow, (DWORD)(w * 3), &wr, 0);
        if (pad) WriteFile(f, g_bmpRow, (DWORD)pad, &wr, 0);
    }
    CloseHandle(f);
}

static char g_log[16384];
static int  g_logN = 0;
static void logs(const char *s) { while (*s && g_logN < 16000) g_log[g_logN++] = *s++; }
static void logi(int v)
{
    char t[16]; int n = 0;
    if (v < 0) { logs("-"); v = -v; }
    if (!v) { logs("0"); return; }
    while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
    while (n && g_logN < 16000) g_log[g_logN++] = t[--n];
}
static void logf2(float v)                    /* two decimals, no CRT */
{
    int w = (int)v, f = (int)((v - (float)w) * 100.0f + 0.5f);
    if (f < 0) f = -f;
    logi(w); logs("."); if (f < 10) logs("0"); logi(f);
}

static const char *camName(int k)
{
    switch (k) {
    case CAM_HOLD:  return "hold ";
    case CAM_PUSH:  return "push ";
    case CAM_PULL:  return "pull ";
    case CAM_TRACK: return "track";
    case CAM_CRANE: return "crane";
    case CAM_ORBIT: return "orbit";
    case CAM_WHIP:  return "whip ";
    default:        return "drift";
    }
}
static const char *trName(int k)
{
    switch (k) {
    case TR_CUT:      return "cut";
    case TR_FLASH:    return "flash";
    case TR_BLACK:    return "black";
    case TR_DISSOLVE: return "dissolve";
    case TR_MATCH:    return "match";
    default:          return "whip-in";
    }
}
static const char *scName(int k)
{
    switch (k) {
    case SC_EYE:       return "eye      ";
    case SC_CATHEDRAL: return "cathedral";
    case SC_LOGO:      return "logo 3D  ";
    case SC_REACTOR:   return "reactor  ";
    case SC_ORBITAL:   return "orbital  ";
    case SC_VOID:      return "void     ";
    case SC_HORIZON:   return "horizon  ";
    case SC_KALEIDO:   return "kaleido  ";
    case SC_FRAMES:    return "frames   ";
    case SC_PLINTH:    return "plinth   ";
    case SC_DRIVE:     return "drive    ";
    case SC_CORRIDOR:  return "corridor ";
    case SC_POWEROFF:  return "power-off";
    case SC_C64:       return "c64 boot ";
    case SC_SIGNOFF:   return "sign-off ";
    default:           return "burst    ";
    }
}

static void offlineMain(void)
{
    static const int RES[][2] = {
        { 1920, 1080 }, { 2560, 1080 }, { 3440, 1440 }, { 1366, 768 },
        { 1280, 1024 }, { 3840, 2160 }, { 5120, 1440 }, { 1024, 768 },
        { 800, 600 }, { 640, 480 }
    };
    ID3D11Texture2D *out = 0, *stage = 0;
    ID3D11RenderTargetView *outRTV = 0;
    D3D11_TEXTURE2D_DESC td;
    D3D11_MAPPED_SUBRESOURCE m;
    int i, fails = 0;
    HANDLE f;
    DWORD wr;

    if (!createPipeline()) { logs("pipeline FAILED\r\n"); fails++; }

    logs("CRTkafa D3D11 self test\r\n\r\n  device: ");
    logs(g_warp ? "WARP (software)" : "hardware");
    logs("\r\n\r\n");

    /* ---- every resolution renders ------------------------------------ */
    for (i = 0; i < (int)(sizeof(RES) / sizeof(RES[0])); i++) {
        int ow = RES[i][0], oh = RES[i][1], lit = 0, px;

        if (!createSceneTargets(ow, oh)) { fails++; continue; }

        memset(&td, 0, sizeof(td));
        td.Width = (UINT)ow; td.Height = (UINT)oh;
        td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &out) < 0) { fails++; continue; }
        if (ID3D11Device_CreateRenderTargetView(g_dev, (ID3D11Resource *)out, 0,
                                                &outRTV) < 0) { fails++; continue; }
        td.Usage = D3D11_USAGE_STAGING;
        td.BindFlags = 0;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &stage) < 0) { fails++; continue; }

        renderFrame((double)BAR(8), outRTV, ow, oh);
        ID3D11DeviceContext_CopyResource(g_ctx, (ID3D11Resource *)stage,
                                         (ID3D11Resource *)out);

        logs("  "); logi(ow); logs("x"); logi(oh);
        logs(" -> scene "); logi(g_vw); logs("x"); logi(g_vh); logs("  ");

        if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage, 0,
                                    D3D11_MAP_READ, 0, &m) >= 0) {
            const unsigned char *p = (const unsigned char *)m.pData;
            int x, y;
            for (y = 0; y < oh; y += 7)
                for (x = 0; x < ow; x += 7) {
                    const unsigned char *q = p + (size_t)y * m.RowPitch + x * 4;
                    if (q[0] + q[1] + q[2] > 24) lit++;
                }
            px = (ow / 7) * (oh / 7);
            if (lit * 100 < px * 3) { logs("DARK "); fails++; }
            else                     logs("ok ");
            logi(lit * 100 / (px ? px : 1)); logs("% lit");
            ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)stage, 0);
        } else { logs("MAP FAILED"); fails++; }
        logs("\r\n");

        /* ---- one frame per shot, so the whole edit can be looked at --- */
        if (i == 0) {
            int sh;
            logs("\r\n  the edit: "); logi(NSHOTS); logs(" shots\r\n");
            for (sh = 0; sh < NSHOTS; sh++) {
                const Shot *s = &g_shots[sh];
                double end = (sh + 1 < NSHOTS) ? (double)g_shots[sh + 1].start
                                               : (double)SONG_ROWS;
                double mid = (double)s->start + (end - (double)s->start) * 0.55;
                char nm[16];
                D3D11_MAPPED_SUBRESOURCE mm;

                if (sh == 0) {
                    static const float seconds[] = {
                        1.0f, 2.4f, 4.8f, 6.5f,
                        BAR(14)*SEC_PER_ROW+1.5f,
                        BAR(51)*SEC_PER_ROW+1.5f,
                        BAR(85)*SEC_PER_ROW+1.5f
                    };
                    static const char *names[] = {
                        "intro0.bmp", "intro1.bmp", "intro2.bmp", "intro3.bmp",
                        "caption0.bmp", "caption1.bmp", "caption2.bmp"
                    };
                    int shotSample;
                    for (shotSample = 0; shotSample < (int)(sizeof(seconds)/sizeof(seconds[0])); shotSample++) {
                        renderFrame((double)seconds[shotSample] / SEC_PER_ROW, outRTV, ow, oh);
                        ID3D11DeviceContext_CopyResource(g_ctx, (ID3D11Resource *)stage,
                                                        (ID3D11Resource *)out);
                        if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage, 0,
                                                   D3D11_MAP_READ, 0, &mm) >= 0) {
                            dumpBmp(names[shotSample], (const unsigned char *)mm.pData,
                                    ow, oh, (int)mm.RowPitch);
                            ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)stage, 0);
                        } else fails++;
                    }
                }
                renderFrame(mid, outRTV, ow, oh);
                ID3D11DeviceContext_CopyResource(g_ctx, (ID3D11Resource *)stage,
                                                 (ID3D11Resource *)out);
                if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage, 0,
                                            D3D11_MAP_READ, 0, &mm) >= 0) {
                    nm[0]='s'; nm[1]='h'; nm[2]='t';
                    nm[3]=(char)('0' + sh / 10); nm[4]=(char)('0' + sh % 10);
                    nm[5]='.'; nm[6]='b'; nm[7]='m'; nm[8]='p'; nm[9]=0;
                    dumpBmp(nm, (const unsigned char *)mm.pData, ow, oh,
                            (int)mm.RowPitch);

                    /* TITLE SAFE. The sign-off is the author's domain and
                       email address - crt.fyi and hi@crt.fyi -
                       it sits in the bottom-left corner, and the outro closes
                       a letterbox over exactly that corner - so this is the
                       one piece of type in the demo that a change to the matte
                       schedule can silently cut in half, three seconds from
                       the end where nobody is watching during development.
                       Measured rather than asserted: find the bar, find the
                       lowest stroke, and require daylight between them. */
                    if (s->scene == SC_SIGNOFF) {
                        const unsigned char *pp =
                            (const unsigned char *)mm.pData;
                        int y2, x2, bar = oh, lowest = -1, lim = ow / 3;
                        for (y2 = oh - 1; y2 >= oh / 2; y2--) {
                            int alive = 0;
                            for (x2 = 0; x2 < ow && !alive; x2 += 11) {
                                const unsigned char *q = pp +
                                    (size_t)y2 * mm.RowPitch + x2 * 4;
                                if (q[0] + q[1] + q[2] > 6) alive = 1;
                            }
                            if (alive) { bar = y2 + 1; break; }
                        }
                        /* well above the dither floor, which peaks near 150 */
                        for (y2 = 0; y2 < oh; y2++) {
                            int hits2 = 0;
                            for (x2 = 0; x2 < lim; x2++) {
                                const unsigned char *q = pp +
                                    (size_t)y2 * mm.RowPitch + x2 * 4;
                                if (q[0] + q[1] + q[2] > 320) hits2++;
                            }
                            if (hits2 >= 2) lowest = y2;
                        }
                        logs("\r\n  title safe:\r\n    picture ends at line ");
                        logi(bar * g_vh / oh);
                        logs(", the sign-off ends at ");
                        logi(lowest < 0 ? -1 : lowest * g_vh / oh);
                        logs("\r\n");
                        if (lowest < 0) {
                            logs("    the sign-off is not drawn at all\r\n");
                            fails++;
                        } else if (bar - lowest < 4 * oh / g_vh) {
                            logs("    it runs into the matte\r\n"); fails++;
                        } else {
                            logs("    clears the matte by ");
                            logi((bar - lowest) * g_vh / oh);
                            logs(" lines, ok\r\n");
                        }
                    }
                    ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)stage, 0);
                } else fails++;

                logs("    "); if (sh < 10) logs(" "); logi(sh);
                logs("  bar "); logi(s->start / ROWS_PER_BAR + 1);
                logs(".");     logi((s->start % ROWS_PER_BAR) / ROWS_PER_BEAT + 1);
                logs("  ");    logf2((float)(end - (double)s->start) * SEC_PER_ROW);
                logs("s  ");   logs(camName(s->cam));
                logs("  ");    logs(scName(s->scene));
                logs("  <- "); logs(trName(s->trans));

                /* Does this cut land on anything the music is doing? The
                   edit and the song are two separate tables, and the only
                   thing that stops them drifting apart is checking. */
                {
                    int o = s->start / SNG_ROWS;
                    int r = s->start % SNG_ROWS;
                    int gt = 0, so = 0, dr = 0, k;
                    if (o >= 0 && o < SNG_ORDERS) {
                        for (k = 0; k < SNG_ROWS; k++) {
                            int q = o * SNG_ROWS + k;
                            if (g_sqGtr[q]  >= 0) gt++;
                            if (g_sqSolo[q] >= 0) so++;
                            if (g_sqDrum[q] !=  0) dr++;
                        }
                        logs("   [song ord "); logi(o);
                        logs(" row ");         logi(r);
                        logs(": gtr ");        logi(gt);
                        logs(" solo ");        logi(so);
                        logs(" drum ");        logi(dr);
                        /* a cut on a bar line is worth flagging - it is the
                           only place a hard cut reads as intentional */
                        logs(r % ROWS_PER_BAR == 0 ? "  ON THE BAR]" : "  offbeat]");
                    }
                }
                logs("\r\n");
            }
            logs("\r\n");
        }


    /* THE STUTTER, proved rather than assumed. A quantised clock is exactly
       the kind of feature that can be wired up wrong and still look plausible
       in motion, so this pins it down: two different moments inside the same
       quantisation window must render the SAME picture, and a moment in the
       next window must render a different one. Both halves matter - without
       the second, a stutter that froze the shot completely would pass.

       Sampled clear of the shot's own transition, because a dissolve or a
       whip is driven by the true row and would differ between the two frames
       no matter how well the stutter works. */
    if (i == 0) {
        int sh5, bad = 0, tested = 0;
        logs("\r\n  stutter:\r\n");
        for (sh5 = 0; sh5 < NSHOTS; sh5++) {
            const Shot *st = &g_shots[sh5];
            double base, q;
            unsigned a1 = 0, a2 = 0, a3 = 0, a4 = 0;
            int k;
            if (st->stutter <= 0.0f) continue;
            tested++;
            q = (double)st->stutter;
            base = (double)st->start + (double)st->transRows + 0.001;
            /* onto the start of a whole window, so the three samples below
               land where they are meant to */
            base = (double)st->start
                 + q * (double)(__int64)((base - (double)st->start) / q + 1.0);

            /* 0.2 and 0.8 of a window are the same held frame; 1.2 is the
               next one. 4.2 is far enough away that ANY moving scene must
               have changed by then - it is what separates "the stutter is
               broken" from "this shot was not moving in the first place",
               which need opposite fixes. */
            for (k = 0; k < 4; k++) {
                double at = base + q * (k == 0 ? 0.2 : (k == 1 ? 0.8 :
                                       (k == 2 ? 1.2 : 4.2)));
                D3D11_MAPPED_SUBRESOURCE ms;
                unsigned h = 2166136261u;
                renderFrame(at, outRTV, ow, oh);
                ID3D11DeviceContext_CopyResource(g_ctx,
                    (ID3D11Resource *)stage, (ID3D11Resource *)out);
                if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage, 0,
                                            D3D11_MAP_READ, 0, &ms) >= 0) {
                    int x3, y3;
                    for (y3 = 0; y3 < oh; y3 += 3)
                        for (x3 = 0; x3 < ow; x3 += 3) {
                            const unsigned char *qq =
                                (const unsigned char *)ms.pData +
                                (size_t)y3 * ms.RowPitch + x3 * 4;
                            h = (h ^ qq[0]) * 16777619u;
                            h = (h ^ qq[1]) * 16777619u;
                            h = (h ^ qq[2]) * 16777619u;
                        }
                    ID3D11DeviceContext_Unmap(g_ctx,
                                              (ID3D11Resource *)stage, 0);
                } else bad++;
                if (k == 0) a1 = h; else if (k == 1) a2 = h;
                else if (k == 2) a3 = h; else a4 = h;
            }

            logs("    shot "); logi(sh5);
            logs(" bar "); logi(st->start / ROWS_PER_BAR + 1);
            logs(", every "); logi((int)(st->stutter * 1000.0f + 0.5f));
            logs(" thousandths of a row: ");
            if (a1 != a2) { logs("HELD FRAMES DIFFER"); bad++; }
            else if (a2 == a3 && a3 == a4) {
                logs("the shot is static - the stutter is wasted here"); bad++;
            } else if (a2 == a3) {
                logs("the scene moves slower than the stutter"); bad++;
            } else logs("holds, then advances");
            logs("\r\n");
        }
        if (!tested) { logs("    no shot in the edit stutters\r\n"); }
        fails += bad;
    }

        ID3D11Texture2D_Release(stage);         stage = 0;
        ID3D11RenderTargetView_Release(outRTV); outRTV = 0;
        ID3D11Texture2D_Release(out);           out = 0;
    }

    /* ---- what a frame costs ------------------------------------------ */
    {
        LARGE_INTEGER f0, t0, t1;
        D3D11_MAPPED_SUBRESOURCE mb;
        const int N = 120;
        int b, ow = 1920, oh = 1080;

        createSceneTargets(ow, oh);
        memset(&td, 0, sizeof(td));
        td.Width = (UINT)ow; td.Height = (UINT)oh;
        td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &out) >= 0 &&
            ID3D11Device_CreateRenderTargetView(g_dev, (ID3D11Resource *)out,
                                                0, &outRTV) >= 0) {
            td.Usage = D3D11_USAGE_STAGING;
            td.BindFlags = 0;
            td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &stage) >= 0) {
                renderFrame((double)BAR(8), outRTV, ow, oh);   /* warm up */
                ID3D11DeviceContext_CopyResource(g_ctx, (ID3D11Resource *)stage,
                                                 (ID3D11Resource *)out);
                if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage, 0,
                                            D3D11_MAP_READ, 0, &mb) >= 0)
                    ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)stage, 0);

                /* PER SHOT, not averaged. A mean over the whole edit hides
                   the frame that actually decides whether this drops on
                   someone else's machine - and the expensive frames are
                   exactly the ones that matter, because a dissolve renders
                   TWO scenes and the demo has dissolves between heavy ones.
                   Each shot is rendered in a batch so one readback amortises
                   over the batch instead of the sync dominating it. */
                {
                    const int BATCH = 24;
                    double worstUs = 0.0, sumUs = 0.0;
                    int worst = 0, sh2;
                    QueryPerformanceFrequency(&f0);
                    for (sh2 = 0; sh2 < NSHOTS; sh2++) {
                        double mid = (double)g_shots[sh2].start + 4.0;
                        double us;
                        QueryPerformanceCounter(&t0);
                        for (b = 0; b < BATCH; b++)
                            renderFrame(mid, outRTV, ow, oh);
                        ID3D11DeviceContext_CopyResource(g_ctx,
                            (ID3D11Resource *)stage, (ID3D11Resource *)out);
                        if (ID3D11DeviceContext_Map(g_ctx,
                                (ID3D11Resource *)stage, 0,
                                D3D11_MAP_READ, 0, &mb) >= 0)
                            ID3D11DeviceContext_Unmap(g_ctx,
                                (ID3D11Resource *)stage, 0);
                        QueryPerformanceCounter(&t1);
                        us = (double)(t1.QuadPart - t0.QuadPart) * 1000000.0 /
                             (double)f0.QuadPart / (double)BATCH;
                        sumUs += us;
                        if (us > worstUs) { worstUs = us; worst = sh2; }
                    }
                    logs("  1920x1080 frame cost:  mean ");
                    logi((int)(sumUs / (double)NSHOTS + 0.5));
                    logs(" us   WORST ");
                    logi((int)(worstUs + 0.5));
                    logs(" us  (shot ");   logi(worst);
                    logs(", ");            logs(scName(g_shots[worst].scene));
                    logs(", ");            logs(trName(g_shots[worst].trans));
                    logs(")\r\n  the worst frame is ");
                    logi((int)(worstUs * 100.0 / 16667.0 + 0.5));
                    logs("% of a 60 fps budget\r\n");
                    if (worstUs > 16667.0 * 0.5) {
                        logs("  OVER HALF THE BUDGET on one frame\r\n");
                        fails++;
                    }
                }
                ID3D11Texture2D_Release(stage); stage = 0;
            }
            ID3D11RenderTargetView_Release(outRTV); outRTV = 0;
            ID3D11Texture2D_Release(out); out = 0;
        }
    }

    /* The clock. Everything on screen is placed by row, and the row index in
       the shipping build comes from waveOutGetPosition, so confirm the two
       ends of that conversion agree. */
    {
        static const int PROBE[] = { 0, 5000, 80000, 960000, 7679999 };
        int q;
        logs("\r\n  clock: ");
        logi(SPR); logs(" samples per row at "); logi(SRATE);
        logs(" Hz, song is "); logi(SONG_ROWS); logs(" rows\r\n");
        for (q = 0; q < (int)(sizeof(PROBE) / sizeof(PROBE[0])); q++) {
            int smp = PROBE[q];
            int row = smp / SPR;
            int sht = findShot((double)row);
            logs("    sample "); logi(smp);
            logs(" -> row ");    logi(row);
            logs(" (bar ");      logi(row / ROWS_PER_BAR + 1);
            logs(") -> shot ");  logi(sht);
            logs(" ");           logs(scName(g_shots[sht].scene));
            logs("\r\n");
        }
        if (SONG_ROWS * SPR != SNG_ORDERS * SNG_ROWS * SPR) {
            logs("    MISMATCH: the edit and the song disagree on length\r\n");
            fails++;
        }
    }

    /* ---- prove the sync ring lines up ---------------------------------
       This is the one thing in the demo that can be silently wrong. If the
       ring is read at the wrong sample index the picture answers the music
       early or late by a tenth of a second, which looks like nothing in a
       still and like a badly dubbed film in motion - and no test that only
       asks "did a value arrive" would catch it.

       So: walk forward through the song, and at rows where the arrangement
       SAYS a kick is playing, read the ring back at that row's sample index
       and check the channel is actually lit. The two sides come from
       different places - one from the baked note table, one from the synth's
       own envelopes - so agreement means the indexing is right.

       The walk matters. The ring holds 743 ms on purpose: it is a window,
       not a recording. Rendering the whole song first and then probing the
       start reads a ring that has wrapped four hundred times, which is what
       the first version of this test did and why it reported everything
       misaligned. */
    {
        static short scratch[BUFFRAMES * 2];
        SyncFrame sf;
        __int64 gen = 0;
        int probe, lit = 0, tested = 0, mism = 0;

        logs("\r\n  sync ring:\r\n");
        for (probe = 0; probe < SNG_ORDERS; probe += 6) {
            int k, kicks = 0, solos = 0, firstKick = -1;
            __int64 smp, want;

            for (k = 0; k < SNG_ROWS; k++) {
                int q = probe * SNG_ROWS + k;
                if (g_sqDrum[q] == 1 || g_sqDrum[q] == 6 || g_sqDrum[q] == 7) {
                    kicks++;
                    if (firstKick < 0) firstKick = k;
                }
                if (g_sqSolo[q] >= 0) solos++;
            }
            smp  = ((__int64)probe * SNG_ROWS + (firstKick < 0 ? 0 : firstKick)) * SPR;
            want = smp + SPR * 2;
            while (gen < want) {
                renderAudio(scratch, BUFFRAMES);
                gen += BUFFRAMES;
            }
            g_syncR = smp >> 8;
            syncRead(smp + 512, &sf);
            tested++;

            logs("    order "); if (probe < 10) logs(" "); logi(probe);
            logs(":  table says kick x"); logi(kicks);
            logs(" solo x");              logi(solos);
            logs("    ring reads kick ");  logi((int)(sf.kick * 100.0f));
            logs(" solo ");                logi((int)(sf.solo * 100.0f));
            if (kicks > 0 && sf.kick < 0.02f) { logs("   MISSED"); mism++; }
            else if (kicks > 0)               { lit++; }
            logs("\r\n");
        }
        logs("    "); logi(lit); logs(" of "); logi(tested - 1);
        logs(" patterns with a kick answered on the right sample");
        if (mism) { logs(", "); logi(mism); logs(" MISALIGNED"); fails += mism; }
        logs("\r\n");
    }

    /* ---- does the mesh path draw anything at all -----------------------
       The cat is a black silhouette in a dark corridor, so "I cannot see it"
       and "it is not being drawn" look identical in a still. This asks the
       narrow question instead: bind the mesh, draw it alone into a cleared
       target with no scene behind it, and count the pixels that changed. */
    {
        MeshCB mc;
        ID3D11ShaderResourceView *srv[2];
        D3D11_MAPPED_SUBRESOURCE mm;
        SceneCB sc;
        int ow = 640, oh = 360, hits = 0;

        logs("\r\n  mesh path:\r\n    objects: vs ");
        logs(g_vsMesh ? "ok" : "NULL");
        logs("  ps ");   logs(g_psMesh ? "ok" : "NULL");
        logs("  pos ");  logs(g_catPos ? "ok" : "NULL");
        logs("  idx ");  logs(g_catIdx ? "ok" : "NULL");
        logs("  cb ");   logs(g_cbMesh ? "ok" : "NULL");
        logs("\r\n");

        createSceneTargets(ow, oh);
        memset(&td, 0, sizeof(td));
        td.Width = (UINT)ow; td.Height = (UINT)oh;
        td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &out) >= 0 &&
            ID3D11Device_CreateRenderTargetView(g_dev, (ID3D11Resource *)out,
                                                0, &outRTV) >= 0) {
            td.Usage = D3D11_USAGE_STAGING;
            td.BindFlags = 0;
            td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &stage) >= 0) {
                float clr[4] = { 0.0f, 0.0f, 0.0f, 1.0f };

                /* a camera four units back, looking at the origin */
                memset(&sc, 0, sizeof(sc));
                sc.t[2] = 1.0f;
                sc.t[3] = (float)ow / (float)oh;
                sc.cam[0] = 0.0f; sc.cam[1] = 0.0f; sc.cam[2] = -4.0f;
                sc.cam[3] = 0.62f;
                sc.dir[2] = 1.0f;
                upload(g_cbScene, &sc, sizeof(sc));

                memset(&mc, 0, sizeof(mc));
                mc.model[3] = 1.0f;          /* at the origin, scale 1 */
                mc.anim[1] = (float)RCAT_NF;
                mc.anim[2] = RCAT_QS;
                mc.misc[0] = (float)RCAT_NV;
                mc.misc[3] = 1.0f;           /* fully lit, not a silhouette */
                upload(g_cbMesh, &mc, sizeof(mc));

                ID3D11DeviceContext_ClearRenderTargetView(g_ctx, outRTV, clr);
                ID3D11DeviceContext_ClearDepthStencilView(g_ctx, g_depthDSV,
                                                          D3D11_CLEAR_DEPTH, 0.0f, 0);
                ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 1, &outRTV, g_depthDSV);
                ID3D11DeviceContext_OMSetDepthStencilState(g_ctx, g_dsMesh, 0);
                setViewport(ow, oh);
                ID3D11DeviceContext_IASetPrimitiveTopology(g_ctx,
                    D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
                ID3D11DeviceContext_IASetInputLayout(g_ctx, 0);
                srv[0] = g_catPos; srv[1] = g_catIdx;
                ID3D11DeviceContext_VSSetShaderResources(g_ctx, 0, 2, srv);
                ID3D11DeviceContext_VSSetShader(g_ctx, g_vsMesh, 0, 0);
                ID3D11DeviceContext_PSSetShader(g_ctx, g_psMesh, 0, 0);
                ID3D11DeviceContext_VSSetConstantBuffers(g_ctx, 0, 1, &g_cbScene);
                ID3D11DeviceContext_VSSetConstantBuffers(g_ctx, 1, 1, &g_cbMesh);
                ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 0, 1, &g_cbScene);
                ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 1, 1, &g_cbMesh);
                ID3D11DeviceContext_Draw(g_ctx, RCAT_NT * 3, 0);

                ID3D11DeviceContext_CopyResource(g_ctx, (ID3D11Resource *)stage,
                                                 (ID3D11Resource *)out);
                if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage, 0,
                                            D3D11_MAP_READ, 0, &mm) >= 0) {
                    int x, y;
                    for (y = 0; y < oh; y++)
                        for (x = 0; x < ow; x++) {
                            const unsigned char *q =
                                (const unsigned char *)mm.pData +
                                (size_t)y * mm.RowPitch + x * 4;
                            if (q[0] + q[1] + q[2] > 8) hits++;
                        }
                    dumpBmp("catonly.bmp", (const unsigned char *)mm.pData,
                            ow, oh, (int)mm.RowPitch);
                    ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)stage, 0);
                }
                ID3D11Texture2D_Release(stage); stage = 0;
            }
            ID3D11RenderTargetView_Release(outRTV); outRTV = 0;
            ID3D11Texture2D_Release(out); out = 0;
        }
        logs("    the cat alone on black: "); logi(hits);
        logs(" lit pixels of "); logi(ow * oh);
        if (!hits) { logs("   NOTHING DREW"); fails++; }
        logs("\r\n");

        /* the vertex data itself, so a bad SRV can be told from a bad shader */
        {
            int lo = 32767, hi = -32768, k;
            for (k = 0; k < RCAT_NV * 3; k++) {
                if (g_rcatV[k] < lo) lo = g_rcatV[k];
                if (g_rcatV[k] > hi) hi = g_rcatV[k];
            }
            logs("    frame 0 vertex range "); logi(lo); logs(" .. "); logi(hi);
            logs("  x quant = "); logi((int)(hi * RCAT_QS * 1000.0f));
            logs(" thousandths of a unit\r\n");
            logs("    first index "); logi((int)g_rcatI[0]);
            logs("  last index ");    logi((int)g_rcatI[RCAT_NT * 3 - 1]);
            logs("  of "); logi(RCAT_NV); logs(" vertices\r\n");
        }
    }

    /* ---- photosensitivity --------------------------------------------
       A flash is a luminance transition over about a tenth of full scale
       affecting more than a quarter of the screen; more than three of them
       in any one second is the guideline threshold. This demo has flash cuts
       and a strobing wind-up, so this is not a hypothetical.

       It has already caught one real problem. The flash used to decay as
       (1-u) squared over a single row, which is 16% of scale per frame - so
       ONE flash registered as six transitions, and the three flash cuts in
       the wind-up came out at seven in a second. The decay is linear over
       two rows now, at 6.6% per frame: one transition on the cut, where it
       belongs, and nothing on the way down.

       Measured on a 64x36 reduction at 60 fps, which is what the eye
       integrates rather than what any single pixel does. */
    {
        static unsigned char lumA[64 * 36], lumB[64 * 36];
        unsigned char *cur = lumA, *prv = lumB;
        int f, worst = 0, worstAt = 0, total = 0;
        int fps = 60, nfr = (int)((__int64)SONG_ROWS * SPR * 60 / SRATE);
        int ow = 640, oh = 360;

        createSceneTargets(ow, oh);
        memset(&td, 0, sizeof(td));
        td.Width = (UINT)ow; td.Height = (UINT)oh;
        td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &out) >= 0 &&
            ID3D11Device_CreateRenderTargetView(g_dev, (ID3D11Resource *)out,
                                                0, &outRTV) >= 0) {
            td.Usage = D3D11_USAGE_STAGING;
            td.BindFlags = 0;
            td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &stage) >= 0) {
                int lastSec = -1, inSec = 0;
                for (f = 0; f < nfr; f++) {
                    D3D11_MAPPED_SUBRESOURCE mm;
                    double row = (double)f * (double)SRATE /
                                 ((double)fps * (double)SPR);
                    int x, y, up = 0, dn = 0, sec2;

                    renderFrame(row, outRTV, ow, oh);
                    ID3D11DeviceContext_CopyResource(g_ctx,
                        (ID3D11Resource *)stage, (ID3D11Resource *)out);
                    if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage,
                            0, D3D11_MAP_READ, 0, &mm) < 0) continue;
                    for (y = 0; y < 36; y++)
                        for (x = 0; x < 64; x++) {
                            const unsigned char *q =
                                (const unsigned char *)mm.pData +
                                (size_t)(y * oh / 36) * mm.RowPitch +
                                (size_t)(x * ow / 64) * 4;
                            cur[y * 64 + x] = (unsigned char)
                                ((q[2] * 77 + q[1] * 150 + q[0] * 29) >> 8);
                        }
                    ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)stage, 0);

                    if (f > 0) {
                        for (x = 0; x < 64 * 36; x++) {
                            int dlt = (int)cur[x] - (int)prv[x];
                            if (dlt >  26) up++;
                            else if (dlt < -26) dn++;
                        }
                        if ((up > dn ? up : dn) * 4 > 64 * 36) {
                            total++;
                            inSec++;
                        }
                    }
                    sec2 = f / fps;
                    if (sec2 != lastSec) {
                        if (inSec > worst) { worst = inSec; worstAt = lastSec; }
                        inSec = 0; lastSec = sec2;
                    }
                    { unsigned char *t2 = prv; prv = cur; cur = t2; }
                }
                ID3D11Texture2D_Release(stage); stage = 0;
            }
            ID3D11RenderTargetView_Release(outRTV); outRTV = 0;
            ID3D11Texture2D_Release(out); out = 0;
        }

        logs("\r\n  photosensitivity:\r\n    ");
        logi(total); logs(" qualifying transitions in the whole demo, worst ");
        logi(worst); logs(" in one second (at "); logi(worstAt);
        logs(" s)\r\n    ");
        if (worst > 3) {
            logs("OVER the guideline of 3 per second"); fails++;
        } else {
            logs("within the guideline of 3 per second");
        }
        logs("\r\n");
    }

    /* The shot table is hand written, and a table nobody checks is a table
       with a typo in it. These are the mistakes that produce a black frame
       or a camera at infinity rather than a compile error. */
    {
        int sh3, bad = 0, logos = 0;
        logs("\r\n  shot table:\r\n");
        for (sh3 = 0; sh3 < NSHOTS; sh3++) {
            const Shot *a = &g_shots[sh3];
            const Shot *b = (sh3 + 1 < NSHOTS) ? &g_shots[sh3 + 1] : 0;
            if (a->scene == SC_LOGO) logos++;
            if (a->scene == SC_EYE || a->scene == SC_FRAMES ||
                a->scene == SC_SIGNOFF ||
                a->scene == SC_POWEROFF) {
                logs("    flat scene in 3D-only edit\r\n"); bad++;
            }
            if (a->scene >= SC_COUNT) {
                logs("    shot "); logi(sh3); logs(": scene out of range\r\n");
                bad++;
            }
            if (b && b->start <= a->start) {
                logs("    shot "); logi(sh3);
                logs(": starts at or after the next one\r\n"); bad++;
            }
            if (b && a->transRows > (b->start - a->start)) {
                logs("    shot "); logi(sh3);
                logs(": its transition outlasts the shot\r\n"); bad++;
            }
            if (a->stutter < 0.0f || a->stutter > 4.0f) {
                logs("    shot "); logi(sh3);
                logs(": stutter out of range\r\n"); bad++;
            }
            if (a->fov <= 0.0f || a->fov > 2.0f) {
                logs("    shot "); logi(sh3); logs(": fov out of range\r\n");
                bad++;
            }
            {   /* a look-at equal to the eye leaves normalize() with a zero
                   vector, and every pixel of that shot becomes NaN */
                float dx = a->at[0] - a->eye[0];
                float dy = a->at[1] - a->eye[1];
                float dz = a->at[2] - a->eye[2];
                if (dx * dx + dy * dy + dz * dz < 1e-6f) {
                    logs("    shot "); logi(sh3);
                    logs(": looks at its own eye position\r\n"); bad++;
                }
            }
        }
        if (!bad) logs("    ok, "); else logs("    ");
        if (logos != 1 || g_shots[1].scene != SC_LOGO ||
            g_shots[1].start != BAR(3)) {
            logs("    3D logo must occur exactly once, immediately after the opening tube\r\n"); bad++;
        }
        logi(NSHOTS); logs(" shots, "); logi(bad); logs(" problems\r\n");
        fails += bad;
    }

    /* The grade and the matte are schedules, and a schedule nobody checks
       drifts away from the arrangement it was written against. These are the
       mistakes that do not produce a compile error: a palette authored and
       never reached, a key out of order so a whole section takes the wrong
       look, or a matte that does not land back where it started and so puts
       a jump cut nobody wrote at the loop point. */
    {
        int i2, bad = 0, used = 0;
        logs("\r\n  grade schedule:\r\n");

        for (i2 = 1; i2 < GRADE_KEYS; i2++)
            if (g_gradeKeys[i2].row <= g_gradeKeys[i2 - 1].row) {
                logs("    key "); logi(i2); logs(": out of order\r\n"); bad++;
            }
        for (i2 = 0; i2 < GRADE_KEYS; i2++)
            if (g_gradeKeys[i2].grade >= GR_COUNT ||
                g_gradeKeys[i2].row < 0 || g_gradeKeys[i2].row >= SONG_ROWS) {
                logs("    key "); logi(i2); logs(": out of range\r\n"); bad++;
            }

        /* Which palettes the finished edit actually reaches, and for how
           long. A grade that no shot resolves to is dead weight in a demo
           that counts its bytes. */
        for (i2 = 0; i2 < GR_COUNT; i2++) {
            int sh4, shots = 0, rows = 0;
            for (sh4 = 0; sh4 < NSHOTS; sh4++) {
                if (gradeFor(&g_shots[sh4]) != &g_grades[i2]) continue;
                shots++;
                rows += ((sh4 + 1 < NSHOTS) ? g_shots[sh4 + 1].start
                                            : SONG_ROWS) - g_shots[sh4].start;
            }
            logs("    "); logs(grName(i2));
            logs(": "); logi(shots); logs(" shots, ");
            logi(rows * SPR / SRATE); logs(" s\r\n");
            if (shots) used++;
            else { logs("      never reached\r\n"); bad++; }
        }
        logs("    "); logi(used); logs(" of "); logi(GR_COUNT);
        logs(" palettes reached, "); logi(bad); logs(" problems\r\n");
        fails += bad;
    }

    {
        int i2, bad = 0;
        float d = matteAt((double)(SONG_ROWS - 1) + 0.999) - matteAt(0.0);
        if (d < 0.0f) d = -d;

        logs("\r\n  matte:\r\n");
        for (i2 = 0; i2 < MATTE_KEYS; i2++) {
            logs("    bar "); logi(g_mattes[i2].row / ROWS_PER_BAR + 1);
            logs(": ");       logi((int)(g_mattes[i2].bars * 1000.0f + 0.5f));
            logs(" thousandths over "); logi(g_mattes[i2].rows);
            logs(" rows\r\n");
            if (g_mattes[i2].bars < 0.0f || g_mattes[i2].bars > 0.25f) {
                logs("      out of range\r\n"); bad++;
            }
            if (i2 && g_mattes[i2].row <= g_mattes[i2 - 1].row) {
                logs("      out of order\r\n"); bad++;
            }
            if (i2 && g_mattes[i2 - 1].row + g_mattes[i2 - 1].rows
                        > g_mattes[i2].row) {
                logs("      its move outlasts the gap to the next key\r\n");
                bad++;
            }
        }
        /* The demo loops. If the outro does not close the bars back to
           exactly where the cold open opens them, the wrap is a jump nobody
           wrote - and it lands on the first frame, where it is most visible. */
        logs("    loop wrap differs by ");
        logi((int)(d * 1000.0f + 0.5f)); logs(" thousandths\r\n");
        if (d > 0.002f) { logs("      the matte jumps at the loop\r\n"); bad++; }
        if (!bad) logs("    ok\r\n");
        fails += bad;
    }

    logs("\r\nfailures: "); logi(fails); logs("\r\n");
    f = CreateFileA("gputest.txt", GENERIC_WRITE, 0, 0, CREATE_ALWAYS, 0, 0);
    if (f != INVALID_HANDLE_VALUE) {
        WriteFile(f, g_log, (DWORD)g_logN, &wr, 0);
        CloseHandle(f);
    }
    ExitProcess(fails ? 1 : 0);
}
#endif  /* OFFLINE */

/* --------------------------------------------------------------------------
   video export
   --------------------------------------------------------------------------
   The whole demo to stdout as raw BGRA, faster than real time, so a two and
   a half minute capture never has to be watched to be made. Piped into
   ffmpeg by makevideo.bat.

   The sync layer is what makes this exact rather than approximate. There is
   no sound card here, so instead of asking the driver what has played, the
   renderer GENERATES audio up to each frame's sample position and reads the
   ring at that same index - which is the identical arithmetic the shipping
   build does, with waveOutGetPosition swapped for a counter. The capture is
   therefore frame-for-frame what the demo looks like, not a re-timing of it.

   Set CRTK_WAVONLY to emit only the soundtrack and exit.
   -------------------------------------------------------------------------- */
#ifdef VIDEO
#define VIDW 1280
#define VIDH 720
#define VIDFPS 60

static short g_vidPcm[BUFFRAMES * 2];

static void writeAll(HANDLE file, const void *data, DWORD bytes)
{
    const unsigned char *p = (const unsigned char *)data;
    while (bytes) {
        DWORD written = 0;
        if (!WriteFile(file, p, bytes, &written, 0) || !written) ExitProcess(2);
        p += written;
        bytes -= written;
    }
}

static void wavOut(void)
{
    HANDLE f = CreateFileA("dump.wav", GENERIC_WRITE, 0, 0, CREATE_ALWAYS, 0, 0);
    __int64 total = (__int64)SONG_ROWS * SPR;
    __int64 done = 0;
    unsigned char h[44];
    unsigned int  bytes = (unsigned int)(total * 4);
    if (f == INVALID_HANDLE_VALUE) ExitProcess(2);
    memset(h, 0, sizeof(h));
    h[0]='R'; h[1]='I'; h[2]='F'; h[3]='F';
    *(unsigned int *)(h + 4) = bytes + 36;
    h[8]='W'; h[9]='A'; h[10]='V'; h[11]='E';
    h[12]='f'; h[13]='m'; h[14]='t'; h[15]=' ';
    *(unsigned int   *)(h + 16) = 16;
    *(unsigned short *)(h + 20) = 1;
    *(unsigned short *)(h + 22) = 2;
    *(unsigned int   *)(h + 24) = SRATE;
    *(unsigned int   *)(h + 28) = SRATE * 4;
    *(unsigned short *)(h + 32) = 4;
    *(unsigned short *)(h + 34) = 16;
    h[36]='d'; h[37]='a'; h[38]='t'; h[39]='a';
    *(unsigned int *)(h + 40) = bytes;
    writeAll(f, h, 44);

    while (done < total) {
        int n = BUFFRAMES;
        if (done + n > total) n = (int)(total - done);
        renderAudio(g_vidPcm, n);
        writeAll(f, g_vidPcm, (DWORD)(n * 4));
        done += n;
    }
    CloseHandle(f);
}

static void videoMain(void)
{
    ID3D11Texture2D *out = 0, *stage = 0;
    ID3D11RenderTargetView *rtv = 0;
    D3D11_TEXTURE2D_DESC td;
    HANDLE so;
    __int64 frames = ((__int64)SONG_ROWS * SPR * VIDFPS + SRATE - 1) / SRATE;
    __int64 fr;
    char env[8];

    if (GetEnvironmentVariableA("CRTK_WAVONLY", env, sizeof(env)) > 0) {
        wavOut();
        ExitProcess(0);
    }

    if (!createPipeline()) ExitProcess(1);
    if (!createSceneTargets(VIDW, VIDH)) ExitProcess(1);

    memset(&td, 0, sizeof(td));
    td.Width = VIDW; td.Height = VIDH;
    td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &out) < 0) ExitProcess(1);
    if (ID3D11Device_CreateRenderTargetView(g_dev, (ID3D11Resource *)out, 0,
                                            &rtv) < 0) ExitProcess(1);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (ID3D11Device_CreateTexture2D(g_dev, &td, 0, &stage) < 0) ExitProcess(1);

    so = GetStdHandle(STD_OUTPUT_HANDLE);

    for (fr = 0; fr < frames; fr++) {
        D3D11_MAPPED_SUBRESOURCE m;
        __int64 smp = fr * SRATE / VIDFPS;

        /* Generate the music up to this frame, then read the ring at the
           same index - the identical arithmetic the shipping build does. */
        while (g_genSamples < smp) renderAudio(g_vidPcm, BUFFRAMES);
        syncRead(smp, &g_syncNow);
        syncFollow(&g_syncNow, 1.0f / (float)VIDFPS);

        g_row = (double)smp / (double)SPR;
        renderFrame(g_row, rtv, VIDW, VIDH);

        ID3D11DeviceContext_CopyResource(g_ctx, (ID3D11Resource *)stage,
                                         (ID3D11Resource *)out);
        if (ID3D11DeviceContext_Map(g_ctx, (ID3D11Resource *)stage, 0,
                                    D3D11_MAP_READ, 0, &m) >= 0) {
            int y;
            /* The staging pitch is whatever the driver chose, so write row by
               row rather than assuming it equals the width. */
            for (y = 0; y < VIDH; y++)
                writeAll(so, (const unsigned char *)m.pData +
                              (size_t)y * m.RowPitch, VIDW * 4);
            ID3D11DeviceContext_Unmap(g_ctx, (ID3D11Resource *)stage, 0);
        } else ExitProcess(3);
    }
    ExitProcess(0);
}
#endif  /* VIDEO */
