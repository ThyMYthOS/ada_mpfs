/*
 * SPDX-FileCopyrightText: 2019 AdaCore
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * Derived from alire-project/bb-runtimes riscv/src/riscv_def.h @ 09e7cd6
 * (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC: the frame of the trap
 * handler is checked against the ABI at assembly time (see below).
 *
 * The ABI decides what a trap frame holds (master plan #41, section 4.1):
 *
 *   E51   -march=rv64imac -mabi=lp64      __riscv_float_abi_soft   x1 - x31 only: 32 * 8 = 256 bytes
 *   U54   -march=rv64imafdc -mabi=lp64d   no such macro            x1 - x31 and f0 - f31: 64 * 8 = 512 bytes
 *
 * The E51 has no FPU, so neither trap_handler.S nor context_switch.S may name an f register
 * there (an fsd would be an illegal instruction); both guard the code with
 * #ifndef __riscv_float_abi_soft. A frame is a multiple of 16 bytes: it is carved out of a stack.
 */

#ifndef _RISCV_DEF_H_
#define _RISCV_DEF_H_

#if __riscv_xlen == 64
# define LREG ld
# define SREG sd
# define REGBYTES 8

#elif __riscv_xlen == 32
# define LREG lw
# define SREG sw
# define REGBYTES 4

# ifdef __riscv_float_abi_double
#  error Double-Precision Floating-Point on 32-bit CPU not supported
# endif

#else
# error XLEN value not supported
#endif

#ifndef __riscv_float_abi_soft
# if __riscv_flen == 64
#  define FLREG fld
#  define FSREG fsd
# elif __riscv_flen == 32
#  define FLREG flw
#  define FSREG fsw
# else
#  error Invalid FLEN value
# endif
#endif

#ifdef __riscv_float_abi_soft
# define FRAME_SIZE (32*REGBYTES)
#else
# define FRAME_SIZE (64*REGBYTES) /* 32 integer + 32 float registers */
#endif

/* Checks: a build that disagrees with itself must not assemble. */
#if !defined(__riscv_float_abi_soft) && !defined(__riscv_flen)
# error A hard-float ABI without an FPU: the trap frame would hold f registers that do not exist
#endif
#if (FRAME_SIZE % 16) != 0
# error The trap frame is not a multiple of 16 bytes (stack alignment of the ABI)
#endif

#define MSTATUS_MIE         0x00000008
#define MSTATUS_MPIE        0x00000080
#define MSTATUS_MPP         0x00001800
#define MSTATUS_FS          0x00006000

#endif /* ! _RISCV_DEF_H_ */
