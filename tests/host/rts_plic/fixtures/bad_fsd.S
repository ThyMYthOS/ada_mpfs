/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * A 64-bit floating-point store to a PLIC register (check_plic_stores.py must
 * FAIL; assembled with the D extension).
 */
        .text
        .globl  fx
fx:
        lui     a5, 0xc201
        fsd     fa0, 0(a5)
        ret
