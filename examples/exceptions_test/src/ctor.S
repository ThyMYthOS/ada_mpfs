/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * ctor.S -- one entry in .preinit_array and one in .init_array, as a C constructor
 * (__attribute__((constructor))) would make. Each appends a letter to exceptions_test_ctor_log:
 * start.S calls the preinit entries first, then the init entries (the frame_dummy of crtbegin.o,
 * which registers .eh_frame, among them), all before main; exceptions_test checks the log.
 */

	.section .sdata,"aw",@progbits
	.balign 8
	.globl exceptions_test_ctor_log
exceptions_test_ctor_log:
	.ascii "--------"
	.globl exceptions_test_ctor_len
exceptions_test_ctor_len:
	.dword 0

	.macro ctor_function name, letter
	.text
	.balign 4
	.type \name,@function
\name:
	la      t0, exceptions_test_ctor_len
	ld      t1, (t0)
	la      t2, exceptions_test_ctor_log
	add     t2, t2, t1
	li      t3, \letter
	sb      t3, (t2)
	addi    t1, t1, 1
	sd      t1, (t0)
	ret
	.size \name, . - \name
	.endm

	ctor_function exceptions_test_preinit, 'p'
	ctor_function exceptions_test_init, 'i'

	.section .preinit_array,"aw",@preinit_array
	.balign 8
	.dword exceptions_test_preinit

	.section .init_array,"aw",@init_array
	.balign 8
	.dword exceptions_test_init
