/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * pmp_mask -- which of pmpaddr0 .. pmpaddr15 are implemented?
 *
 * The CSR number is part of the instruction, so the sixteen probes are
 * unrolled. pmpaddr is WARL: an entry that does not exist reads back zero
 * whatever is written. Each entry is written with a pattern of ones that every
 * implemented pmpaddr bit can hold (bits 53:0 on RV64), read back, and
 * cleared again. Bit n of the result is set if pmpaddrN holds the pattern.
 * Entries are expected to be unlocked (no pmpcfg L bit), which holds after
 * reset.
 *
 * unsigned long pmp_mask (void);
 */

        .text
        .globl pmp_mask
        .type pmp_mask,@function

pmp_mask:
        li      a0, 0
        li      t0, -1
        srli    t0, t0, 10              /* 54 ones */
        .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
        csrw    pmpaddr\n, t0
        csrr    t1, pmpaddr\n
        csrw    pmpaddr\n, zero
        snez    t1, t1
        slli    t1, t1, \n
        or      a0, a0, t1
        .endr
        ret
        .size pmp_mask, . - pmp_mask
