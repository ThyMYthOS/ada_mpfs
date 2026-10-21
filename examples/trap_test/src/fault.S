/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * The illegal instruction of trap_test, with a label so that the test knows the mepc to expect.
 * 0xC0001073 is `unimp` without the C extension: a write of a read-only CSR (cycle), which
 * raises an illegal-instruction exception in every privilege level.
 */

	.section .text.trap_test_fault,"ax",@progbits
	.globl trap_test_fault
	.type trap_test_fault,@function
	.balign 4
trap_test_fault:
.option push
.option norvc
	.globl trap_test_fault_insn
trap_test_fault_insn:
	.word 0xC0001073
.option pop
	.size trap_test_fault, . - trap_test_fault
