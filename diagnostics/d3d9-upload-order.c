/* Dynamic ring upload regression: queued draws, partial and nested VB/IB locks.
 * Build i686-w64-mingw32-gcc d3d9-upload-order.c -O2 -ld3d9 -lgdi32 -o upload-order.exe
 * Run with ALTIUM_D3D9_UPLOADS=0 and =1. Uses its own hidden test window only. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define BYTES (2 * 1024 * 1024)
#define CHECK(x) do { HRESULT hr_=(x); if (FAILED(hr_)) { printf("FAIL line %d hr=%08lx\n",__LINE__,(long)hr_); return 1; } } while (0)
struct vertex { float x,y,z,rhw; DWORD colour; };
static DWORD expected[64];
static void quad(struct vertex *p, int tile, DWORD colour) {
    float x=(tile%8)*16+1, y=(tile/8)*16+1;
    const float dx[4]={0,14,0,14},dy[4]={0,0,14,14};
    for(int i=0;i<4;i++) p[i]=(struct vertex){x+dx[i],y+dy[i],0,1,colour};
    expected[tile]=colour&0xffffff;
}
static LRESULT CALLBACK proc(HWND h,UINT m,WPARAM w,LPARAM l) { return DefWindowProcA(h,m,w,l); }
int main(void) {
    WNDCLASSA wc={0}; wc.lpfnWndProc=proc; wc.hInstance=GetModuleHandleA(0); wc.lpszClassName="UploadOrder";
    RegisterClassA(&wc);
    HWND h=CreateWindowA(wc.lpszClassName,"Upload order test",WS_OVERLAPPEDWINDOW,40,80,160,180,0,0,wc.hInstance,0);
    IDirect3D9 *d=Direct3DCreate9(D3D_SDK_VERSION); if(!d) return 2;
    D3DPRESENT_PARAMETERS pp={0}; pp.Windowed=TRUE; pp.SwapEffect=D3DSWAPEFFECT_DISCARD; pp.hDeviceWindow=h;
    pp.BackBufferWidth=128; pp.BackBufferHeight=128; pp.BackBufferFormat=D3DFMT_X8R8G8B8; pp.PresentationInterval=D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *dev=0;
    CHECK(IDirect3D9_CreateDevice(d,0,D3DDEVTYPE_HAL,h,D3DCREATE_HARDWARE_VERTEXPROCESSING,&pp,&dev));
    IDirect3DVertexBuffer9 *vb=0; IDirect3DIndexBuffer9 *ib=0;
    CHECK(IDirect3DDevice9_CreateVertexBuffer(dev,BYTES,D3DUSAGE_DYNAMIC|D3DUSAGE_WRITEONLY,D3DFVF_XYZRHW|D3DFVF_DIFFUSE,D3DPOOL_DEFAULT,&vb,0));
    CHECK(IDirect3DDevice9_CreateIndexBuffer(dev,BYTES,D3DUSAGE_DYNAMIC|D3DUSAGE_WRITEONLY,D3DFMT_INDEX16,D3DPOOL_DEFAULT,&ib,0));
    CHECK(IDirect3DDevice9_SetFVF(dev,D3DFVF_XYZRHW|D3DFVF_DIFFUSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_LIGHTING,FALSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_CULLMODE,D3DCULL_NONE));
    CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_ZENABLE,FALSE));
    CHECK(IDirect3DDevice9_SetIndices(dev,ib));
    CHECK(IDirect3DDevice9_Clear(dev,0,0,D3DCLEAR_TARGET,0,1,0));
    CHECK(IDirect3DDevice9_BeginScene(dev));
    for(int tile=0;tile<64;tile++) {
        struct vertex *p; WORD *indices; const WORD pattern[6]={0,1,2,2,1,3};
        UINT offset=(tile%4)*4096; DWORD flags=tile%4?D3DLOCK_NOOVERWRITE:D3DLOCK_DISCARD;
        CHECK(IDirect3DVertexBuffer9_Lock(vb,offset,4*sizeof(*p),(void **)&p,flags));
        quad(p,tile,0xff000000|((tile*3719+0x104080)&0xffffff));
        CHECK(IDirect3DVertexBuffer9_Unlock(vb));
        CHECK(IDirect3DIndexBuffer9_Lock(ib,offset,sizeof(pattern),(void **)&indices,flags));
        memcpy(indices,pattern,sizeof(pattern));
        CHECK(IDirect3DIndexBuffer9_Unlock(ib));
        CHECK(IDirect3DDevice9_SetStreamSource(dev,0,vb,offset,sizeof(*p)));
        CHECK(IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLELIST,0,0,4,offset/2,2));
    }
    /* A partial discard at the end must orphan safely without reading beyond
     * the small upload snapshot. Subsequent writes use fresh, disjoint ranges. */
    for(int tile=56;tile<58;tile++) {
        struct vertex *p; WORD *indices; const WORD pattern[6]={0,1,2,2,1,3};
        UINT vo=tile==56?BYTES-4*sizeof(*p):128;
        UINT io=tile==56?BYTES-sizeof(pattern):128;
        DWORD flags=tile==56?D3DLOCK_DISCARD:D3DLOCK_NOOVERWRITE;
        CHECK(IDirect3DVertexBuffer9_Lock(vb,vo,4*sizeof(*p),(void **)&p,flags));
        quad(p,tile,tile==56?0xffe07020:0xff2080e0);
        CHECK(IDirect3DVertexBuffer9_Unlock(vb));
        CHECK(IDirect3DIndexBuffer9_Lock(ib,io,sizeof(pattern),(void **)&indices,flags));
        memcpy(indices,pattern,sizeof(pattern));
        CHECK(IDirect3DIndexBuffer9_Unlock(ib));
        CHECK(IDirect3DDevice9_SetStreamSource(dev,0,vb,vo,sizeof(*p)));
        CHECK(IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLELIST,0,0,4,io/2,2));
    }
    char opt[8]={0}; GetEnvironmentVariableA("ALTIUM_D3D9_UPLOADS",opt,sizeof(opt));
    int nested=!strcmp(opt,"1");
    /* Disjoint nested ranges: write after the first Unlock, commit on the last. */
    struct vertex *a,*b; WORD *ia,*ibits; const WORD idx[6]={0,1,2,2,1,3};
    if (nested) {
    CHECK(IDirect3DVertexBuffer9_Lock(vb,0,4*sizeof(*a),(void **)&a,D3DLOCK_DISCARD));
    CHECK(IDirect3DVertexBuffer9_Lock(vb,8192,4*sizeof(*b),(void **)&b,0));
    quad(a,62,0xffe03090);
    CHECK(IDirect3DVertexBuffer9_Unlock(vb));
    quad(b,63,0xff20e050);
    if(nested && IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLELIST,0,0,4,0,2)!=D3DERR_INVALIDCALL) {
        puts("FAIL draw accepted while shadow vertex buffer locked"); return 1;
    }
    CHECK(IDirect3DVertexBuffer9_Unlock(vb));
    CHECK(IDirect3DIndexBuffer9_Lock(ib,0,sizeof(idx),(void **)&ia,D3DLOCK_DISCARD));
    CHECK(IDirect3DIndexBuffer9_Lock(ib,8192,sizeof(idx),(void **)&ibits,D3DLOCK_NOOVERWRITE));
    memcpy(ia,idx,sizeof(idx)); CHECK(IDirect3DIndexBuffer9_Unlock(ib)); memcpy(ibits,idx,sizeof(idx));
    if(!strcmp(opt,"1") && IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLELIST,0,0,4,0,2)!=D3DERR_INVALIDCALL) {
        puts("FAIL draw accepted while shadow index buffer locked"); return 1;
    }
    CHECK(IDirect3DIndexBuffer9_Unlock(ib));
    CHECK(IDirect3DDevice9_SetStreamSource(dev,0,vb,0,sizeof(*a)));
    CHECK(IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLELIST,0,0,4,0,2));
    CHECK(IDirect3DDevice9_SetStreamSource(dev,0,vb,8192,sizeof(*a)));
    CHECK(IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLELIST,0,0,4,4096,2));
    }
    /* The earlier discard invalidates the old index range in every mode. */
    CHECK(IDirect3DIndexBuffer9_Lock(ib,0,sizeof(idx),(void **)&ia,D3DLOCK_DISCARD));
    memcpy(ia,idx,sizeof(idx));
    CHECK(IDirect3DIndexBuffer9_Unlock(ib));
    /* A non-nested ordinary lock uses the legacy map; then switch back to uploads. */
    CHECK(IDirect3DVertexBuffer9_Lock(vb,16384,4*sizeof(*a),(void **)&a,0));
    quad(a,60,0xff4080c0);
    CHECK(IDirect3DVertexBuffer9_Unlock(vb));
    CHECK(IDirect3DVertexBuffer9_Lock(vb,24576,4*sizeof(*b),(void **)&b,D3DLOCK_NOOVERWRITE));
    quad(b,61,0xffc08040);
    CHECK(IDirect3DVertexBuffer9_Unlock(vb));
    for(int tile=60;tile<62;tile++) {
        CHECK(IDirect3DDevice9_SetStreamSource(dev,0,vb,tile==60?16384:24576,sizeof(*a)));
        CHECK(IDirect3DDevice9_DrawIndexedPrimitive(dev,D3DPT_TRIANGLELIST,0,0,4,0,2));
    }
    /* Size zero extends to the end; non-indexed draw checks that path too. */
    CHECK(IDirect3DVertexBuffer9_Lock(vb,BYTES-3*sizeof(*a),0,(void **)&a,D3DLOCK_NOOVERWRITE));
    struct vertex q[4]; quad(q,59,0xff90d020); a[0]=q[0]; a[1]=q[1]; a[2]=q[2];
    CHECK(IDirect3DVertexBuffer9_Unlock(vb));
    CHECK(IDirect3DDevice9_SetStreamSource(dev,0,vb,BYTES-3*sizeof(*a),sizeof(*a)));
    CHECK(IDirect3DDevice9_DrawPrimitive(dev,D3DPT_TRIANGLELIST,0,1));
    if(!strcmp(opt,"1")) {
        if(IDirect3DVertexBuffer9_Lock(vb,BYTES+1,1,(void **)&a,D3DLOCK_NOOVERWRITE)!=D3DERR_INVALIDCALL
            ||IDirect3DIndexBuffer9_Lock(ib,BYTES-2,4,(void **)&ia,D3DLOCK_NOOVERWRITE)!=D3DERR_INVALIDCALL) {
            puts("FAIL out-of-bounds lock accepted"); return 1;
        }
    }
    CHECK(IDirect3DDevice9_EndScene(dev));
    IDirect3DSurface9 *rt=0,*copy=0; D3DLOCKED_RECT bits;
    CHECK(IDirect3DDevice9_GetRenderTarget(dev,0,&rt));
    CHECK(IDirect3DDevice9_CreateOffscreenPlainSurface(dev,128,128,D3DFMT_X8R8G8B8,D3DPOOL_SYSTEMMEM,&copy,0));
    CHECK(IDirect3DDevice9_GetRenderTargetData(dev,rt,copy)); CHECK(IDirect3DSurface9_LockRect(copy,&bits,0,D3DLOCK_READONLY));
    int failures=0;
    for(int tile=0;tile<64;tile++) {
        int x=(tile%8)*16+4,y=(tile/8)*16+4;
        DWORD pixel=*(DWORD *)((BYTE *)bits.pBits+y*bits.Pitch+x*4)&0xffffff;
        if(pixel!=expected[tile]) { printf("FAIL tile %d expected=%06lx actual=%06lx\n",tile,(long)expected[tile],(long)pixel); failures++; }
    }
    IDirect3DSurface9_UnlockRect(copy); IDirect3DSurface9_Release(copy); IDirect3DSurface9_Release(rt);
    IDirect3DVertexBuffer9_Release(vb); IDirect3DIndexBuffer9_Release(ib); IDirect3DDevice9_Release(dev); IDirect3D9_Release(d); DestroyWindow(h);
    printf("%s: 64 queued draws, nested/partial VB and IB uploads, mode=%s\n",failures?"FAIL":"PASS",opt);
    return failures?1:0;
}
