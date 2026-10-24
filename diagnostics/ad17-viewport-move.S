/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Delphi register ABI; preserve all GPRs, XMM0 and the x87 stack.
 */
.text
.globl _move_sse
_move_sse:
    pushal
    subl $16,%esp
    movdqu %xmm0,(%esp)
    cmpl %edx,%eax
    je 9f
    testl %ecx,%ecx
    jle 9f
    cmpl %eax,%edx
    jb 1f
    movl %edx,%ebx
    subl %eax,%ebx
    cmpl %ecx,%ebx
    jb 5f
1:  cmpl $16,%ecx
    jb 3f
2:  movdqu (%eax),%xmm0
    movdqu %xmm0,(%edx)
    addl $16,%eax
    addl $16,%edx
    subl $16,%ecx
    cmpl $16,%ecx
    jae 2b
3:  testl %ecx,%ecx
    jz 9f
4:  movb (%eax),%bl
    movb %bl,(%edx)
    incl %eax
    incl %edx
    decl %ecx
    jnz 4b
    jmp 9f
5:  addl %ecx,%eax
    addl %ecx,%edx
    cmpl $16,%ecx
    jb 7f
6:  subl $16,%eax
    subl $16,%edx
    movdqu (%eax),%xmm0
    movdqu %xmm0,(%edx)
    subl $16,%ecx
    cmpl $16,%ecx
    jae 6b
7:  testl %ecx,%ecx
    jz 9f
8:  decl %eax
    decl %edx
    movb (%eax),%bl
    movb %bl,(%edx)
    decl %ecx
    jnz 8b
9:  movdqu (%esp),%xmm0
    addl $16,%esp
    popal
    ret
