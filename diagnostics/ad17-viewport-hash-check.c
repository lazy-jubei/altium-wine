/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Build with i686-w64-mingw32-clang -O2; run with original and --geometry-hash Core3D DLLs.
 * Compares the original algorithm, including observable input aliases and guarded reads.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef void (__attribute__((regparm(3))) *hash_fn)(void*,const void*,int);
static uint32_t rnd(uint32_t *s){*s^=*s<<13;*s^=*s>>17;*s^=*s<<5;return *s;}
int main(int argc,char **argv){
 if(argc!=3)return 1;
 HMODULE mod=LoadLibraryExA(argv[1],NULL,DONT_RESOLVE_DLL_REFERENCES);
 HMODULE patched=LoadLibraryExA(argv[2],NULL,DONT_RESOLVE_DLL_REFERENCES);
 if(!mod||!patched||mod==patched)return 1;
 unsigned char a[8192],b[8192];uint32_t seed=42;unsigned checks=0;
 for(int fn=0;fn<2;fn++){
  hash_fn original=(hash_fn)((char*)mod+(fn?0x4fd33c:0x4fd280));
  hash_fn fast=(hash_fn)((char*)patched+(fn?0x4fd33c:0x4fd280));
  if(*(unsigned char*)fast!=0xe9){puts("Missing hash entry patch");return 1;}
  for(int n=-8;n<=2048;n++)for(int alias=-6;alias<=6;alias++){
   for(int i=0;i<8192;i+=4){uint32_t v=rnd(&seed);memcpy(a+i,&v,4);}memcpy(b,a,sizeof(a));
   int state=alias==-6?4096:512+alias;
   original(a+state,a+512,n);fast(b+state,b+512,n);
   if(memcmp(a,b,sizeof(a))){printf("FAIL fn%d n%d alias%d\n",fn,n,alias);return 2;}checks++;
  }
  original(NULL,NULL,0);fast(NULL,NULL,0);checks++;
  SYSTEM_INFO info;GetSystemInfo(&info);
  unsigned char *pages=VirtualAlloc(NULL,info.dwPageSize*2,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);DWORD prot;
  if(!pages||!VirtualProtect(pages+info.dwPageSize,info.dwPageSize,PAGE_NOACCESS,&prot))return 1;
  for(unsigned n=1;n<=info.dwPageSize;n++){
   uint32_t sa=rnd(&seed),sb=sa;for(unsigned i=0;i<n;i++)pages[info.dwPageSize-n+i]=(i*71+n)&255;
   original(&sa,pages+info.dwPageSize-n,n);fast(&sb,pages+info.dwPageSize-n,n);
   if(sa!=sb){printf("FAIL fn%d guard n%u\n",fn,n);return 3;}checks++;
  }VirtualFree(pages,0,MEM_RELEASE);
  LARGE_INTEGER f,t0,t1;QueryPerformanceFrequency(&f);memset(a,123,sizeof(a));
  for(int mode=0;mode<2;mode++){hash_fn call=mode?fast:original;uint32_t h=42;QueryPerformanceCounter(&t0);for(int i=0;i<20000;i++)call(&h,a,4096);QueryPerformanceCounter(&t1);printf("BENCH fn%d %s %.3f ms hash=%08x\n",fn,mode?"register":"original",(t1.QuadPart-t0.QuadPart)*1000.0/f.QuadPart,h);}

 }
 printf("PASS %u exact hash, overlap, zero/negative count and guard-page checks\n",checks);return 0;
}
