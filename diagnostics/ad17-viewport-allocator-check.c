/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Build with ad17-viewport-allocator-check.S for Win32.
 * Run original-Core3D patched-Core3D original-ADVPCB patched-ADVPCB.
 * Compare actual rounded extents and ABI with the original routines, without
 * Altium initialization or proprietary test fixtures.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <xmmintrin.h>
extern void run_allocator(void*,const void*,void*,int,void*);
static unsigned cases;
static unsigned extent(int count,int minimum){if(count<=minimum)return minimum;return (((unsigned)count+3)&~(unsigned)(minimum+3))+minimum;}
static int compare(void*old,void*fast,const BYTE*src,BYTE*a,BYTE*b,int count,unsigned bytes,unsigned region,unsigned pad){
 __attribute__((aligned(16))) BYTE ra[544],rb[544];
 memset(a,0xa7,region);memset(b,0xa7,region);
 run_allocator(old,src,a+pad,count,ra);run_allocator(fast,src,b+pad,count,rb);
 if(memcmp(a,b,region)||memcmp(src,b+pad,bytes)||memcmp(ra,rb,12)||memcmp(ra+16,rb+16,4)||
    memcmp(ra+32,rb+32,2)||((*(WORD*)(ra+34)^*(WORD*)(rb+34))&0x3800)||ra[36]!=rb[36]||
    memcmp(ra+64,rb+64,10)||memcmp(ra+80,rb+80,10)||memcmp(ra+96,rb+96,10)||
    memcmp(ra+56,rb+56,4)||memcmp(ra+192,rb+192,128)){
  printf("FAIL count%d rounded%u pad%u bytes%d regs%d xmm%d\n",count,bytes,pad,memcmp(a,b,region),memcmp(ra,rb,12),memcmp(ra+192,rb+192,128));return 1;
 }
 cases++;return 0;
}
struct guard{BYTE*pages,*data;unsigned accessible;};
static struct guard guarded(unsigned n){SYSTEM_INFO si;GetSystemInfo(&si);struct guard g={0};g.accessible=((n+64+si.dwPageSize-1)/si.dwPageSize)*si.dwPageSize;g.pages=VirtualAlloc(NULL,g.accessible+si.dwPageSize,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);DWORD old;if(!g.pages||!VirtualProtect(g.pages+g.accessible,si.dwPageSize,PAGE_NOACCESS,&old))ExitProcess(90);g.data=g.pages+g.accessible-n;return g;}
static void fill(BYTE*p,unsigned n){for(unsigned i=0;i<n;i++)p[i]=(i*53+(i>>7))&255;}
int main(int argc,char**argv){if(argc!=5)return 1;const DWORD entries[2][4]={{0x53e0,0x182c4,0x19938,0x182f4},{0x5760,0x1d2a0,0x1ec10,0x1d2d0}};
 const int special[]={-1,-8,-1024,255,256,257,511,512,513,1023,1024,1025};
 WORD savedcw;__asm__ volatile("fnstcw %0":"=m"(savedcw));unsigned savedcsr=_mm_getcsr();
 for(unsigned module=0;module<2;module++){
  HMODULE a=LoadLibraryExA(argv[1+module*2],NULL,DONT_RESOLVE_DLL_REFERENCES),b=LoadLibraryExA(argv[2+module*2],NULL,DONT_RESOLVE_DLL_REFERENCES);if(!a||!b||a==b)return 2;
  for(unsigned entry=0;entry<4;entry++){
   BYTE*old=(BYTE*)a+entries[module][entry],*fast=(BYTE*)b+entries[module][entry];if(old[0]!=0x83||fast[0]!=0xe9)return 3;
   int minimum=entry==3?4:12;BYTE src[4096],left[4096],right[4096];fill(src,sizeof(src));
   for(int pc=0;pc<3;pc++)for(int rc=0;rc<4;rc++)for(unsigned k=0;k<129+sizeof(special)/sizeof(*special);k++)for(unsigned align=0;align<16;align++){
    int n=k<129?(int)k:special[k-129];unsigned bytes=extent(n,minimum);
    WORD cw=0x7f|(pc==0?0:pc==1?0x200:0x300)|(rc<<10);__asm__ volatile("fnclex; fldcw %0"::"m"(cw));_mm_setcsr(0x1f80|((align&3)<<13)|((align&4)?0x8040:0));
    if(compare(old,fast,src+align,left,right,n,bytes,sizeof(left),(align*7+k)%16)){printf("module%u entry%u pc%d rc%d align%u\n",module,entry,pc,rc,align);return 4;}
   }
   __asm__ volatile("fnclex; fldcw %0"::"m"(savedcw));_mm_setcsr(savedcsr);
   const int large[]={0,1,12,13,31,32,33,127,128,129,255,256,257,1023,1024,1025,4095,4096,4097,65535,65536,65537,1048575,1048576};
   for(unsigned k=0;k<sizeof(large)/sizeof(*large);k++){
    int n=large[k];unsigned bytes=extent(n,minimum);
    struct guard s=guarded(bytes),l=guarded(bytes),r=guarded(bytes);fill(s.data,bytes);unsigned head=64;
    if(compare(old,fast,s.data,l.data-head,r.data-head,n,bytes,bytes+head,head)){printf("guard module%u entry%u\n",module,entry);return 5;}
    VirtualFree(s.pages,0,MEM_RELEASE);VirtualFree(l.pages,0,MEM_RELEASE);VirtualFree(r.pages,0,MEM_RELEASE);
   }
  }
  FreeLibrary(a);FreeLibrary(b);
 }
 __asm__ volatile("fnclex; fldcw %0"::"m"(savedcw));_mm_setcsr(savedcsr);
 printf("PASS %u rounded allocator copies, all helper entries, guards, alignments, precision, rounding and ABI\n",cases);return 0;
}
