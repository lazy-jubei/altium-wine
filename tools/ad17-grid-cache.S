/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT */
.text
.globl _cache_pre, _cache_post
.extern _cache_pre_helper, _cache_post_helper
.extern _cache_pre_continue, _cache_post_continue, _cache_hit_continue
.macro save
    pushfl
    pushal
    movl %esp,%eax
    andl $-16,%esp
    subl $528,%esp
    movl %eax,512(%esp)
    fxsave (%esp)
.endm
.macro restore
    fxrstor (%esp)
    movl 512(%esp),%esp
    popal
    popfl
.endm
_cache_pre:
    save
    pushl %ebx
    pushl %ebp
    call _cache_pre_helper
    addl $8,%esp
    testl %eax,%eax
    jz .Lmiss
    cmpl $1,%eax
    je .Lhit
    /* Positive rows on an expanded miss; update saved EBX before restoring. */
    decl %eax
    movl 512(%esp),%edx
    movl %eax,16(%edx)
.Lmiss:
    restore
    movl -0x54(%ebp),%eax
    incl %eax
    leal 1(%ebx),%edx
    jmp *_cache_pre_continue
.Lhit:
    restore
    jmp *_cache_hit_continue
_cache_post:
    save
    pushl %ebp
    call _cache_post_helper
    addl $4,%esp
    restore
    movl -0x14(%ebp),%eax
    cmpl 0x30(%ebp),%eax
    jmp *_cache_post_continue
