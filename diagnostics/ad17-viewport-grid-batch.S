/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * One verified buffer access per zero-angle grid. Original loop handles other cases.
 * EBP is the original factory frame, EBX the maximum row index.
 * Delphi register ABI; preserve GPRs, SIMD registers and x87 stack.
 */
.text
.globl _grid_batch, _grid_batch_pc, _grid_batch_iat, _grid_batch_after, _grid_batch_original
_grid_batch:
    pushal
    subl $192,%esp
    movdqu %xmm0,0(%esp)
    movdqu %xmm1,16(%esp)
    movdqu %xmm2,32(%esp)
    movdqu %xmm3,48(%esp)
    movdqu %xmm4,64(%esp)
    movdqu %xmm5,80(%esp)
    movdqu %xmm6,96(%esp)
    movdqu %xmm7,112(%esp)
    testl %ebx,%ebx
    js .Lfallback
    movl -0x54(%ebp),%eax
    testl %eax,%eax
    js .Lfallback
    incl %eax
    movl %eax,160(%esp)
    movl %ebx,%ecx
    incl %ecx
    movl %ecx,172(%esp)
    movl %ecx,156(%esp)
    mull %ecx
    testl %edx,%edx
    jnz .Lfallback
    testl %eax,%eax
    js .Lfallback
    movl %eax,144(%esp)
    cmpl $0,-0x24(%ebp)
    jne .Lfallback
    cmpl $0,-0xf4(%ebp)
    jne .Lfallback
    cmpl $0,-0x40(%ebp)
    jne .Lfallback
    cmpl $0x80000000,-0x3c(%ebp)
    jne .Lfallback
    cmpw $0x3fff,-0x38(%ebp)
    jne .Lfallback
    movl -0x30(%ebp),%eax
    orl -0x2c(%ebp),%eax
    jne .Lfallback
    testw $0x7fff,-0x28(%ebp)
    jne .Lfallback
    fnstcw 128(%esp)
    movzwl 128(%esp),%eax
    andl $0xc3f,%eax
    cmpl $0x3f,%eax
    jne .Lfallback
    stmxcsr 132(%esp)
    movl 132(%esp),%eax
    andl $0x7f80,%eax
    cmpl $0x1f80,%eax
    jne .Lfallback
    movzwl 128(%esp),%eax
    andl $0x300,%eax
    cmpl $0x100,%eax
    je .Lfallback
    movl %eax,136(%esp)
    movl %fs:0x34,%eax
    movl %eax,164(%esp)
    call _grid_batch_pc
_grid_batch_pc:
    popl %ebx
    leal .Lcore_name-_grid_batch_pc(%ebx),%eax
    pushl %eax
    .byte 0xff,0x93
_grid_batch_iat:
    .long 0x117eadf1
    movl 164(%esp),%edx
    movl %edx,%fs:0x34
    testl %eax,%eax
    jz .Lfallback
    movl %eax,%ebx
    movl -4(%ebp),%eax
    testl %eax,%eax
    jz .Lfallback
    movl (%eax),%edx
    leal 0x503fe1(%ebx),%ecx
    cmpl %ecx,0x24(%edx)
    jne .Lfallback
    movl -0xc(%eax),%edi
    testl %edi,%edi
    jz .Lfallback
    movl %edi,152(%esp)
    movl (%edi),%edx
    leal 0x529e45(%ebx),%ecx
    cmpl %ecx,0x30(%edx)
    jne .Lfallback
    leal 0x529ee3(%ebx),%ecx
    cmpl %ecx,4(%edx)
    jne .Lfallback
    leal 0x529eed(%ebx),%ecx
    cmpl %ecx,8(%edx)
    jne .Lfallback
    cmpl $28,-8(%edi)
    jne .Lfallback
    movl 144(%esp),%ecx
    cmpl %ecx,-4(%edi)
    jb .Lfallback
    movl -0xc(%edi),%eax
    testl %eax,%eax
    jz .Lfallback
    movl %eax,140(%esp)
    movl %ecx,%eax
    movl $28,%edx
    mull %edx
    testl %edx,%edx
    jnz .Lfallback
    addl 140(%esp),%eax
    jc .Lfallback
    /* Known getters only copy an interface and return a stable data field. */
    leal -0xf4(%ebp),%edx
    movl -4(%ebp),%eax
    movl (%eax),%ecx
    call *0x24(%ecx)
    movl -0xf4(%ebp),%eax
    cmpl 152(%esp),%eax
    jne .Lfallback
    movl (%eax),%edx
    call *0x30(%edx)
    cmpl 140(%esp),%eax
    jne .Lfallback
    movl %eax,%edi
    movl -0x14(%ebp),%esi
    subl 0x18(%ebp),%esi
    movl %esi,148(%esp)
    movl 0x28(%ebp),%edx
    subl 0x14(%ebp),%edx
    movq 0x14(%ebp),%xmm2
    pshufd $0xe1,%xmm2,%xmm2
    cvtdq2pd %xmm2,%xmm2
    movl 0x1c(%ebp),%eax
    movl %eax,176(%esp)
    movl $0,180(%esp)
    movl $0,184(%esp)
    movl $0xbf800000,188(%esp)
    movdqu 176(%esp),%xmm3
    movl -0x18(%ebp),%eax
    movl 136(%esp),%ebx
