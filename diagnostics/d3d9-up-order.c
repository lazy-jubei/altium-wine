/* Build: i686-w64-mingw32-gcc d3d9-up-order.c -O2 -ld3d9 -lgdi32 -o up-order.exe
 * Run with ALTIUM_D3D9_QUEUED_UP=0 and =1. Uses its own test window.
 * Queued UP upload regression: caller lifetime, changing strides, VB/IB wrap
 * and growth, 16/32-bit indices, nonzero min vertex, state reset and Reset. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { HRESULT hr_=(x); if(FAILED(hr_)){printf("FAIL line %d hr=%08lx\n",__LINE__,hr_);return 1;} }while(0)
struct vertex {float x,y,z,rhw;DWORD colour;};
static LRESULT CALLBACK proc(HWND h,UINT m,WPARAM w,LPARAM l){return DefWindowProcA(h,m,w,l);}
static void quad(BYTE *p,UINT stride,int tile,DWORD colour){
 float x=tile<0?-200:(tile%8)*16+1,y=tile<0?-200:(tile/8)*16+1;
 const float dx[4]={0,14,0,14},dy[4]={0,0,14,14};
 for(int i=0;i<4;i++){struct vertex v={x+dx[i],y+dy[i],0,1,colour};memcpy(p+i*stride,&v,sizeof(v));}
}
static int draw(IDirect3DDevice9 *dev,int tile,int mode,UINT stride,DWORD colour){
 BYTE data[8*40];memset(data,0,sizeof(data));
 if(!mode){quad(data,stride,tile,colour);CHECK(IDirect3DDevice9_DrawPrimitiveUP(dev,D3DPT_TRIANGLESTRIP,2,data,stride));}
 else{
   quad(data+2*stride,stride,tile,colour);
   WORD i16[6]={2,3,4,4,3,5};DWORD i32[6]={2,3,4,4,3,5};
   CHECK(IDirect3DDevice9_DrawIndexedPrimitiveUP(dev,D3DPT_TRIANGLELIST,2,4,2,mode==1?(void*)i16:(void*)i32,mode==1?D3DFMT_INDEX16:D3DFMT_INDEX32,data,stride));
   memset(i16,0,sizeof(i16));memset(i32,0,sizeof(i32));
 }
 /* Every stack source is overwritten before the next draw can execute. */
 memset(data,0,sizeof(data));
 IDirect3DVertexBuffer9 *stream=(void*)1;UINT offset,stride_out;
 CHECK(IDirect3DDevice9_GetStreamSource(dev,0,&stream,&offset,&stride_out));
 if(stream){puts("FAIL UP did not clear stream 0");IDirect3DVertexBuffer9_Release(stream);return 1;}
 if(mode){IDirect3DIndexBuffer9 *ib=(void*)1;CHECK(IDirect3DDevice9_GetIndices(dev,&ib));if(ib){puts("FAIL indexed UP did not clear indices");IDirect3DIndexBuffer9_Release(ib);return 1;}}
 return 0;
}
int main(void){
 WNDCLASSA wc={0};wc.lpfnWndProc=proc;wc.hInstance=GetModuleHandleA(0);wc.lpszClassName="DrawUPOrder";RegisterClassA(&wc);
 HWND h=CreateWindowA(wc.lpszClassName,"Draw UP order test",WS_OVERLAPPEDWINDOW|WS_VISIBLE,40,80,160,180,0,0,wc.hInstance,0);
 MSG msg;while(PeekMessageA(&msg,0,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageA(&msg);}
 IDirect3D9 *d=Direct3DCreate9(D3D_SDK_VERSION);if(!d)return 2;
 D3DPRESENT_PARAMETERS pp={0};pp.Windowed=TRUE;pp.SwapEffect=D3DSWAPEFFECT_DISCARD;pp.hDeviceWindow=h;pp.BackBufferWidth=pp.BackBufferHeight=128;
 pp.BackBufferFormat=D3DFMT_X8R8G8B8;pp.PresentationInterval=D3DPRESENT_INTERVAL_IMMEDIATE;
 IDirect3DDevice9 *dev=0;CHECK(IDirect3D9_CreateDevice(d,0,D3DDEVTYPE_HAL,h,D3DCREATE_HARDWARE_VERTEXPROCESSING|D3DCREATE_MULTITHREADED,&pp,&dev));
 CHECK(IDirect3DDevice9_SetFVF(dev,D3DFVF_XYZRHW|D3DFVF_DIFFUSE));CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_LIGHTING,FALSE));
 CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_CULLMODE,D3DCULL_NONE));CHECK(IDirect3DDevice9_SetRenderState(dev,D3DRS_ZENABLE,FALSE));
 CHECK(IDirect3DDevice9_Clear(dev,0,0,D3DCLEAR_TARGET,0,1,0));CHECK(IDirect3DDevice9_BeginScene(dev));
 DWORD expected[64];
 for(int tile=0;tile<64;tile++){expected[tile]=(tile*3719+0x204060)&0xffffff;if(draw(dev,tile,tile%3,20+(tile%6)*4,0xff000000|expected[tile]))return 1;}
 /* Cross the 512 KiB vertex ring several times without touching visible tiles. */
 for(int n=0;n<12000;n++)if(draw(dev,-1,n%3,20+(n%6)*4,0xff123456))return 1;
 /* Grow both rings; subsequent draws wrap the larger index ring. The first
  * six indices draw tile 63, the remaining triangles are offscreen/degenerate. */
 UINT vertex_count=50000,primitive_count=100000,stride=24;
 BYTE *vertices=calloc(vertex_count+2,stride);DWORD *indices=calloc(primitive_count*3,sizeof(*indices));if(!vertices||!indices)return 2;
 for(UINT n=0;n<vertex_count+2;n++){struct vertex v={-200,-200,0,1,0};memcpy(vertices+n*stride,&v,sizeof(v));}
 for(int pass=0;pass<3;pass++){
   expected[63]=(0xe01020+pass*0x2010)&0xffffff;quad(vertices+2*stride,stride,63,0xff000000|expected[63]);
   const DWORD idx[6]={2,3,4,4,3,5};memcpy(indices,idx,sizeof(idx));
   for(UINT n=6;n<primitive_count*3;n++)indices[n]=6;
   CHECK(IDirect3DDevice9_DrawIndexedPrimitiveUP(dev,D3DPT_TRIANGLELIST,2,vertex_count,primitive_count,indices,D3DFMT_INDEX32,vertices,stride));
 }
 memset(vertices,0,(vertex_count+2)*stride);memset(indices,0,primitive_count*3*sizeof(*indices));free(vertices);free(indices);
 for(int tile=48;tile<63;tile++){expected[tile]=(tile*9123+0x108090)&0xffffff;if(draw(dev,tile,tile%3,20+(tile%6)*4,0xff000000|expected[tile]))return 1;}
 CHECK(IDirect3DDevice9_EndScene(dev));
 IDirect3DSurface9 *rt=0,*copy=0;CHECK(IDirect3DDevice9_GetRenderTarget(dev,0,&rt));CHECK(IDirect3DDevice9_CreateOffscreenPlainSurface(dev,128,128,D3DFMT_X8R8G8B8,D3DPOOL_SYSTEMMEM,&copy,0));
 CHECK(IDirect3DDevice9_GetRenderTargetData(dev,rt,copy));D3DLOCKED_RECT map;CHECK(IDirect3DSurface9_LockRect(copy,&map,0,D3DLOCK_READONLY));
 int failures=0;for(int tile=0;tile<64;tile++){DWORD pixel=*(DWORD*)((BYTE*)map.pBits+((tile/8)*16+4)*map.Pitch+((tile%8)*16+4)*4)&0xffffff;if(pixel!=expected[tile]){printf("FAIL GPU tile %d expected=%06lx actual=%06lx\n",tile,expected[tile],pixel);failures++;}}
 CHECK(IDirect3DSurface9_UnlockRect(copy));IDirect3DSurface9_Release(copy);IDirect3DSurface9_Release(rt);
 CHECK(IDirect3DDevice9_Present(dev,0,0,0,0));CHECK(IDirect3DDevice9_Reset(dev,&pp));IDirect3DDevice9_Release(dev);IDirect3D9_Release(d);DestroyWindow(h);
 printf("%s: UP source lifetime, 16/32-bit indexed draws, strides, ring wraps/growth, state cleanup, reset\n",failures?"FAIL":"PASS");return failures?1:0;
}
