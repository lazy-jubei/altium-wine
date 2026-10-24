/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Compile this file with ad17-viewport-grid-batch-check.S for Win32.
 * Run ORIGINAL_ADVPCB PATCHED_ADVPCB [stress]. Modules are mapped without
 * initialization; a local return at the loop exit isolates the original oracle.
 * Guarded output, caller scratch/ABI and interface ownership are compared.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <xmmintrin.h>
extern void run_grid_batch(void*,void*,int,void*);
static BYTE holder[64],buffer[80];
static void *holder_vtable[20],*buffer_vtable[20];
static unsigned calls,reads,adds,releases;
static BYTE *fake_core;
static int missing_module;
static HMODULE WINAPI module(LPCWSTR name){if(wcscmp(name,L"Core3D.dll"))ExitProcess(95);SetLastError(0x5a17);return missing_module?NULL:(HMODULE)fake_core;}
static void writable(void *at,unsigned bytes){DWORD old;if(!VirtualProtect(at,bytes,PAGE_EXECUTE_READWRITE,&old))ExitProcess(96);}
static BYTE *iface(void){return buffer+0x2c;}
static unsigned WINAPI add(void *obj){if(obj!=buffer)ExitProcess(91);adds++;return ++*(unsigned*)(buffer+4);}
static unsigned WINAPI release(void *obj){if(obj!=buffer)ExitProcess(92);releases++;return --*(unsigned*)(buffer+4);}
__attribute__((regparm(2)))static void get(void *obj,void **out){
 if(obj!=holder)ExitProcess(93);calls++;BYTE *p=*(BYTE**)(holder+0xc);
 if(p){void**vt=*(void***)p;((unsigned(WINAPI*)(void*))vt[1])(p);}
 void *old=*out;*out=p;if(old){void**vt=*(void***)old;((unsigned(WINAPI*)(void*))vt[2])(old);}
}
__attribute__((regparm(1)))static void *raw(void *obj){if(obj!=buffer)ExitProcess(94);reads++;return *(void**)(buffer+0x20);}
static uint32_t rnd(uint32_t*s){*s^=*s<<13;*s^=*s>>17;*s^=*s<<5;return *s;}
static void put32(BYTE*f,int off,uint32_t v){memcpy(f+off,&v,4);}
static void ext80(BYTE*p,uint64_t mant,uint16_t exp){memcpy(p,&mant,8);memcpy(p+8,&exp,2);}
static void thunk(BYTE *at,int adjust,void *fn,int stack){
 unsigned n;if(stack){BYTE p[]={0x83,0x44,0x24,4,(BYTE)adjust};memcpy(at,p,5);n=5;}
 else{BYTE p[]={0x83,0xc0,(BYTE)adjust};memcpy(at,p,3);n=3;}
 at[n]=0xe9;*(int32_t*)(at+n+1)=(BYTE*)fn-(at+n+5);
}
struct guarded{BYTE *pages,*data;SIZE_T total;};
static struct guarded allocation(unsigned bytes){
 SYSTEM_INFO si;GetSystemInfo(&si);SIZE_T n=((bytes+64+si.dwPageSize-1)/si.dwPageSize)*si.dwPageSize;if(!n)n=si.dwPageSize;
 struct guarded g={0};g.total=n+si.dwPageSize;g.pages=VirtualAlloc(NULL,g.total,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);DWORD old;
 if(!g.pages||!VirtualProtect(g.pages+n,si.dwPageSize,PAGE_NOACCESS,&old))ExitProcess(90);
 g.data=g.pages+n-bytes;return g;
}
int main(int argc,char **argv){
 if(argc!=3&&argc!=4)return 1;int stress=argc==4;HMODULE original=LoadLibraryExA(argv[1],NULL,DONT_RESOLVE_DLL_REFERENCES),trial=LoadLibraryExA(argv[2],NULL,DONT_RESOLVE_DLL_REFERENCES);if(!original||!trial)return 2;
 BYTE *fast=(BYTE*)trial+0xfd10ae,*oracle=(BYTE*)original+0xfd10ae;
 BYTE *core=VirtualAlloc(NULL,0x530000,MEM_COMMIT|MEM_RESERVE,PAGE_EXECUTE_READWRITE);if(!core)return 4;
 fake_core=core;writable((BYTE*)original+0xfd11be,1);writable((BYTE*)trial+0xfd11be,1);
 *((BYTE*)original+0xfd11be)=0xc3;*((BYTE*)trial+0xfd11be)=0xc3;
 writable((BYTE*)trial+0x27ec0d0,4);*(void**)((BYTE*)trial+0x27ec0d0)=module;
 unsigned fast_count=0,fallback_count=0;
 thunk(core+0x503fe1,-0x18,get,0);thunk(core+0x503ff1,-0x18,get,0);thunk(core+0x529e45,-0x2c,raw,0);thunk(core+0x529ee3,-0x2c,add,1);thunk(core+0x529eed,-0x2c,release,1);
 holder_vtable[9]=core+0x503fe1;buffer_vtable[1]=core+0x529ee3;buffer_vtable[2]=core+0x529eed;buffer_vtable[12]=core+0x529e45;
 *(void**)(holder+0x18)=holder_vtable;*(void**)(buffer+0x2c)=buffer_vtable;*(void**)(holder+0xc)=iface();
 uint32_t seed=42;unsigned cases=0;unsigned short savedcw;__asm__ volatile("fnstcw %0":"=m"(savedcw));unsigned savedcsr=_mm_getcsr();
 for(int pc=0;pc<3;pc++)for(int rc=0;rc<(stress?1:4);rc++)for(int mx=0;mx<(stress?1:4);mx++)for(int mode=0;mode<(stress?1:13);mode++)for(unsigned i=0;i<(stress?4096u:32u);i++){
  int rows=(int)(rnd(&seed)%(stress?33:5)),cols=(int)(rnd(&seed)%(stress?97:9));if(mode==4)rows=-1;if(mode==5)cols=-1;
  unsigned count=rows<0||cols<0?0:(rows+1)*(cols+1),bytes=count*28;
  struct guarded ga=allocation(bytes),gb=allocation(bytes);memset(ga.data-64,0xbd,bytes+64);memset(gb.data-64,0xbd,bytes+64);
  BYTE a[1024],b[1024],*f=a+512;
  for(unsigned j=0;j<sizeof(a);j+=4)put32(a,j,rnd(&seed));
  put32(f,-4,(DWORD)(uintptr_t)(holder+0x18));put32(f,-0xf4,mode==8?(DWORD)(uintptr_t)iface():0);put32(f,-0x24,0);put32(f,-0x54,cols);
  ext80(f-0x40,0x8000000000000000ULL,0x3fff);ext80(f-0x30,0,mode==11?0x8000:0);
  if(mode==1){ext80(f-0x40,0,0);ext80(f-0x30,0x8000000000000000ULL,0x3fff);}
  if(mode==2)ext80(f-0x30,0x8000000000000000ULL,0x3ffe);
  if(mode==3)ext80(f-0x40,0xc000000000000000ULL,0x7fff);
  if(mode==9)put32(f,0x2c,0);
  if(mode==10)put32(f,0x20,0);
  memcpy(b,a,sizeof(a));
  *(unsigned*)(buffer+0x24)=mode==6?32:28;*(unsigned*)(buffer+0x28)=mode==7&&count?count-1:count;
  missing_module=mode==12;
  holder_vtable[9]=core+(mode==6?0x503ff1:0x503fe1);
  unsigned short cw=0x7f|(pc==0?0:pc==1?0x200:0x300)|(rc<<10);unsigned csr=0x1f80|(mx<<13)|((i&1)?0x8040:0);
  __attribute__((aligned(16))) BYTE ra[544],rb[544];
  for(int which=0;which<2;which++){
   calls=reads=adds=releases=0;*(unsigned*)(buffer+4)=mode==8?2:1;*(void**)(buffer+0x20)=which?gb.data:ga.data;
   __asm__ volatile("fnclex; fldcw %0"::"m"(cw));_mm_setcsr(csr);
   int is_fast=which&&rc==0&&mx==0&&(mode==0||mode==9||mode==10||mode==11);
   SetLastError(0x31415926);
   run_grid_batch(which?fast:oracle,which?b+512:a+512,rows,which?rb:ra);
   if(GetLastError()!=0x31415926){printf("FAIL last-error mode%d which%d\n",mode,which);return 8;}
   unsigned expected=is_fast?1:count;
   if(which){if(is_fast)fast_count++;else fallback_count++;}
   if(calls!=expected||reads!=expected||adds!=expected||releases!=(expected?expected-(mode==8?0:1):0)){printf("FAIL calls pc%d rc%d mx%d mode%d i%u which%d got%u/%u/%u/%u expected%u\n",pc,rc,mx,mode,i,which,calls,reads,adds,releases,expected);return 7;}
   if(*(unsigned*)(buffer+4)!=(count?2:mode==8?2:1)){printf("FAIL ownership pc%d rc%d mx%d mode%d i%u which%d refs%u n%u\n",pc,rc,mx,mode,i,which,*(unsigned*)(buffer+4),count);return 5;}
  }
  DWORD axa=((DWORD*)ra)[7],axb=((DWORD*)rb)[7];
  if(count){axa-=(DWORD)(uintptr_t)ga.data;axb-=(DWORD)(uintptr_t)gb.data;}
  if(memcmp(ga.data-64,gb.data-64,bytes+64)||memcmp(a,b,sizeof(a))||axa!=axb||memcmp(ra,rb,8)||memcmp(ra+16,rb+16,12)||
   memcmp(ra+32,rb+32,2)||((*(WORD*)(ra+34)^*(WORD*)(rb+34))&0x3800)||ra[36]!=rb[36]||memcmp(ra+64,rb+64,10)||memcmp(ra+80,rb+80,10)||memcmp(ra+96,rb+96,10)||memcmp(ra+192,rb+192,128)||((*(DWORD*)(ra+56)^*(DWORD*)(rb+56))&~63u)){
   printf("FAIL pc%d rc%d mx%d mode%d i%u n%u vertices%d frame%d ax%lx/%lx regs%d xmm%d\n",pc,rc,mx,mode,i,count,memcmp(ga.data-64,gb.data-64,bytes+64),memcmp(a,b,sizeof(a)),axa,axb,memcmp(ra+16,rb+16,12),memcmp(ra+192,rb+192,128));
   for(int j=0;j<1024;j++)if(a[j]!=b[j]){printf("frame offset%d old%02x new%02x\n",j-512,a[j],b[j]);if(j>512)break;}
   return 6;
  }
  VirtualFree(ga.pages,0,MEM_RELEASE);VirtualFree(gb.pages,0,MEM_RELEASE);cases++;
 }
 __asm__ volatile("fnclex; fldcw %0"::"m"(savedcw));_mm_setcsr(savedcsr);
 printf("PASS %u batch grids, guarded vertex buffers, frame/GPR/XMM/x87, rounding/precision, generic fallbacks; fast=%u fallback=%u\n",cases,fast_count,fallback_count);
 return 0;
}
