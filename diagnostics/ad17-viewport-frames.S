/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * AD17.1 Core3D frame-query constructor extension, entered at RVA 5586e6.
 * The patcher changes the original allocation to two interface entries first.
 * Keep query 0 and all original polling/rotation code. If query 1 fails, use
 * Delphi's interface-array resize to release it and restore one-entry pacing.
 * No absolute addresses or new PE relocations are required.
 */
.text
.globl _frames_ahead, _frames_base, _frames_resize, _frames_continue
_frames_ahead:
    pushal
    call 1f
1:  popl %ebx
    .byte 0x81,0xeb
_frames_base:
    .long 0                       /* RVA of the return address above */
    movl -4(%ebp),%esi
    movl 0xec(%esi),%edi
    testl %edi,%edi
    jz 3f                         /* Original query-0 failure path. */
    cmpl $2,-4(%edi)
    jne 3f
    movl 4(%edi),%eax
    testl %eax,%eax
    jz 4f
    movl $0,4(%edi)                /* Reinitialization can retain query 1. */
    pushl %eax
    movl (%eax),%edx
    call *8(%edx)                 /* Release the old owned reference first. */
4:
    leal 4(%edi),%eax
    pushl %eax
    pushl $8                      /* D3DQUERYTYPE_EVENT */
    movl 0xb4(%esi),%eax
    pushl %eax
    movl (%eax),%edx
    call *0x1d8(%edx)             /* IDirect3DDevice9::CreateQuery */
    testl %eax,%eax
    js 2f
    movl 4(%edi),%eax
    testl %eax,%eax
    jz 2f
    pushl $1                      /* D3DISSUE_END: initially complete */
    pushl %eax
    movl (%eax),%edx
    call *0x18(%edx)              /* IDirect3DQuery9::Issue */
    testl %eax,%eax
    jns 3f
2:  pushl $1
    leal 0xec(%esi),%eax
    movl 0x556cd8(%ebx),%edx      /* Original dynamic interface-array type. */
    movl $1,%ecx                  /* One dimension; length is on the stack. */
_frames_resize:
    .byte 0xe8
    .long 0                       /* Original _DynArraySetLength, RVA e5fc. */
    addl $4,%esp
3:  popal
    movl -4(%ebp),%eax            /* Displaced original index initialization. */
    xorl %edx,%edx
    movl %edx,0xf0(%eax)
_frames_continue:
    .byte 0xe9
    .long 0                       /* Resume original constructor at 5586f1. */
