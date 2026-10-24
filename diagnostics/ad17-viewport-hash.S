/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Delphi register ABI: EAX state, EDX bytes, ECX signed byte count.
 * Keep the Jenkins update bit-exact, including wrapped uint32 arithmetic.
 */
.text
.globl _hash_fast, _hash_original
_hash_fast:
    pushal
    testl %ecx,%ecx
    jz 9f
    js 8f
    movl %eax,%edi
    leal 4(%eax),%ebx
    cmpl %eax,%ebx
    jb 8f
    movl %edx,%esi
    addl %ecx,%esi
    jc 8f
    cmpl %eax,%esi
    jbe 1f
    cmpl %edx,%ebx
    ja 8f
1:  movl (%edi),%eax
2:  movzbl (%edx),%ebx
    addl %ebx,%eax
    movl %eax,%ebx
    shll $10,%ebx
    addl %ebx,%eax
    movl %eax,%ebx
    shrl $6,%ebx
    xorl %ebx,%eax
    incl %edx
    decl %ecx
    jnz 2b
    movl %eax,(%edi)
9:  popal
    ret
8:  popal
_hash_original:
    .byte 0xe9
    .long 0
