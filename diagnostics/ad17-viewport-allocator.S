/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Keep rounded allocator extents; unusual lengths retain the original routine.
 */
.text
.macro allocator label,minimum,mask
.globl \label, \label\()_call, \label\()_fallback
\label:
.if \minimum == 4
    cmpl $4,%ecx
    ja .Lregular\@
    pushl %ecx
    movl (%eax),%ecx
    movl %ecx,(%edx)
    popl %ecx
    ret
.Lregular\@:
.endif
    pushl %ecx
    cmpl $0x7fffffd0,%ecx
    ja .Loriginal\@
    cmpl $\minimum,%ecx
    jle .Lminimum\@
    addl $3,%ecx
    andl $\mask,%ecx
    addl $\minimum,%ecx
    jmp .Lcall\@
.Lminimum\@:
    movl $\minimum,%ecx
.Lcall\@:
\label\()_call:
    .byte 0xe8
    .long 0
    popl %ecx
    ret
.Loriginal\@:
    popl %ecx
\label\()_fallback:
    .byte 0xe9
    .long 0
.endm
allocator _allocator16,12,-16
allocator _allocator8,4,-8
