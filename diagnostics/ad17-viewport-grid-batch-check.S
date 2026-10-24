/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT */
.text
.globl _run_grid_batch
_run_grid_batch:
 pushl %ebp
 pushl %ebx
 pushl %esi
 pushl %edi
 movl 24(%esp),%ebp
 movl 28(%esp),%ebx
 movl $0x11223344,%eax
 movl $0x22334455,%edx
 movl $0x33445566,%ecx
 movl $0x44556677,%esi
 movl $0x55667788,%edi
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
 movl 64(%esp),%edi
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
