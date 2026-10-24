/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT */
.text
.globl _run_allocator
_run_allocator:
 pushl %ebp
 pushl %ebx
 pushl %esi
 pushl %edi
 movl 24(%esp),%eax
 movl 28(%esp),%edx
 movl 32(%esp),%ecx
 movl $0x44556677,%ebx
 movl $0x55667788,%esi
 movl $0x66778899,%edi
 movl $0x778899aa,%ebp
 pcmpeqd %xmm0,%xmm0
 pcmpeqd %xmm1,%xmm1
 pslld $1,%xmm1
 pcmpeqd %xmm2,%xmm2
 pslld $2,%xmm2
 pcmpeqd %xmm3,%xmm3
 pslld $3,%xmm3
 pcmpeqd %xmm4,%xmm4
 pslld $4,%xmm4
 pcmpeqd %xmm5,%xmm5
 pslld $5,%xmm5
 pcmpeqd %xmm6,%xmm6
 pslld $6,%xmm6
 pcmpeqd %xmm7,%xmm7
 pslld $7,%xmm7
 fldpi
 fldln2
 fldz
 call *20(%esp)
 pushal
 movl 68(%esp),%edi
 movl %esp,%esi
 movl $8,%ecx
 rep movsl
 fxsave (%edi)
 fstp %st(0)
 fstp %st(0)
 fstp %st(0)
 popal
 popl %edi
 popl %esi
 popl %ebx
 popl %ebp
 ret
