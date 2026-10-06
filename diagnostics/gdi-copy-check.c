/* GDI bitmap correctness and copy timing probe.
 * Copyright (c) 2026 lazy-jubei
 * SPDX-License-Identifier: LGPL-2.1-or-later
 * Checks actual pixels, clipping, raster operations and overlapping copies.
 * Timing output is a microbenchmark, not an Altium frame-rate measurement.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if(!(x)){printf("FAIL line %d: %s error=%lu\n",__LINE__,#x,GetLastError());exit(1);} }while(0)
typedef struct {HDC dc;HBITMAP bitmap,old;DWORD *bits;int w,h,topdown;} image;
static image create(int w,int h,int topdown) {
 BITMAPINFO b={0}; image a={0};
 b.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);b.bmiHeader.biWidth=w;b.bmiHeader.biHeight=topdown?-h:h;b.bmiHeader.biPlanes=1;b.bmiHeader.biBitCount=32;
 a.dc=CreateCompatibleDC(NULL);a.bitmap=CreateDIBSection(a.dc,&b,DIB_RGB_COLORS,(void**)&a.bits,NULL,0);
 CHECK(a.dc && a.bitmap && a.bits);a.old=SelectObject(a.dc,a.bitmap);a.w=w;a.h=h;a.topdown=topdown;return a;
}
static DWORD *pixel(image *a,int x,int y) {return a->bits+(a->topdown?y:a->h-1-y)*a->w+x;}
static void fill(image *a,int seed) {for(int y=0;y<a->h;y++)for(int x=0;x<a->w;x++)*pixel(a,x,y)=(DWORD)(seed+x*73+y*191)|0xff000000;}
static void destroy(image *a) {SelectObject(a->dc,a->old);DeleteObject(a->bitmap);DeleteDC(a->dc);}
static void check_rect(int sw,int dw,int st,int dt,int sx,int sy,int dx,int dy,int w,int h,int clip,DWORD rop) {
 image s=create(sw,103,st),d=create(dw,107,dt); fill(&s,199);fill(&d,773);
 DWORD *expected=malloc(dw*107*4);memcpy(expected,d.bits,dw*107*4);
 if(clip) CHECK(IntersectClipRect(d.dc,dx+3,dy+2,dx+w-4,dy+h-5)!=ERROR);
 CHECK(BitBlt(d.dc,dx,dy,w,h,s.dc,sx,sy,rop));GdiFlush();
 for(int y=0;y<107;y++)for(int x=0;x<dw;x++) {
  DWORD val=expected[(dt?y:106-y)*dw+x];
  if(x>=dx && x<dx+w && y>=dy && y<dy+h && (!clip || (x>=dx+3 && x<dx+w-4 && y>=dy+2 && y<dy+h-5))) {
   DWORD src=*pixel(&s,x-dx+sx,y-dy+sy);
   if(rop==SRCCOPY)val=src;else if(rop==SRCINVERT)val^=src;else if(rop==SRCAND)val&=src;else if(rop==SRCPAINT)val|=src;
  }
  if(*pixel(&d,x,y)!=val){printf("FAIL rectangle srcwidth=%d dstwidth=%d st=%d dt=%d clip=%d rop=%08lx pixel=%d,%d got=%08lx expected=%08lx\n",sw,dw,st,dt,clip,rop,x,y,*pixel(&d,x,y),val);exit(1);}
 }
 free(expected);destroy(&s);destroy(&d);
}
static void check_overlap(int top,int dx,int dy,int width,int height) {
 image d=create(width,height,top);fill(&d,93);DWORD *before=malloc((size_t)width*height*4);CHECK(before);memcpy(before,d.bits,(size_t)width*height*4);
 int margin=height>113?16:0;
 int sx=margin+(dx>0?0:-dx),sy=margin+(dy>0?0:-dy),tx=margin+(dx>0?dx:0),ty=margin+(dy>0?dy:0),w=width-2*margin-abs(dx),h=height-2*margin-abs(dy);
 CHECK(BitBlt(d.dc,tx,ty,w,h,d.dc,sx,sy,SRCCOPY));GdiFlush();
 for(int y=0;y<height;y++)for(int x=0;x<width;x++) {
  int ex=x,ey=y;if(x>=tx && x<tx+w && y>=ty && y<ty+h){ex=x-tx+sx;ey=y-ty+sy;}
  DWORD val=before[(top?ey:height-1-ey)*width+ex];CHECK(*pixel(&d,x,y)==val);
 }
 free(before);destroy(&d);
}
static void check_large_rect(int st,int dt,int clip) {
 image s=create(3003,1301,st),d=create(3051,1307,dt);fill(&s,173);fill(&d,419);
 DWORD *before=malloc((size_t)d.w*d.h*4);CHECK(before);memcpy(before,d.bits,(size_t)d.w*d.h*4);
 int sx=3,sy=5,dx=7,dy=11,w=2987,h=1273;
 if(clip)CHECK(IntersectClipRect(d.dc,dx+17,dy+13,dx+w-19,dy+h-23)!=ERROR);
 CHECK(BitBlt(d.dc,dx,dy,w,h,s.dc,sx,sy,SRCCOPY));GdiFlush();
 for(int y=0;y<d.h;y++)for(int x=0;x<d.w;x++) {
  DWORD expected=before[(dt?y:d.h-1-y)*d.w+x];
  if(x>=dx && x<dx+w && y>=dy && y<dy+h && (!clip || (x>=dx+17 && x<dx+w-19 && y>=dy+13 && y<dy+h-23)))expected=*pixel(&s,x-dx+sx,y-dy+sy);
  CHECK(*pixel(&d,x,y)==expected);
 }
 free(before);destroy(&s);destroy(&d);
}
static void check_fill(int bpp,int top,int full) {
 BITMAPINFO b={0};void *bits;int w=257,h=53,stride=((w*bpp+31)/32)*4;
 b.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);b.bmiHeader.biWidth=w;b.bmiHeader.biHeight=top?-h:h;b.bmiHeader.biPlanes=1;b.bmiHeader.biBitCount=bpp;
 HDC dc=CreateCompatibleDC(NULL);HBITMAP bitmap=CreateDIBSection(dc,&b,DIB_RGB_COLORS,&bits,NULL,0);CHECK(bitmap && bits);HGDIOBJ old=SelectObject(dc,bitmap);memset(bits,0xcd,stride*h);
 HBRUSH brush=CreateSolidBrush(RGB(31,93,171));HGDIOBJ oldbrush=SelectObject(dc,brush);
 CHECK(PatBlt(dc,full?0:3,full?0:2,full?w:249,full?h:47,PATCOPY));GdiFlush();
 DWORD val=0x001f5dab;WORD v16=((31>>3)<<10)|((93>>3)<<5)|(171>>3);
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){
  unsigned char *p=(unsigned char*)bits+(top?y:h-1-y)*stride+x*bpp/8;int inside=full || (x>=3 && x<252 && y>=2 && y<49);
  if(bpp==32) CHECK((*(DWORD*)p&0xffffff)==(inside?val:0xcdcdcd));
  else CHECK(*(WORD*)p==(inside?v16:0xcdcd));
 }
 for(int y=0;y<h;y++)for(int i=w*bpp/8;i<stride;i++)CHECK(((unsigned char*)bits)[y*stride+i]==0xcd);
 SelectObject(dc,oldbrush);DeleteObject(brush);SelectObject(dc,old);DeleteObject(bitmap);DeleteDC(dc);
}
int main(void) {
 for(int bpp=16;bpp<=32;bpp+=16)for(int top=0;top<2;top++)for(int full=0;full<2;full++)check_fill(bpp,top,full);
 DWORD rops[]={SRCCOPY,SRCINVERT,SRCAND,SRCPAINT};
 for(int st=0;st<2;st++)for(int dt=0;dt<2;dt++)for(int r=0;r<4;r++) {
  check_rect(263,269,st,dt,3,5,7,11,1,1,0,rops[r]);
  check_rect(256,256,st,dt,0,0,0,0,256,100,0,rops[r]);
  check_rect(263,269,st,dt,7,3,11,5,220,91,0,rops[r]);
  check_rect(263,269,st,dt,7,3,11,5,220,91,1,rops[r]);
 }
 for(int t=0;t<2;t++)for(int dy=-7;dy<=7;dy+=7)for(int dx=-5;dx<=5;dx+=5) {
  check_overlap(t,dx,dy,256,113);
  check_overlap(t,dx,dy,2049,769);
 }
 for(int st=0;st<2;st++)for(int dt=0;dt<2;dt++)for(int clip=0;clip<2;clip++)check_large_rect(st,dt,clip);
 image f=create(400,120,1);fill(&f,7);HFONT font=CreateFontA(-20,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,"Arial");
 HGDIOBJ old=SelectObject(f.dc,font);TEXTMETRICA m;SIZE size;CHECK(GetTextMetricsA(f.dc,&m));CHECK(m.tmHeight>10);CHECK(GetTextExtentPoint32A(f.dc,"ABC test",8,&size));CHECK(size.cx>30 && size.cy>10);CHECK(TextOutA(f.dc,10,10,"ABC test",8));GdiFlush();SelectObject(f.dc,old);DeleteObject(font);destroy(&f);
 for(int orientation=0;orientation<2;orientation++) {
  image a=create(2430,1250,1),b=create(2560,1250,orientation);fill(&a,9);fill(&b,12);
  LARGE_INTEGER freq,t0,t1;QueryPerformanceFrequency(&freq);QueryPerformanceCounter(&t0);
  for(int n=0;n<200;n++)CHECK(BitBlt(b.dc,0,0,2430,1250,a.dc,0,0,SRCCOPY));GdiFlush();QueryPerformanceCounter(&t1);
  printf("BitBlt orientation=%d ms/copy=%.3f\n",orientation,(t1.QuadPart-t0.QuadPart)*1000.0/freq.QuadPart/200);
  destroy(&a);destroy(&b);
 }
 puts("PASS 16/32-bit odd-width pattern fills with padding, full/partial/clipped copies, both orientations, four raster operations, overlap in nine directions, text metrics and rendering");return 0;
}
