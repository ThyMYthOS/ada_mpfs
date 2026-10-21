/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * A 64-bit store to the enable block of a context that is computed from a hart
 * number (check_plic_stores.py must FAIL).
 */
        .text
        .globl  fx
fx:
        lui     a5, 0xc002
        slli    a4, a1, 7
        add     a5, a5, a4
        sd      zero, 0(a5)
        ret
