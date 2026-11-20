/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * pmp_csr_page -- code for U mode that touches a PMP CSR.
 *
 * pmp_try (pmp_probe/pmp_try.S) with op 2 makes U mode jump to an address. At pmp_csr_page the code
 * writes pmpcfg0, at pmp_csr_page_read it reads pmpcfg0; both then make an ecall. In U mode the CSR
 * instruction raises an illegal instruction (mcause 2) before it reaches the ecall. The page holds
 * nothing else, so that one NAPOT entry lets U mode execute exactly this.
 */

        .option push
        .option norvc

        .section .text.pmp_csr_page,"ax",@progbits
        .balign 4096
        .globl pmp_csr_page
pmp_csr_page:
        csrw    pmpcfg0, zero
        ecall
        .balign 16
        .globl pmp_csr_page_read
pmp_csr_page_read:
        csrr    t0, pmpcfg0
        ecall
        .balign 4096

        .option pop
