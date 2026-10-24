/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * AD17.1 grid vertex transform. EBP is the caller's frame; EAX is vertex.
 * Zero rotation only; other values and rounding modes use the original code.
 */
.text
.globl _grid_sse, _grid_continue, _grid_original
_grid_sse:
    pushal
    subl $48,%esp
    movdqu %xmm0,(%esp)
    movdqu %xmm1,16(%esp)
    cmpl $0,-0x40(%ebp)
    jne 8f
    cmpl $0x80000000,-0x3c(%ebp)
    jne 8f
    cmpw $0x3fff,-0x38(%ebp)
    jne 8f
    movl -0x30(%ebp),%ecx
    orl -0x2c(%ebp),%ecx
    jne 8f
    testw $0x7fff,-0x28(%ebp)
    jne 8f
    fnstcw 32(%esp)
    movzwl 32(%esp),%ecx
    andl $0xc3f,%ecx
    cmpl $0x3f,%ecx
    jne 8f
    stmxcsr 36(%esp)
    movl 36(%esp),%ecx
    andl $0x7f80,%ecx
    cmpl $0x1f80,%ecx
    jne 8f
    movzwl 32(%esp),%ecx
    andl $0x300,%ecx
    cmpl $0x100,%ecx
    je 8f
    movd -0xec(%ebp),%xmm0
    movl -0x20(%ebp),%edx
    imull 0x20(%ebp),%edx
    addl 0x28(%ebp),%edx
    subl 0x14(%ebp),%edx
    movl %edx,-0xec(%ebp)
    movl %edx,68(%esp)
    movd %edx,%xmm1
    punpckldq %xmm1,%xmm0
    cvtdq2pd %xmm0,%xmm0
    movsd %xmm0,-0x48(%ebp)
    movhpd %xmm0,-0x50(%ebp)
    testl %ecx,%ecx
    jnz 1f
    cvtpd2ps %xmm0,%xmm0
    cvtps2pd %xmm0,%xmm0
1:  movq 0x14(%ebp),%xmm1
    pshufd $0xe1,%xmm1,%xmm1
    cvtdq2pd %xmm1,%xmm1
    addpd %xmm1,%xmm0
    cvtpd2ps %xmm0,%xmm0
    movlps %xmm0,(%eax)
    movdqu (%esp),%xmm0
    movdqu 16(%esp),%xmm1
    addl $48,%esp
    popal
_grid_continue:
    .byte 0xe9
    .long 0
8:  movdqu (%esp),%xmm0
    movdqu 16(%esp),%xmm1
    addl $48,%esp
    popal
_grid_original:
    .byte 0xe9
    .long 0
