/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT */
.text
.globl _bucket_scan,_bucket_found,_bucket_miss,_bucket_original
_bucket_scan:
 subl $48,%esp
 movdqu %xmm0,0(%esp)
 movdqu %xmm1,16(%esp)
 movdqu %xmm2,32(%esp)
 movl (%esi),%edx
 testl %edx,%edx
 jle .Loriginal
 cmpl $0xfffffff,%edx
 ja .Loriginal
 movl 4(%esi),%ecx
 leal -8(%ecx,%edx,8),%eax
 cmpl %ecx,%eax
 jb .Loriginal
 movd -4(%ebp),%xmm2
 pshufd $0,%xmm2,%xmm2
 xorl %eax,%eax
.Lloop:
 cmpl $4,%edx
 jb .Lscalar
 leal (%ecx,%eax,8),%ebx
 andl $4095,%ebx
 cmpl $4064,%ebx
 ja .Lscalar
 movdqu (%ecx,%eax,8),%xmm0
 movdqu 16(%ecx,%eax,8),%xmm1
 shufps $0x88,%xmm1,%xmm0
 pcmpeqd %xmm2,%xmm0
 movmskps %xmm0,%ebx
 testl %ebx,%ebx
 jnz .Lvector_found
 addl $4,%eax
 subl $4,%edx
 jnz .Lloop
 jmp .Lmiss
.Lscalar:
 movl (%ecx,%eax,8),%ebx
 cmpl -4(%ebp),%ebx
 je .Lfound
 xorl %ebx,%ebx
 incl %eax
 decl %edx
 jnz .Lloop
 jmp .Lmiss
.Lvector_found:
 bsfl %ebx,%ebx
 addl %ebx,%eax
.Lfound:
 xorl %ebx,%ebx
 movdqu 0(%esp),%xmm0
 movdqu 16(%esp),%xmm1
 movdqu 32(%esp),%xmm2
 addl $48,%esp
_bucket_found:
 .byte 0xe9
 .long 0
.Lmiss:
 xorl %ebx,%ebx
 movdqu 0(%esp),%xmm0
 movdqu 16(%esp),%xmm1
 movdqu 32(%esp),%xmm2
 addl $48,%esp
_bucket_miss:
 .byte 0xe9
 .long 0
.Loriginal:
 movdqu 0(%esp),%xmm0
 movdqu 16(%esp),%xmm1
 movdqu 32(%esp),%xmm2
 addl $48,%esp
 movl (%esi),%edx
 decl %edx
 testl %edx,%edx
_bucket_original:
 .byte 0xe9
 .long 0
