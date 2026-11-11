# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# LIM ECC probe, part 3 (P1.14, #55): which single access raises an ECC event, and does a fetch from a line that
# was written in part work? Every test uses its own 64-byte line at 0x081C4000 + 0x100 * n, which nothing has
# written since power-up (a power cycle makes them fresh again). The ECC counters of the L2 (DatECCFixCount at
# 0x02010148, DatECCFailCount at 0x02010168) are read before and after the one access under test.
# Results at 0x08102000, 0x40 bytes per test: [0]=fix before [8]=fail before [16]=fix after [24]=fail after
# [32]=cause (0 no trap, else mcause + 1) [40]=s6 (1 if the fetched code ran)
#   test 0: sb into a fresh dword            test 1: sw           test 2: sd
#   test 3: sd into a dword of a line whose dword 0 was written (other dword of the same line)
#   test 4: jalr into a line of which only the first two dwords (addi s6,s6,1; ret) were written
#   test 5: jalr into a line of which all 8 dwords were written (the code in the first two)
#   test 6: ld of a never-written dword (control: events must show)
#   [504]=done
	.option norvc
	.equ RES,   0x08102000
	.equ LINES, 0x081C4000
	.equ L2,    0x02010000
	.macro SNAP off
	fence
	ld   t0, 0x148(s3)
	sd   t0, \off(s0)
	ld   t0, 0x168(s3)
	sd   t0, \off+8(s0)
	.endm
	.macro AFTER
	fence
	ld   t0, 0x148(s3)
	sd   t0, 16(s0)
	ld   t0, 0x168(s3)
	sd   t0, 24(s0)
	sd   s2, 32(s0)
	sd   s6, 40(s0)
	.endm
	.macro NEXT
	addi s0, s0, 0x40
	addi s1, s1, 0x100
	li   s2, 0
	li   s6, 0
	.endm
	.section .text
	.globl _start
	.balign 4
_start:
	li   s0, RES
	li   s1, LINES
	li   s3, L2
	la   t0, handler
	csrw mtvec, t0
	csrw mie, zero
	li   t0, 0x1800
	csrs mstatus, t0
	li   s2, 0
	li   s6, 0
	la   s4, resume
	li   s7, 0x00008067001b0b13   # addi s6,s6,1 ; ret

# test 0: sb
	SNAP 0
	li   t1, 0x5a
	sb   t1, 0(s1)
	AFTER
	NEXT
# test 1: sw
	SNAP 0
	li   t1, 0x12345678
	sw   t1, 0(s1)
	AFTER
	NEXT
# test 2: sd
	SNAP 0
	li   t1, 0x1122334455667788
	sd   t1, 0(s1)
	AFTER
	NEXT
# test 3: sd into dword 1 of a line whose dword 0 was written
	li   t1, 0x1122334455667788
	sd   t1, 0(s1)
	SNAP 0
	sd   t1, 8(s1)
	AFTER
	NEXT
# test 4: fetch from a line written in part (two dwords)
	sd   s7, 0(s1)
	sd   zero, 8(s1)
	fence
	.word 0x0000100f   # fence.i (the probe is built without zifencei)
	SNAP 0
	mv   ra, s4
	jalr ra, 0(s1)
resume:
	AFTER
	NEXT
# test 5: fetch from a line written as a whole
	sd   s7, 0(s1)
	sd   zero, 8(s1)
	sd   zero, 16(s1)
	sd   zero, 24(s1)
	sd   zero, 32(s1)
	sd   zero, 40(s1)
	sd   zero, 48(s1)
	sd   zero, 56(s1)
	fence
	.word 0x0000100f   # fence.i (the probe is built without zifencei)
	SNAP 0
	la   s4, resume5
	jalr ra, 0(s1)
resume5:
	AFTER
	NEXT
# test 6: ld of a never-written dword
	SNAP 0
	ld   t1, 0(s1)
	AFTER

	li   s0, RES
	li   t0, 1
	sd   t0, 504(s0)
1:	j    1b

	.balign 4
handler:
	csrr t6, mcause
	addi s2, t6, 1
	csrw mepc, s4
	mret
