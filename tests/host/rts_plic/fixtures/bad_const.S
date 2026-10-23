/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * A 64-bit store to a PLIC register, the base is a constant of the window
 * (check_plic_stores.py must FAIL).
 */
        .text
        .globl  fx
fx:
        lui     a5, 0xc200
        sd      a0, 4(a5)
        ret
