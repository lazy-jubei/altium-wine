/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Build with ad17-viewport-grid-check.S and run against original and patched ADVPCB.DLL.
 * No Altium initialization, project data or proprietary fixture is needed.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <xmmintrin.h>
extern void run_grid(void*,void*,void*,void*);
static uint32_t rnd(uint32_t *s){*s^=*s<<13;*s^=*s>>17;*s^=*s<<5;return *s;}
static void put32(unsigned char *f,int n,uint32_t v){memcpy(f+n,&v,4);}
static void ext80(unsigned char *p,uint64_t mant,uint16_t exp){memcpy(p,&mant,8);memcpy(p+8,&exp,2);}
static int check_grid(HMODULE original, HMODULE patched){
 unsigned char *old=VirtualAlloc(NULL,0x55,MEM_COMMIT|MEM_RESERVE,PAGE_EXECUTE_READWRITE);
 unsigned char *fast=VirtualAlloc(NULL,0x200,MEM_COMMIT|MEM_RESERVE,PAGE_EXECUTE_READWRITE);
 if(!old||!fast)return 1;
 unsigned char *entry=(unsigned char*)patched+0xfd1110;
 if(entry[0]!=0xe9)return 1;
 unsigned char *target=entry+5+*(int32_t*)(entry+1);
 memcpy(old,(unsigned char*)original+0xfd1110,0x54);old[0x54]=0xc3;
 memcpy(fast,target,0x111);
 if(fast[0xf8]!=0xe9||fast[0x10c]!=0xe9)return 1;
 /* End the isolated inline block at its continuation, without running its outer grid loop. */
 memset(fast+0xf8,0x90,5);fast[0xf8]=0xc3;
 *(int32_t*)(fast+0x10d)=0x120-0x111;memcpy(fast+0x120,old,0x55);
 unsigned char a[1024],b[1024];
 __attribute__((aligned(16))) unsigned char ra[544],rb[544];
 uint32_t seed=42,count=0;unsigned short savedcw;__asm__ volatile("fnstcw %0":"=m"(savedcw));unsigned savedcsr=_mm_getcsr();
 for(int pc=0;pc<3;pc++)for(int rc=0;rc<4;rc++)for(int mx=0;mx<4;mx++)for(int special=0;special<6;special++){
  unsigned short cw=0x7f|(pc==0?0:pc==1?0x200:0x300)|(rc<<10);unsigned csr=0x1f80|(mx<<13)|((special&1)?0x8040:0);
  __asm__ volatile("fnclex; fldcw %0"::"m"(cw));_mm_setcsr(csr);
  for(int i=0;i<5000;i++){
   for(int j=0;j<1024;j+=4)put32(a,j,rnd(&seed));unsigned char *f=a+512;
   ext80(f-0x40,0x8000000000000000ULL,0x3fff);ext80(f-0x30,0,special&1?0x8000:0);
   if(special==2)ext80(f-0x40,0x8000000000000000ULL,0xbfff);
   if(special==3)ext80(f-0x30,0x8000000000000000ULL,0x3fff);
   if(special==4)ext80(f-0x40,0xc000000000000000ULL,0x7fff);
   if(special==5)ext80(f-0x30,1,0);
   if(i<32){put32(f,-0xec,(i&1?0x80000000:0x7fffffff)+(i>>1));put32(f,0x18,(i&2?0x80000000:0x7fffffff)+(i>>2));}
   memcpy(b,a,sizeof(a));memset(ra,0,sizeof(ra));memset(rb,0,sizeof(rb));
   uint64_t outa=0,outb=0;run_grid(old,f,&outa,ra);run_grid(fast,b+512,&outb,rb);
   /* Pointers in EAX/EBP differ; all other GPRs, frame writes, x87 registers and XMM state must match. */
   if(outa!=outb||memcmp(a,b,sizeof(a))||memcmp(ra,rb,8)||memcmp(ra+16,rb+16,12)||
      memcmp(ra+32,rb+32,2)||memcmp(ra+36,rb+36,1)||memcmp(ra+64,rb+64,10)||memcmp(ra+192,rb+192,128)){
    printf("FAIL pc%d rc%d mx%d special%d i%d out=%016llx/%016llx frame=%d regs=%d st=%d xmm=%d\n",pc,rc,mx,special,i,(unsigned long long)outa,(unsigned long long)outb,memcmp(a,b,sizeof(a)),memcmp(ra+16,rb+16,12),memcmp(ra+64,rb+64,10),memcmp(ra+192,rb+192,128));return 2;
   }count++;
  }
 }
 __asm__ volatile("fnclex; fldcw %0"::"m"(savedcw));_mm_setcsr(savedcsr);
 printf("PASS %u exact grid transforms, frame writes, registers, precision and rounding modes\n",count);return 0;
}