.Lrow:
    movl 160(%esp),%ecx
.Lpoint:
    movd %esi,%xmm0
    movd %edx,%xmm1
    punpckldq %xmm1,%xmm0
    cvtdq2pd %xmm0,%xmm0
    testl %ebx,%ebx
    jnz .Lwide
    cvtpd2ps %xmm0,%xmm0
    cvtps2pd %xmm0,%xmm0
.Lwide:
    addpd %xmm2,%xmm0
    cvtpd2ps %xmm0,%xmm0
    movlps %xmm0,(%edi)
    movdqu %xmm3,8(%edi)
    movl %eax,24(%edi)
    addl 0x2c(%ebp),%esi
    addl $28,%edi
    decl %ecx
    jnz .Lpoint
    decl 156(%esp)
    jz .Lfinish
    addl 0x20(%ebp),%edx
    movl 148(%esp),%esi
    jmp .Lrow
.Lfinish:
    movl $0,-0x98(%ebp)
    movl $0,-0x94(%ebp)
    movl $0xbf800000,-0x90(%ebp)
    subl 0x2c(%ebp),%esi
    movl %edx,-0xec(%ebp)
    movd %esi,%xmm0
    movd %edx,%xmm1
    punpckldq %xmm1,%xmm0
    cvtdq2pd %xmm0,%xmm0
    movsd %xmm0,-0x48(%ebp)
    movhpd %xmm0,-0x50(%ebp)
    movl 144(%esp),%ecx
    movl %ecx,-0x24(%ebp)
    decl %ecx
    movl %ecx,216(%esp)
    movl 172(%esp),%ecx
    movl %ecx,-0x20(%ebp)
    movl 160(%esp),%ecx
    movl %ecx,-0x1c(%ebp)
    movl $0,-0x58(%ebp)
    subl $28,%edi
    movl %edi,220(%esp)
    movl %eax,212(%esp)
    movl $0,208(%esp)
    movdqu 0(%esp),%xmm0
    movdqu 16(%esp),%xmm1
    movdqu 32(%esp),%xmm2
    movdqu 48(%esp),%xmm3
    movdqu 64(%esp),%xmm4
    movdqu 80(%esp),%xmm5
    movdqu 96(%esp),%xmm6
    movdqu 112(%esp),%xmm7
    addl $192,%esp
    popal
    jmp .Lafter
.Lfallback:
    movdqu 0(%esp),%xmm0
    movdqu 16(%esp),%xmm1
    movdqu 32(%esp),%xmm2
    movdqu 48(%esp),%xmm3
    movdqu 64(%esp),%xmm4
    movdqu 80(%esp),%xmm5
    movdqu 96(%esp),%xmm6
    movdqu 112(%esp),%xmm7
    addl $192,%esp
    popal
_grid_baseline:
    testl %ebx,%ebx
    js .Lafter
    incl %ebx
    movl %ebx,-0x58(%ebp)
    movl $0,-0x20(%ebp)
_grid_batch_original:
    .byte 0xe9
    .long 0
.Lafter:
_grid_batch_after:
    .byte 0xe9
    .long 0
.Lcore_name:
    .short 67,111,114,101,51,68,46,100,108,108,0
