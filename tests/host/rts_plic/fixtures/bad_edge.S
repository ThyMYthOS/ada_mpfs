/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * The last page of the window, 0x0FFF_F000 (check_plic_stores.py must FAIL).
 */
        .text
        .globl  fx
fx:
        lui     a5, 0x0ffff
        sd      a0, 0(a5)
        ret
