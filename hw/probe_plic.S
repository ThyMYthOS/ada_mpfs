# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# A5 probe: does the real PLIC accept 64-bit stores into its enable block? (QEMU does not: PLIC_INIT)
# Results at 0x08102000: [0]=32-bit readback [8]=step done [16]=64-bit zero readback [24]=done
#                        [32]=64-bit pattern readback [40]=done [48]=all done
	.section .text
	.globl _start
_start:
	li   s0, 0x08102000
	li   s1, 0x0c002080      # hart 1 M-mode enable block, the address QEMU faulted on
	li   t1, 0x5
	sw   t1, 0(s1)
	lw   t2, 0(s1)
	sd   t2, 0(s0)
	li   t1, 1
	sd   t1, 8(s0)
	sd   zero, 0(s1)         # what memset does
	ld   t2, 0(s1)
	sd   t2, 16(s0)
	li   t1, 1
	sd   t1, 24(s0)
	li   t1, 0x0000000500000003
	sd   t1, 0(s1)
	ld   t2, 0(s1)
	sd   t2, 32(s0)
	li   t1, 1
	sd   t1, 40(s0)
	sd   zero, 0(s1)
	li   t1, 1
	sd   t1, 48(s0)
1:	j    1b
