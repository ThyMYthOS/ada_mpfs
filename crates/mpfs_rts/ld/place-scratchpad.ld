/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * place-scratchpad.ld -- everything in the L2 scratchpad (pinned cache ways at 0x0A00_0000,
 * MPFS_SCRATCHPAD_LENGTH; the ways are taken away from the LIM, so the partition data lowers
 * MPFS_LIM_LENGTH by the same amount). VMA and LMA are both in the scratchpad: the boot stage
 * (HSS or the own MSS init) enables the ways and loads the image there before it starts the
 * hart, so start.S copies nothing. QEMU has no scratchpad: an image placed here is
 * build-only there.
 *
 * .fast_text and .fast_data run in the local memories (ITIM, DTIM) and are loaded from the
 * scratchpad.
 */

INCLUDE mpfs-memory.ld

REGION_ALIAS("REGION_TEXT",      scratchpad)
REGION_ALIAS("REGION_DATA",      scratchpad)
REGION_ALIAS("REGION_DATA_LOAD", scratchpad)
REGION_ALIAS("REGION_RAM",       scratchpad)
REGION_ALIAS("REGION_FAST_TEXT", local_itim)
REGION_ALIAS("REGION_FAST_DATA", dtim)
REGION_ALIAS("REGION_FAST_LOAD", scratchpad)

ASSERT(LENGTH(scratchpad) != 0,
       "place-scratchpad.ld: MPFS_SCRATCHPAD_LENGTH is 0, the image has no scratchpad to run in")

INCLUDE app-sections.ld
