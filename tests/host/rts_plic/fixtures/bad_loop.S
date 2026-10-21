/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * The base of the store is set at the end of the loop body, so it is an
 * address of the window from the second iteration on (check_plic_stores.py must
 * FAIL: it follows the back edge).
 */
        .text
        .globl  fx
fx:
        li      a4, 0
        lui     a5, 0xc002
        li      a3, 6
1:      sd      zero, 0(a4)
        mv      a4, a5
        addi    a5, a5, 8
        addi    a3, a3, -1
        bnez    a3, 1b
        ret
