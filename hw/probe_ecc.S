# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# LIM ECC probe (P1.14, #55): what do loads and stores do on 64-byte lines of the LIM that nothing has written
# since power-up (the lines at 0x081C0000, which no image or probe uses)? A trap is recorded and skipped.
# Run it on a board that was power-cycled since the last run of the probe: it writes the lines.
# Results at 0x08102000, four words per test (0x20 bytes); "cause" is 0 for no trap, else mcause + 1:
#   test 0 (fresh line): ld
#     [0]=cause of the ld  [8]=value read (0xdead if the ld trapped)
#   test 1 (fresh): sb, then ld
#     [0]=cause of the sb  [8]=cause of the ld  [16]=value
#   test 2 (fresh): sw, then ld
#   test 3 (fresh): sd, then ld (the control: 64-bit stores are the rule of run_image.py)
#   test 4 (fresh): sd of dword 0, sb into it, ld of it, then ld of dword 1 (never written, same line)
#     [0]=cause of the sb  [8]=cause of the ld  [16]=value of dword 0  [24]=cause of the ld of dword 1
#   test 5 (fresh): sd of dword 0, then sw into dword 1 (never written), then ld of dword 1
#     [0]=cause of the sw  [8]=cause of the ld  [16]=value
#   test 6 (fresh): sd of dword 0 only, then ld of dword 7 of the same line
#   [248]=done
	.option norvc
	.equ RES,   0x08102000
	.equ FRESH, 0x081C0000
	.section .text
	.globl _start
	.balign 4
_start:
	li   s0, RES
	li   s1, FRESH
	la   t0, handler
	csrw mtvec, t0
	csrw mie, zero
	li   t0, 0x1800
	csrs mstatus, t0          # MPP = M, so mret stays in M mode
	li   s3, 0xdead

# test 0: ld from a fresh line
	li   s2, 0
	mv   t0, s3
	ld   t0, 0(s1)
	sd   s2, 0(s0)
	sd   t0, 8(s0)

# test 1: sb, then ld
	addi s1, s1, 64
	addi s0, s0, 32
	li   s2, 0
	li   t1, 0x5a
	sb   t1, 0(s1)
	sd   s2, 0(s0)
	li   s2, 0
	mv   t0, s3
	ld   t0, 0(s1)
	sd   s2, 8(s0)
	sd   t0, 16(s0)

# test 2: sw, then ld
	addi s1, s1, 64
	addi s0, s0, 32
	li   s2, 0
	li   t1, 0x12345678
	sw   t1, 0(s1)
	sd   s2, 0(s0)
	li   s2, 0
	mv   t0, s3
	ld   t0, 0(s1)
	sd   s2, 8(s0)
	sd   t0, 16(s0)

# test 3: sd, then ld
	addi s1, s1, 64
	addi s0, s0, 32
	li   s2, 0
	li   t1, 0x1122334455667788
	sd   t1, 0(s1)
	sd   s2, 0(s0)
	li   s2, 0
	mv   t0, s3
	ld   t0, 0(s1)
	sd   s2, 8(s0)
	sd   t0, 16(s0)

# test 4: sd, sb into it, ld, then ld of the next dword of the line
	addi s1, s1, 64
	addi s0, s0, 32
	li   t1, 0x1122334455667788
	sd   t1, 0(s1)
	li   s2, 0
	li   t2, 0x5a
	sb   t2, 3(s1)
	sd   s2, 0(s0)
	li   s2, 0
	mv   t0, s3
	ld   t0, 0(s1)
	sd   s2, 8(s0)
	sd   t0, 16(s0)
	li   s2, 0
	mv   t0, s3
	ld   t0, 8(s1)
	sd   s2, 24(s0)

# test 5: sd of dword 0, sw into dword 1, ld of dword 1
	addi s1, s1, 64
	addi s0, s0, 32
	li   t1, 0x1122334455667788
	sd   t1, 0(s1)
	li   s2, 0
	li   t2, 0x12345678
	sw   t2, 8(s1)
	sd   s2, 0(s0)
	li   s2, 0
	mv   t0, s3
	ld   t0, 8(s1)
	sd   s2, 8(s0)
	sd   t0, 16(s0)

# test 6: sd of dword 0 only, ld of dword 7
	addi s1, s1, 64
	addi s0, s0, 32
	li   t1, 0x1122334455667788
	sd   t1, 0(s1)
	li   s2, 0
	mv   t0, s3
	ld   t0, 56(s1)
	sd   s2, 0(s0)
	sd   t0, 8(s0)

	li   s0, RES
	li   t0, 1
	sd   t0, 248(s0)
1:	j    1b

	.balign 4
handler:
	csrr t6, mcause
	addi s2, t6, 1
	csrr t6, mepc
	addi t6, t6, 4
	csrw mepc, t6
	mret
