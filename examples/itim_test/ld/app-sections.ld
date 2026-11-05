/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * app-sections.ld of examples/itim_test: the hook of the application (included by sections.ld of
 * the runtime). The code in .fast_text and the data in .fast_data of the application run from
 * and are loaded into the L2 LIM, at different addresses, because QEMU has no ITIM: the copy
 * step of start.S and the check of the range are the same as for the real ITIM and DTIM.
 * examples/itim_reject_test places the same sections in the real ITIM and DTIM.
 *
 * The contract with start.S: __fast_<kind>_start and _end (run address) and _load (where the
 * image holds the bytes), multiples of 8, for the kinds text and data. The project asks for the
 * check and copy step (start_fast.S) with Mpfs_Link.Fast_Switches: EXTERN cannot be said here.
 */

	/* The bytes follow the loaded sections (the location counter is the end of .sdata2); the
	 * code and the data run 1 MB above the start of the LIM, so that LMA and VMA differ and
	 * start.S has to copy. .bss and the rest of the RAM region follow the run addresses. */
	__fast_text_load = ALIGN(8);
	.fast_text ORIGIN(l2lim) + 0x100000 : AT(__fast_text_load) {
		__fast_text_start = .;
		*(.fast_text .fast_text.*)
		. = ALIGN(8);
		__fast_text_end = .;
	} > l2lim

	__fast_data_load = __fast_text_load + SIZEOF(.fast_text);
	.fast_data : AT(__fast_data_load) {
		__fast_data_start = .;
		*(.fast_data .fast_data.*)
		. = ALIGN(8);
		__fast_data_end = .;
	} > l2lim
