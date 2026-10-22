# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from ThyMYthOS/ada-machine rts-spikes/hw/probe_time.S @ 2f0be23; modified for PolarFire SoC.
# A5 probe: does CLINT mtime count on a running hart? Records mtime before and after a loop of
# 3,000,000 iterations (2 cycles each, measured). The U54 has no `time` CSR (csrr time traps).
# Results at 0x08102000: [0]=mtime before [16]=mcycles in loop [24]=mtime after [40]=done
	.section .text
	.globl _start
_start:
	li   t3, 0x08102000
	li   t4, 0x0200bff8
	ld   t0, 0(t4)
	sd   t0, 0(t3)
	csrr t5, mcycle
	li   t2, 3000000
1:	addi t2, t2, -1
	bnez t2, 1b
	csrr t6, mcycle
	sub  t6, t6, t5
	sd   t6, 16(t3)
	ld   t0, 0(t4)
	sd   t0, 24(t3)
	li   t0, 1
	sd   t0, 40(t3)
2:	j    2b
