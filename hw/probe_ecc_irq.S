# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# LIM ECC probe, part 2, after probe_ecc.S: (a) what does an instruction fetch from a LIM line
# that nothing has written do, (b) are the ECC events of the L2 delivered as an interrupt once the PLIC
# sources 1..4 are enabled? Fresh lines: 0x081C2000 (fetch), 0x081C2800 (load). Hart 1, M mode.
# Results at 0x08102000, "cause" is 0 for no trap, else mcause + 1:
#   [0]=cause of the fetch (3 = illegal instruction: the line was fetched and the garbage decoded)
#   [8]=mepc, after the handler set it, so the resume address  [16]=mtval of the fault
#   [32]=number of external interrupts taken  [40]=first claim id  [48]=second claim id
#   [56]=DatECCFixCount before the load  [64]=after  [72]=DatECCFailCount after
#   [248]=done
	.option norvc
	.equ RES,    0x08102000
	.equ FETCH,  0x081C2000
	.equ LOAD,   0x081C2800
	.equ PLIC,   0x0C000000
	.equ L2,     0x02010000
	.section .text
	.globl _start
	.balign 4
_start:
	li   s0, RES
	la   t0, handler
	csrw mtvec, t0
	csrw mie, zero
	li   t0, 0x1800
	csrs mstatus, t0
	li   s5, 0               # external interrupts taken
	la   s4, after_fetch     # where the handler resumes after the fetch fault

# (a) fetch from a fresh line
	li   t0, FETCH
	jalr ra, 0(t0)
after_fetch:
	sd   s2, 0(s0)
	csrr t0, mepc
	sd   t0, 8(s0)
	csrr t0, mtval
	sd   t0, 16(s0)

# (b) enable the sources 1..4 for the M context of hart 1 and read a fresh line
	li   t0, PLIC
	li   t1, 1
	sw   t1, 4(t0)           # priority of source 1
	sw   t1, 8(t0)
	sw   t1, 12(t0)
	sw   t1, 16(t0)
	li   t1, 0x1e
	li   t2, 0x0C002080      # enable, context 1 (hart 1 M)
	sw   t1, 0(t2)
	li   t2, 0x0C201000      # threshold of context 1
	sw   zero, 0(t2)
	li   t0, L2
	ld   t1, 0x148(t0)
	sd   t1, 56(s0)
	li   t0, 0x800
	csrs mie, t0             # MEIE
	li   t0, 8
	csrs mstatus, t0         # MIE
	li   t0, LOAD
	ld   t1, 0(t0)
	li   t2, 200000
1:	addi t2, t2, -1
	bnez t2, 1b
	li   t0, L2
	ld   t1, 0x148(t0)
	sd   t1, 64(s0)
	ld   t1, 0x168(t0)
	sd   t1, 72(s0)
	sd   s5, 32(s0)

	li   t0, 1
	sd   t0, 248(s0)
2:	j    2b

	.balign 4
handler:
	csrr t6, mcause
	bltz t6, irq
	addi s2, t6, 1           # synchronous: the fetch fault
	csrw mepc, s4
	mret
irq:
	li   t5, 0x0C201004      # claim/complete, context 1
	lw   t4, 0(t5)
	addi s5, s5, 1
	li   t3, 1
	bne  s5, t3, 3f
	sd   t4, 40(s0)
	j    4f
3:	li   t3, 2
	bne  s5, t3, 4f
	sd   t4, 48(s0)
4:	sw   t4, 0(t5)           # complete
	mret
