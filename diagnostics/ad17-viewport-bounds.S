/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Delphi register ABI; preserve all GPRs, XMM0 and the x87 stack.
 */
.text
.globl _bounds_sse, _bounds_fallback_jump
_bounds_sse:
    pushal
    subl $16,%esp
    movdqu %xmm0,(%esp)
    leal 24(%eax),%ecx
    cmpl %edx,%ecx
    jbe 1f
    leal 12(%edx),%ecx
    cmpl %eax,%ecx
    ja 8f
1:  movl %eax,%esi
    movl $6,%ebx
2:  movl (%esi),%ecx
    movl %ecx,%edi
    andl $0x7f800000,%edi
    cmpl $0x7f800000,%edi
    je 8f
    testl %edi,%edi
    jnz 3f
    andl $0x007fffff,%ecx
    jnz 8f
3:  addl $4,%esi
    decl %ebx
    jnz 2b
    movl %edx,%esi
    movl $3,%ebx
4:  movl (%esi),%ecx
    movl %ecx,%edi
    andl $0x7f800000,%edi
    cmpl $0x7f800000,%edi
    je 8f
    testl %edi,%edi
    jnz 5f
    andl $0x007fffff,%ecx
    jnz 8f
5:  addl $4,%esi
    decl %ebx
    jnz 4b
    movss (%eax),%xmm0
    minss (%edx),%xmm0
    movss %xmm0,(%eax)
    movss 4(%eax),%xmm0
    minss 4(%edx),%xmm0
    movss %xmm0,4(%eax)
    movss 8(%eax),%xmm0
    minss 8(%edx),%xmm0
    movss %xmm0,8(%eax)
    movss 12(%eax),%xmm0
    maxss (%edx),%xmm0
    movss %xmm0,12(%eax)
    movss 16(%eax),%xmm0
    maxss 4(%edx),%xmm0
    movss %xmm0,16(%eax)
    movss 20(%eax),%xmm0
    maxss 8(%edx),%xmm0
    movss %xmm0,20(%eax)
    movdqu (%esp),%xmm0
    addl $16,%esp
    popal
    ret
8:  movdqu (%esp),%xmm0
    addl $16,%esp
    popal
_bounds_fallback_jump:
    .byte 0xe9
    .long 0
