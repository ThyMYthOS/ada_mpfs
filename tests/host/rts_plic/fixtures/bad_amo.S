/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * A 64-bit atomic memory operation on a PLIC register (check_plic_stores.py
 * must FAIL).
 */
        .text
        .globl  fx
fx:
        lui     a5, 0xc000
        amoswap.d zero, a0, (a5)
        ret
