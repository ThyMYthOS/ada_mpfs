/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * Entry point of a bare image. QEMU's reset ROM (and, on hardware, a
 * multi-hart release) sends every hart that is started to this one address,
 * so the first thing a hart does is to test its own bit in the image's hart
 * mask: __mpfs_harts_mask is an absolute symbol set at link time with
 * --defsym (1 for the E51, 2 for U54 hart 1, ...). A hart whose bit is clear
 * parks.
 */

#define MSTATUS_MIE 0x00000008
#define MSTATUS_FS  0x00006000

	.section .start,"ax",@progbits
	.globl _start
	.type _start,@function

_start:
.option push
.option norelax
	la      gp, __global_pointer$
.option pop

	/* Interrupts off before anything can park: wfi wakes on any pending
	 * interrupt enabled in mie even with mstatus.MIE clear, and a hart
	 * handed over from an earlier stage may carry a stale mie. */
	li      t0, MSTATUS_MIE
	csrc    mstatus, t0
	csrw    mie, zero

	/* Any trap lands in a loop that does nothing. */
	la      t0, trap_loop
	csrw    mtvec, t0

	/* Hart gate: park unless bit mhartid of the mask is set. */
	csrr    t1, mhartid
	li      t0, 1
	sll     t0, t0, t1
	lui     t2, %hi(__mpfs_harts_mask)
	addi    t2, t2, %lo(__mpfs_harts_mask)
	and     t0, t0, t2
	beqz    t0, park

	la      sp, __stack_end

	/* Clear .bss */
	la      a0, __bss_start
	la      a1, __bss_end
	bgeu    a0, a1, 2f
1:
	sd      zero, (a0)
	addi    a0, a0, 8
	bltu    a0, a1, 1b
2:

#ifndef __riscv_float_abi_soft
	/* Enable the FPU (U54 images; the E51 has none). */
	li      t0, MSTATUS_FS
	csrs    mstatus, t0
#endif

	call    main

park:
	wfi
	j       park

	.balign 4
trap_loop:
	j       trap_loop