static int check_distance(HMODULE original, HMODULE patched){
 typedef void (__attribute__((regparm(3))) *dist_fn)(float*,const float*,float*);
 dist_fn old=(dist_fn)((char*)original+0x7529c8),fast=(dist_fn)((char*)patched+0x7529c8);
 uint32_t seed=42,count=0;unsigned short savedcw;__asm__ volatile("fnstcw %0":"=m"(savedcw));unsigned savedcsr=_mm_getcsr();
 const uint32_t edge[]={0,0x80000000,1,0x80000001,0x007fffff,0x00800000,0x0c7fffff,0x0c800000,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7fc00000,0x7f800001,0x3f800000,0xbf800000};
 for(int pc=0;pc<3;pc++)for(int rc=0;rc<4;rc++)for(int mx=0;mx<4;mx++)for(int flags=0;flags<4;flags++){
  unsigned short cw=0x7f|(pc==0?0:pc==1?0x200:0x300)|(rc<<10);unsigned csr=0x1f80|(mx<<13)|((flags&1)?0x40:0)|((flags&2)?0x8000:0);
  __asm__ volatile("fnclex; fldcw %0"::"m"(cw));_mm_setcsr(csr);
  for(int alias=-1;alias<9;alias++)for(int i=0;i<1500;i++){
   union {uint32_t u[20];float f[20];} a,b;
   for(int j=0;j<20;j++){uint32_t v=rnd(&seed);a.u[j]=i<16?edge[(i+j)%16]:i<750?v:((v&0x807fffff)|((100+(v%60))<<23));}b=a;
   int output=alias<0?12:alias;old(a.f,a.f+6,a.f+output);fast(b.f,b.f+6,b.f+output);
   if(memcmp(&a,&b,sizeof(a))){printf("FAIL pc%d rc%d mx%d flags%d alias%d i%d\n",pc,rc,mx,flags,alias,i);for(int k=0;k<20;k++)if(a.u[k]!=b.u[k])printf("  %d %08x/%08x\n",k,a.u[k],b.u[k]);return 2;}count++;
  }
 }
 __asm__ volatile("fnclex; fldcw %0"::"m"(savedcw));_mm_setcsr(savedcsr);
 printf("PASS %u exact distance, alias, special value, precision and rounding comparisons\n",count);return 0;
}

static int check_move(HMODULE original, HMODULE patched){
 typedef void (__attribute__((regparm(3))) *move_fn)(const void *, void *, int);
 move_fn old_move=(move_fn)((char*)original+0x75f4),new_move=(move_fn)((char*)patched+0x75f4);
 unsigned char before[4096],after[4096];unsigned copies=0;
    const int negative[] = {-1, -8, -1024, INT32_MIN};
    for (unsigned i = 0; i < sizeof(negative) / sizeof(*negative); i++) {
        old_move(NULL, (void *)1, negative[i]);
        new_move(NULL, (void *)1, negative[i]);
        copies++;
    }
    for (int size = 0; size <= 1024; size++) {
        for (int shift = -33; shift <= 33; shift++) {
            for (int i = 0; i < 4096; i++) before[i] = after[i] = (i * 53 + size) & 255;
            old_move(before + 512, before + 512 + shift, size);
            new_move(after + 512, after + 512 + shift, size);
            if (memcmp(before, after, sizeof(before))) {
                printf("FAIL Move: size %d, overlap %d\n", size, shift);
                return 3;
            }
            copies++;
        }
    }
    for (int size = 1; size <= 256; size++) {
        for (int alignment = 0; alignment < 16; alignment++) {
            SYSTEM_INFO info;
            DWORD protection;
            unsigned char *pages, *src, *dst;
            GetSystemInfo(&info);
            pages = VirtualAlloc(NULL, info.dwPageSize * 3, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (!pages || !VirtualProtect(pages + info.dwPageSize, info.dwPageSize,
                                          PAGE_NOACCESS, &protection)) return 4;
            src = pages + info.dwPageSize - size;
            dst = pages + info.dwPageSize * 2 + alignment;
            for (int i = 0; i < size; i++) src[i] = (i * 19) & 255;
            new_move(src, dst, size);
            if (memcmp(src, dst, size)) return 4;
            VirtualFree(pages, 0, MEM_RELEASE);
            copies++;
        }
    }
    printf("PASS %u overlap, alignment, padding and guard-page copies\n", copies);
    return 0;
}

int main(int argc,char **argv){
 if(argc!=3)return 1;
 HMODULE original=LoadLibraryExA(argv[1],NULL,DONT_RESOLVE_DLL_REFERENCES);
 HMODULE patched=LoadLibraryExA(argv[2],NULL,DONT_RESOLVE_DLL_REFERENCES);
 if(!original||!patched||original==patched){printf("Cannot map separate modules: %lu\n",GetLastError());return 1;}
 int result=check_grid(original,patched);if(!result)result=check_distance(original,patched);if(!result)result=check_move(original,patched);
 FreeLibrary(patched);FreeLibrary(original);return result;
}
