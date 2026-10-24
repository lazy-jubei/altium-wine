/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT */
.text
.globl _run_grid
_run_grid:
    pushl %ebp
    pushl %ebx
    pushl %esi
    pushl %edi
    movl 24(%esp),%ebp
    movl 28(%esp),%eax
    movl -0xec(%ebp),%edx
    movl $0x12345678,%ecx
    movl $0x23456789,%ebx
    movl $0x3456789a,%esi
    movl $0x456789ab,%edi
    pcmpeqd %xmm0,%xmm0
    pcmpeqd %xmm1,%xmm1
    pslld $1,%xmm1
    fldpi
    call *20(%esp)
    pushal
    movl 64(%esp),%edi
    movl %esp,%esi
    movl $8,%ecx
    rep movsl
    fxsave (%edi)
    fstp %st(0)
    popal
    popl %edi
    popl %esi
    popl %ebx
    popl %ebp
    ret
