/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * place-lim.ld -- everything in the L2 LIM window (MPFS_LIM_LENGTH, 1920 KB at reset): usable
 * with no L2 way configuration at all, so no system-controller memory setup, no DDR, no L2
 * programming. The partition that boots from it is loaded there by a debugger or by the boot
 * stage.
 *
 * LMA = VMA throughout: l2lim is writable SRAM, so .data needs no copy at startup.
 * .fast_text and .fast_data run in the local memories (ITIM, DTIM) and are loaded from the LIM.
 */

INCLUDE mpfs-memory.ld

REGION_ALIAS("REGION_TEXT",      l2lim)
REGION_ALIAS("REGION_DATA",      l2lim)
REGION_ALIAS("REGION_DATA_LOAD", l2lim)
REGION_ALIAS("REGION_RAM",       l2lim)
REGION_ALIAS("REGION_FAST_TEXT", local_itim)
REGION_ALIAS("REGION_FAST_DATA", dtim)
REGION_ALIAS("REGION_FAST_LOAD", l2lim)

ASSERT(LENGTH(l2lim) != 0, "place-lim.ld: MPFS_LIM_LENGTH is 0, the image has no LIM to run in")

INCLUDE app-sections.ld
