# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from ThyMYthOS/ada-machine rts-spikes/hw/probe_irq.S @ 2f0be23; modified for PolarFire SoC.
# A5 probe, hart 1: a timer interrupt (forced via mtimecmp, mtime does not tick on an idle-boot board)
# and a PLIC external interrupt from MMUART0 (source 90, context 1).
# Results at 0x08102000: [0]=stage [8]=timer mcause [16]=external mcause [24]=claimed id [32]=mip [40]=done
	.equ RES,       0x08102000
	.equ MTIMECMP1, 0x02004008
	.equ MTIME,     0x0200bff8
	.equ PLIC,      0x0c000000
	.equ UART0,     0x20000000
	.section .text
	.globl _start
	.balign 4
_start:
	li   s0, RES
	la   t0, handler
	csrw mtvec, t0
	csrw mie, zero
	li   t1, MTIME
	sd   zero, 0(t1)
	li   t1, MTIMECMP1
	li   t2, -1
	sd   t2, 0(t1)
	li   t2, 1
	sd   t2, 0(s0)
	li   t3, 0x80
	csrs mie, t3             # MTIE
	li   t3, 8
	csrs mstatus, t3         # MIE
	li   t1, MTIMECMP1
	sd   zero, 0(t1)         # mtime (0) >= mtimecmp: fires
1:	ld   t2, 8(s0)
	beqz t2, 1b
	li   t2, 2
	sd   t2, 0(s0)
	# The PLIC powers up with random enables, priorities and pending bits (measured): clear the
	# enable block with 64-bit stores, as System.BB.RISCV_PLIC.Initialize does, or a claim returns noise.
	li   t1, 0x0c002080
	sd   zero, 0(t1)
	sd   zero, 8(t1)
	sd   zero, 16(t1)
	sd   zero, 24(t1)
	sd   zero, 32(t1)
	li   t1, PLIC + 4*90
	li   t2, 1
	sw   t2, 0(t1)           # priority of source 90
	li   t1, 0x0c201000
	sw   zero, 0(t1)         # threshold 0
	li   t1, 0x0c002080 + 8
	li   t2, 1 << 26
	sw   t2, 0(t1)           # enable source 90
	li   t3, 0x800
	csrs mie, t3             # MEIE
	li   t1, UART0 + 4
	li   t2, 2
	sw   t2, 0(t1)           # IER.ETBEI: THRE interrupt
2:	ld   t2, 16(s0)
	beqz t2, 2b
	li   t2, 1
	sd   t2, 40(s0)
3:	j    3b

	.balign 4
handler:
	csrr t4, mcause
	li   t5, RES
	ld   t6, 8(t5)
	bnez t6, 4f
	sd   t4, 8(t5)
	li   t6, MTIMECMP1
	li   a0, -1
	sd   a0, 0(t6)
	mret
4:	sd   t4, 16(t5)
	csrr a0, mip
	sd   a0, 32(t5)
	li   t6, 0x0c201004
	lw   a0, 0(t6)           # claim
	sd   a0, 24(t5)
	li   a1, UART0 + 4
	sw   zero, 0(a1)
	sw   a0, 0(t6)           # complete
	mret
