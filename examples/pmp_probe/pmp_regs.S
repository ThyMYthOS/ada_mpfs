/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * pmp_regs -- read and write the PMP CSRs by number (for Pmp_Csr, pmp_csr.ads).
 *
 * The CSR number is part of the instruction, so each accessor jumps into a
 * table of sixteen slots of two instructions (8 bytes, no compressed
 * encodings), one per pmpaddr.
 *
 * unsigned long pmp_read_addr  (unsigned long index);              index 0 .. 15
 * void          pmp_write_addr (unsigned long index, unsigned long value);
 * unsigned long pmp_read_cfg   (unsigned long reg);                reg 0 or 2
 * void          pmp_write_cfg  (unsigned long reg, unsigned long value);
 */

        .text
        .option push
        .option norvc

        .globl pmp_read_addr
        .type pmp_read_addr,@function
pmp_read_addr:
        andi    a0, a0, 15
        slli    a0, a0, 3
        la      t0, 1f
        add     t0, t0, a0
        jr      t0
1:
        .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
        csrr    a0, pmpaddr\n
        ret
        .endr
        .size pmp_read_addr, . - pmp_read_addr

        .globl pmp_write_addr
        .type pmp_write_addr,@function
pmp_write_addr:
        andi    a0, a0, 15
        slli    a0, a0, 3
        la      t0, 1f
        add     t0, t0, a0
        jr      t0
1:
        .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
        csrw    pmpaddr\n, a1
        ret
        .endr
        .size pmp_write_addr, . - pmp_write_addr

        .globl pmp_read_cfg
        .type pmp_read_cfg,@function
pmp_read_cfg:
        bnez    a0, 1f
        csrr    a0, pmpcfg0
        ret
1:
        csrr    a0, pmpcfg2
        ret
        .size pmp_read_cfg, . - pmp_read_cfg

        .globl pmp_write_cfg
        .type pmp_write_cfg,@function
pmp_write_cfg:
        bnez    a0, 1f
        csrw    pmpcfg0, a1
        ret
1:
        csrw    pmpcfg2, a1
        ret
        .size pmp_write_cfg, . - pmp_write_cfg

        .option pop
