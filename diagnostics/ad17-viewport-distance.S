/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * EAX: six-float box; EDX: three-float point; ECX: three-float result.
 * Preserve input aliases and exceptional/unsupported arithmetic via fallback.
 */
.text
.globl _distance_sse, _distance_original
_distance_sse:
    pushal
    subl $64,%esp
    movdqu %xmm0,(%esp)
    movdqu %xmm1,16(%esp)
    movdqu %xmm2,32(%esp)
    leal 12(%ecx),%ebx
    cmpl %ecx,%ebx
    jb 8f
    leal 24(%eax),%esi
    cmpl %eax,%esi
    jb 8f
    cmpl %eax,%ebx
    jbe 1f
    cmpl %ecx,%esi
    ja 8f
1:  leal 12(%edx),%esi
    cmpl %edx,%esi
    jb 8f
    cmpl %edx,%ebx
    jbe 2f
    cmpl %ecx,%esi
    ja 8f
    /* Excluding tiny values keeps DAZ/FTZ from changing subtraction results. */
2:  movl %eax,%esi
    movl $6,%edi
3:  movl (%esi),%ebx
    andl $0x7fffffff,%ebx
    jz 4f
    andl $0x7f800000,%ebx
    cmpl $0x0c800000,%ebx
    jb 8f
    cmpl $0x7f800000,%ebx
    jae 8f
4:  addl $4,%esi
    decl %edi
    jnz 3b
    /* Finish box, then scan the point exactly once. */
    movl %edx,%esi
    movl $3,%edi
    jmp 6f
6:  movl (%esi),%ebx
    andl $0x7fffffff,%ebx
    jz 7f
    andl $0x7f800000,%ebx
    cmpl $0x0c800000,%ebx
    jb 8f
    cmpl $0x7f800000,%ebx
    jae 8f
7:  addl $4,%esi
    decl %edi
    jnz 6b
5:  fnstcw 48(%esp)
    movzwl 48(%esp),%ebx
    andl $0xc3f,%ebx
    cmpl $0x3f,%ebx
    jne 8f
    stmxcsr 52(%esp)
    movl 52(%esp),%ebx
    andl $0x7f80,%ebx
    cmpl $0x1f80,%ebx
    jne 8f
    movzwl 48(%esp),%ebx
    andl $0x300,%ebx
    cmpl $0x100,%ebx
    je 8f
    movq (%eax),%xmm0
    movq (%edx),%xmm1
    movq 12(%eax),%xmm2
    cvtps2pd %xmm0,%xmm0
    cvtps2pd %xmm1,%xmm1
    cvtps2pd %xmm2,%xmm2
    subpd %xmm1,%xmm0
    subpd %xmm2,%xmm1
    testl %ebx,%ebx
    jnz 10f
    cvtpd2ps %xmm0,%xmm0
    cvtps2pd %xmm0,%xmm0
    cvtpd2ps %xmm1,%xmm1
    cvtps2pd %xmm1,%xmm1
10: maxpd %xmm0,%xmm1
    pxor %xmm0,%xmm0
    maxpd %xmm1,%xmm0
    cvtpd2ps %xmm0,%xmm0
    movlps %xmm0,(%ecx)
    movss 8(%eax),%xmm0
    movss 8(%edx),%xmm1
    movss 20(%eax),%xmm2
    cvtss2sd %xmm0,%xmm0
    cvtss2sd %xmm1,%xmm1
    cvtss2sd %xmm2,%xmm2
    subsd %xmm1,%xmm0
    subsd %xmm2,%xmm1
    testl %ebx,%ebx
    jnz 11f
    cvtsd2ss %xmm0,%xmm0
    cvtss2sd %xmm0,%xmm0
    cvtsd2ss %xmm1,%xmm1
    cvtss2sd %xmm1,%xmm1
11: maxsd %xmm0,%xmm1
    pxor %xmm0,%xmm0
    maxsd %xmm1,%xmm0
    cvtsd2ss %xmm0,%xmm0
    movss %xmm0,8(%ecx)
    movdqu (%esp),%xmm0
    movdqu 16(%esp),%xmm1
    movdqu 32(%esp),%xmm2
    addl $64,%esp
    popal
    ret
8:  movdqu (%esp),%xmm0
    movdqu 16(%esp),%xmm1
    movdqu 32(%esp),%xmm2
    addl $64,%esp
    popal
_distance_original:
    .byte 0xe9
    .long 0
