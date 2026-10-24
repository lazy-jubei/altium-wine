/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Initialize every extra query; any CreateQuery/Issue failure restores one entry.
 * Entered at RVA 5586e6. The patcher selects two or three allocated entries.
 */
.text
.globl _frames_ahead,_frames_base,_frames_resize,_frames_continue
_frames_ahead:
 pushal
 call 1f
1: popl %ebx
 .byte 0x81,0xeb
_frames_base:
 .long 0
 movl -4(%ebp),%esi
 movl 0xec(%esi),%edi
 testl %edi,%edi
 jz 3f
 cmpl $2,-4(%edi)
 jb 3f
 cmpl $4,-4(%edi)
 ja 3f
 movl $1,%ebp
.Lnext:
 movl (%edi,%ebp,4),%eax
 testl %eax,%eax
 jz 4f
 movl $0,(%edi,%ebp,4)
 pushl %eax
 movl (%eax),%edx
 call *8(%edx)
4:
 leal (%edi,%ebp,4),%eax
 pushl %eax
 pushl $8
 movl 0xb4(%esi),%eax
 pushl %eax
 movl (%eax),%edx
 call *0x1d8(%edx)
 testl %eax,%eax
 js 2f
 movl (%edi,%ebp,4),%eax
 testl %eax,%eax
 jz 2f
 pushl $1
 pushl %eax
 movl (%eax),%edx
 call *0x18(%edx)
 testl %eax,%eax
 js 2f
 incl %ebp
 cmpl -4(%edi),%ebp
 jb .Lnext
 jmp 3f
2:
 pushl $1
 leal 0xec(%esi),%eax
 movl 0x556cd8(%ebx),%edx
 movl $1,%ecx
_frames_resize:
 .byte 0xe8
 .long 0
 addl $4,%esp
3:
 popal
 movl -4(%ebp),%eax
 xorl %edx,%edx
 movl %edx,0xf0(%eax)
_frames_continue:
 .byte 0xe9
 .long 0
