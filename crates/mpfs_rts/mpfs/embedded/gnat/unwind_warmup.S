/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * unwind_warmup.S -- the first unwind of the embedded profile is done before main, not in the
 * first trap (issue #91).
 *
 * libgcc's unwinder (unwind-dw2-fde.o, the registration-based one that link-zcx.spec selects)
 * sorts the frame descriptions of an object when the first _Unwind_Find_FDE searches it: it calls
 * malloc for the sort array and runs the sorting frames, about 1.1 KiB of stack. If that first
 * search is the one of an exception raised in a trap handler, it runs on the interrupt stack with
 * the heap lock taken (interrupts off) and its time is not bounded by the program: how long the
 * sort takes depends on the number of frame descriptions, and malloc can take as long as the
 * allocator needs.
 *
 * This constructor makes the search happen at start-up instead, where nothing else runs: it is an
 * entry of .init_array behind frame_dummy of crtbegin.o (which registers .eh_frame with
 * __register_frame_info; crtbegin.o is the first object of the link, so its entry is the first),
 * run by start.S before main, interrupts off, on the stack of the environment task. It calls
 * _Unwind_Find_FDE, the public function of libgcc that every unwinder search starts with, for a
 * pc inside this function (which has a frame description of its own, from the .cfi directives):
 * the lookup finds the registered object, sorts it, and finds the description. The result is not
 * used. Later searches (an exception in a trap, in a task) only look into the sorted table.
 *
 * Linked by -u __mpfs_unwind_warmup of link-zcx.spec, so every image of the embedded profile
 * has it and no other profile does.
 */
/* @req RTS-024 */

	.section .text.__mpfs_unwind_warmup,"ax",@progbits
	.globl __mpfs_unwind_warmup
	.type __mpfs_unwind_warmup,@function
	.balign 4
__mpfs_unwind_warmup:
	.cfi_startproc
	addi    sp, sp, -32
	.cfi_def_cfa_offset 32
	sd      ra, 24(sp)
	.cfi_offset 1, -8
	la      a0, __mpfs_unwind_warmup
	addi    a0, a0, 4               /* a pc inside this function */
	mv      a1, sp                  /* struct dwarf_eh_bases: three pointers, 24 bytes */
	call    _Unwind_Find_FDE
	ld      ra, 24(sp)
	addi    sp, sp, 32
	ret
	.cfi_endproc
	.size __mpfs_unwind_warmup, . - __mpfs_unwind_warmup

	.section .init_array,"aw",@init_array
	.balign 8
	.dword  __mpfs_unwind_warmup
