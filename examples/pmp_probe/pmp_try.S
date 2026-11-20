/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * pmp_try -- make one access in M or U mode and say whether it trapped.
 *
 * unsigned long pmp_try (unsigned long op, unsigned long addr, unsigned long user,
 *                        unsigned long value);
 *
 *   op 0  load a word from addr (lw); the word is left in pmp_try_value
 *   op 1  store the low word of value to addr (sw)
 *   op 2  execute at addr, which must hold an ecall
 *
 * With user = 0 the access is made in M mode, otherwise in U mode: mret with
 * mstatus.MPP = U into try_op. After the access try_op makes an ecall; the
 * trap handler of the call (try_trap) takes mcause 8 (ecall from U) or 11
 * (from M) as "the access completed" and returns 0, any other mcause (1
 * instruction, 5 load, 7 store access fault) as it is. The mtval of the
 * trap is left in pmp_try_mtval, the word of a load in pmp_try_value
 * (zero-extended; kept in t2 across the ecall). Either way the handler restores mtvec,
 * sp and ra and returns to the caller of pmp_try in M mode.
 *
 * try_op is alone in the 4 KiB page pmp_user_page, so that one NAPOT entry
 * lets U mode execute it and nothing else. pmp_pages are four pages of 4 KiB
 * (16 KiB, aligned to 16 KiB) for the regions of the test: each starts with
 * an ecall (the target of op 2); the rest is zero. No compressed encodings,
 * so that every instruction is 4 bytes.
 */

        .option push
        .option norvc

        .text
        .globl pmp_try
        .type pmp_try,@function
pmp_try:
        la      t0, pmp_try_ctx
        sd      ra, 0(t0)
        sd      sp, 8(t0)
        csrr    t1, mtvec
        sd      t1, 16(t0)
        la      t1, try_trap
        csrw    mtvec, t1
        la      t1, pmp_try_mtval
        sd      zero, 0(t1)
        li      t2, 0
        la      t1, try_op
        bnez    a2, 1f
        jr      t1                      /* M mode: straight to the access */
1:
        csrw    mepc, t1
        li      t1, 0x1800              /* mstatus.MPP = 0: U mode */
        csrc    mstatus, t1
        mret
        .size pmp_try, . - pmp_try

        .balign 4
try_trap:
        csrr    a0, mcause
        csrr    t1, mtval
        la      t0, pmp_try_mtval
        sd      t1, 0(t0)
        slli    t2, t2, 32
        srli    t2, t2, 32
        la      t0, pmp_try_value
        sd      t2, 0(t0)
        li      t1, 8
        beq     a0, t1, 1f
        li      t1, 11
        bne     a0, t1, 2f
1:
        li      a0, 0
2:
        li      t1, 0x1800              /* mstatus.MPP back to M */
        csrs    mstatus, t1
        la      t0, pmp_try_ctx
        ld      t1, 16(t0)
        csrw    mtvec, t1
        ld      sp, 8(t0)
        ld      ra, 0(t0)
        ret

        .section .text.pmp_user_page,"ax",@progbits
        .balign 4096
        .globl pmp_user_page
pmp_user_page:
try_op:
        beqz    a0, 1f
        addi    t2, a0, -1
        beqz    t2, 2f
        jr      a1
1:
        lw      t2, 0(a1)
        ecall
2:
        sw      a3, 0(a1)
        ecall
        .balign 4096

        .section .pmp_pages,"awx",@progbits
        .balign 16384
        .globl pmp_pages
pmp_pages:
        .rept 4
        ecall
        .fill 1023, 4, 0
        .endr

        .option pop

        .bss
        .balign 8
pmp_try_ctx:
        .skip 24
        .globl pmp_try_mtval
pmp_try_mtval:
        .skip 8
        .globl pmp_try_value
pmp_try_value:
        .skip 8
