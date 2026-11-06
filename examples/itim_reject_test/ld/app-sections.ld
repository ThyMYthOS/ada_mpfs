/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 *
 * app-sections.ld of examples/itim_reject_test: the hook of the application (included by
 * sections.ld of the runtime). .fast_text runs in the ITIM of the E51 and .fast_data in its DTIM
 * (REGION_FAST_TEXT and REGION_FAST_DATA of the placement), both loaded from the LIM
 * (REGION_FAST_LOAD). The runtime declares no section for them; it copies and checks what the
 * symbols name.
 *
 * The contract with start.S: __fast_<kind>_start and _end (run address) and _load (where the
 * image holds the bytes), multiples of 8, for the kinds text and data. The project asks for the
 * check and copy step (start_fast.S) with Mpfs_Link.Fast_Switches: EXTERN cannot be said here.
 */

	.fast_text : ALIGN(8) {
		__fast_text_start = .;
		*(.fast_text .fast_text.*)
		. = ALIGN(8);
		__fast_text_end = .;
	} > REGION_FAST_TEXT AT> REGION_FAST_LOAD
	__fast_text_load = LOADADDR(.fast_text);

	.fast_data : ALIGN(8) {
		__fast_data_start = .;
		*(.fast_data .fast_data.*)
		. = ALIGN(8);
		__fast_data_end = .;
	} > REGION_FAST_DATA AT> REGION_FAST_LOAD
	__fast_data_load = LOADADDR(.fast_data);
