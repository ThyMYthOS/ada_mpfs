/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * Accesses that are allowed (check_plic_stores.py must PASS): 32-bit accesses to
 * the PLIC, 64-bit stores to the stack, to the CLINT and the UART (outside the
 * window), to the page below and the one above the window, and through a value
 * that was loaded from the PLIC.
 */
        .text
        .globl  fx
fx:
        addi    sp, sp, -16
        sd      ra, 8(sp)
        lui     a5, 0xc200
        lw      a4, 4(a5)
        sw      a4, 4(a5)
        sw      zero, 0(a5)
        lui     a3, 0x02004
        sd      a0, 0(a3)
        lui     a3, 0x20000
        sd      a0, 0(a3)
        lui     a3, 0x10000
        sd      a0, 0(a3)
        lui     a3, 0x0bfff
        sd      a0, 0(a3)
        lui     a3, 0xc000
        ld      a3, 0(a3)
        sd      a0, 0(a3)
        ld      ra, 8(sp)
        addi    sp, sp, 16
        ret
