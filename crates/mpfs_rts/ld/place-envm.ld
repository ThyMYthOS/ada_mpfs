/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * place-envm.ld -- for the bootloader only (the boot stage that the chip starts from the eNVM at
 * 0x2022_0100, MPFS_ENVM_LENGTH): code and read-only data run from the eNVM, which is never a
 * placement for writable data. .data is loaded into the eNVM and runs in the L2 LIM, where
 * .bss, the stacks and the heap live: start.S copies .data from __data_load to __data_start.
 *
 * .fast_text and .fast_data run in the local memories (ITIM, DTIM) and are loaded from the eNVM.
 */

INCLUDE mpfs-memory.ld

REGION_ALIAS("REGION_TEXT",      envm)
REGION_ALIAS("REGION_DATA",      l2lim)
REGION_ALIAS("REGION_DATA_LOAD", envm)
REGION_ALIAS("REGION_RAM",       l2lim)
REGION_ALIAS("REGION_FAST_TEXT", local_itim)
REGION_ALIAS("REGION_FAST_DATA", dtim)
REGION_ALIAS("REGION_FAST_LOAD", envm)

ASSERT(LENGTH(envm) != 0, "place-envm.ld: MPFS_ENVM_LENGTH is 0, the image has no eNVM to run from")
ASSERT(LENGTH(l2lim) != 0, "place-envm.ld: MPFS_LIM_LENGTH is 0, the data of the bootloader has no RAM")

INCLUDE sections.ld
