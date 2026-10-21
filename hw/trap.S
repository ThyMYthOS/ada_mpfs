# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Records the FIRST trap (mcause, mepc, mtval) at REC and spins. Linked at 0x08100000.
# REC: [0]=seen, [8]=mcause, [16]=mepc, [24]=mtval
	.equ REC, 0x08101000
	.section .text
	.globl _trap
	.balign 4
_trap:
	csrr t0, mcause
	csrr t1, mepc
	csrr t2, mtval
	li   t3, REC
	ld   t4, 0(t3)
	bnez t4, 1f
	sd   t0, 8(t3)
	sd   t1, 16(t3)
	sd   t2, 24(t3)
	li   t4, 1
	sd   t4, 0(t3)
1:	j    1b
