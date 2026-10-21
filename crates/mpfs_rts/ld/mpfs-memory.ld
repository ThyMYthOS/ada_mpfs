/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 * Derived from examples/common/ld/mpfs-memory.ld of this repository (same author, Apache-2.0); the
 * runtime crate carries its own copy and its own license.
 *
 * mpfs-memory.ld -- the one MEMORY block shared by every memory profile and
 * every partition.
 *
 * Every ORIGIN below is a LITERAL: it *is* the SoC -- a base address does not
 * change with how an image is configured, only with which chip it targets, and
 * this repository targets exactly one chip.
 *
 * Every LENGTH that is not fixed by the SoC itself is a SYMBOL, supplied by
 * the image via -Wl,--defsym=. Lengths vary because the memory system
 * genuinely is configuration, not because the hardware is unclear about it:
 *   - the L2 is 16 ways of 128 KB, partitioned at run time into cache / LIM /
 *     scratchpad ways -- LIM and scratchpad lengths follow that partition;
 *   - ITIM/DTIM are a cache/SRAM split, per hart, private -- their lengths
 *     follow which hart this image owns, and are 0 (not omitted) for every
 *     hart it does not;
 *   - DDR may not be present at all, and each 32-bit alias's length follows
 *     the DDR size.
 * A LENGTH of 0 is deliberate, not a placeholder: `ld` still lists a
 * zero-length region in the map, so placing anything in a region this image
 * does not own is a link-time "region ... overflowed" error rather than a
 * silently accepted image.
 *
 * `ld` enforces region *overflow*; it does not check region *overlap*,
 * including between the local-memory windows below and including across two
 * separately-linked AMP partitions. Overlap checking belongs in Ada, as
 * pragma Compile_Time_Error -- not here.
 */

MEMORY
{
	/* Non-volatile boot source. (rx): never a placement for writable data. */
	envm        (rx)  : ORIGIN = 0x20220100, LENGTH = MPFS_ENVM_LENGTH

	/* E51-only local data window (L1-D cache/SRAM split). */
	/* MPFS_DTIM_LENGTH is the WHOLE E51 DTIM; a reserved tail would be carved
	 * off its top, so the two regions cannot overlap however MPFS_DTIM_LENGTH
	 * is configured.  */
	dtim        (rwx) : ORIGIN = 0x01000000, LENGTH = MPFS_DTIM_LENGTH

	/* Five local-memory (L1-I cache/SRAM split) windows: one per hart,
	 * declared unconditionally -- names and bases are invariant, and a
	 * declared-but-unused window (LENGTH = 0) costs nothing. */
	e51_itim    (rwx) : ORIGIN = 0x01800000, LENGTH = MPFS_E51_ITIM_LENGTH
	u54_1_itim  (rwx) : ORIGIN = 0x01808000, LENGTH = MPFS_U54_1_ITIM_LENGTH
	u54_2_itim  (rwx) : ORIGIN = 0x01810000, LENGTH = MPFS_U54_2_ITIM_LENGTH
	u54_3_itim  (rwx) : ORIGIN = 0x01818000, LENGTH = MPFS_U54_3_ITIM_LENGTH
	u54_4_itim  (rwx) : ORIGIN = 0x01820000, LENGTH = MPFS_U54_4_ITIM_LENGTH

	/* Generic alias for "whichever hart this image owns' ITIM": both ORIGIN
	 * and LENGTH are symbolic, so one placement script serves any hart
	 * instead of needing one variant per hart. */
	local_itim  (rwx) : ORIGIN = MPFS_LOCAL_ITIM_ORIGIN, LENGTH = MPFS_LOCAL_ITIM_LENGTH

	/* L2, addressed as directly-addressable SRAM (the ways not enabled as
	 * cache). 1920 KB at reset, needing zero L2 configuration. */
	l2lim       (rwx) : ORIGIN = 0x08000000, LENGTH = MPFS_LIM_LENGTH

	/* L2, addressed as pinned cache ways (cacheable, 0 at reset -- creating
	 * one takes ways away from LIM). */
	scratchpad  (rwx) : ORIGIN = 0x0A000000, LENGTH = MPFS_SCRATCHPAD_LENGTH

	/* DDR, 32-bit aliases. LENGTH = 0 is the vendor's own idiom for "alias
	 * absent". */
	ddr_cached  (rwx) : ORIGIN = 0x80000000, LENGTH = MPFS_DDR_CACHED_LENGTH
	ddr_nc      (rwx) : ORIGIN = 0xC0000000, LENGTH = MPFS_DDR_NC_LENGTH
	ddr_wcb     (rwx) : ORIGIN = 0xD0000000, LENGTH = MPFS_DDR_WCB_LENGTH
}
