/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: Apache-2.0
 * Derived from ThyMYthOS/ada-machine rts-spikes/rts_support_mpfs/ld/place-lim.ld @ 2f0be23; modified for PolarFire SoC.
 *
 * place-lim.ld -- everything in the L2 LIM window, which is 1920 KB and
 * directly usable at reset with *no* L2 way configuration at all. That makes
 * it the right first-boot placement: no system-controller memory setup, no
 * DDR, no L2 programming. The SECTIONS layout follows the common RAM layout
 * of the GNAT bare-board runtimes, with the single flat "ram" region replaced
 * by "l2lim".
 *
 * LMA = VMA throughout: l2lim is writable SRAM, so .data needs no ROM-to-RAM
 * copy at startup. The stack size can be set with --defsym=__stack_size=.
 */

INCLUDE mpfs-memory.ld

SEARCH_DIR(.)
__DYNAMIC = 0;

_DEFAULT_STACK_SIZE = (2 * 1024 * 1024);

OUTPUT_ARCH("riscv")

ENTRY(_start);

SECTIONS
{
	.text : {
		__text = .;
		KEEP (*(SORT_NONE(.start)))
		*(.text .text.* .gnu.linkonce.t*)
		*(.gnu.warning)
	} > l2lim

	.init : { KEEP(*(.init)) } > l2lim

	.ctors : { KEEP(SORT_BY_NAME(*)(.ctors)) } > l2lim
	.dtors : { KEEP(SORT_BY_NAME(*)(.dtors)) } > l2lim

	.rodata : {
		*(.rdata)
		*(.rodata .rodata.* .gnu.linkonce.r*)
		. = ALIGN(0x4);
		__rom_end = .;
	} > l2lim

	.eh_frame_hdr : {
		 __eh_frame_hdr = .;
		*(.eh_frame_hdr)
	} > l2lim

	.eh_frame : {
		KEEP (*(.eh_frame))
	} > l2lim

	.gcc_except_table : {
		*(.gcc_except_table .gcc_except_table.*)
	} > l2lim

	.data : {
		__data = .;
		__data_start = .;
		*(.data .data.* .gnu.linkonce.d*)
	} > l2lim

	.srodata ALIGN(4) : ALIGN(4) /* Align both virtual and load addresses */
	{
		PROVIDE( __global_pointer$ = . + 0x800 );
		*(.srodata.cst16)
		*(.srodata.cst8)
		*(.srodata.cst4)
		*(.srodata.cst2)
		*(.srodata .srodata.*)
	} > l2lim

	.sdata ALIGN(4) : ALIGN(4) /* Align both virtual and load addresses */
	{
		*(.sdata .sdata.*)
		*(.gnu.linkonce.s.*)
	} > l2lim

	.sdata2 ALIGN(4) : ALIGN(4) /* Align both virtual and load addresses */
	{
		*(.sdata2 .sdata2.*)
		*(.gnu.linkonce.s2.*)
	} > l2lim

	__data_end = .;

	/* Size of all data sections (.data, .srodata, .sdata) in number of 32bit words. */
	__data_words = (__data_end - __data_start) >> 2;

	/* Base address of all data sections in ROM. The startup code copies these
	 * sections from __data_load (in ROM) to __data_start (in RAM).
	 */
	__data_load = LOADADDR(.data);

	.bss (NOLOAD): {
		. = ALIGN(0x8);
		__bss_start = .;

		*(.sbss*)
		*(.gnu.linkonce.sb.*)
		*(.bss .bss.*)
		*(.gnu.linkonce.b.*)
		*(COMMON)

		/* Interrupt stacks. Statically allocated in System.BB.Interrupts */
		__interrupt_stack_start = .;
		*(.noinit.interrupt_stacks)
		. = ALIGN(0x10); /* Align stack to 128 bits as required in the ABI */
		__interrupt_stack_end = .;

		__stack_start = .;
		. += DEFINED (__stack_size) ? __stack_size : _DEFAULT_STACK_SIZE;
		. = ALIGN(0x10); /* Align stack to 128 bits as required in the ABI */
		__stack_end = .;

		_end = .;
		__heap_start = .;
		__heap_end = ORIGIN(l2lim) + LENGTH(l2lim);
		__bss_end = .;
	} > l2lim

	 __bss_words = (__bss_end - __bss_start) >> 2;

	/* DWARF debug sections.
	 * Symbols in the DWARF debugging sections are relative to the beginning
	 * of the section so we begin them at 0.
	 */

	/* DWARF 1. */
	.debug             0 : { *(.debug) }
	.line              0 : { *(.line) }

	/* GNU DWARF 1 extensions. */
	.debug_srcinfo     0 : { *(.debug_srcinfo) }
	.debug_sfnames     0 : { *(.debug_sfnames) }

	/* DWARF 1.1 and DWARF 2. */
	.debug_aranges     0 : { *(.debug_aranges) }
	.debug_pubnames    0 : { *(.debug_pubnames) }

	/* DWARF 2. */
	.debug_info        0 : { *(.debug_info .gnu.linkonce.wi.*) }
	.debug_abbrev      0 : { *(.debug_abbrev) }
	.debug_line        0 : { *(.debug_line .debug_line.* .debug_line_end) }
	.debug_frame       0 : { *(.debug_frame) }
	.debug_str         0 : { *(.debug_str) }
	.debug_loc         0 : { *(.debug_loc) }
	.debug_macinfo     0 : { *(.debug_macinfo) }

	/* SGI/MIPS DWARF 2 extensions. */
	.debug_weaknames   0 : { *(.debug_weaknames) }
	.debug_funcnames   0 : { *(.debug_funcnames) }
	.debug_typenames   0 : { *(.debug_typenames) }
	.debug_varnames    0 : { *(.debug_varnames) }

	/* DWARF 3. */
	.debug_pubtypes    0 : { *(.debug_pubtypes) }
	.debug_ranges      0 : { *(.debug_ranges) }

	/* DWARF 5. */
	.debug_addr        0 : { *(.debug_addr) }
	.debug_line_str    0 : { *(.debug_line_str) }
	.debug_loclists    0 : { *(.debug_loclists) }
	.debug_macro       0 : { *(.debug_macro) }
	.debug_names       0 : { *(.debug_names) }
	.debug_rnglists    0 : { *(.debug_rnglists) }
	.debug_str_offsets 0 : { *(.debug_str_offsets) }
	.debug_sup         0 : { *(.debug_sup) }

	.gnu.attributes    0 : { KEEP (*(.gnu.attributes)) }
	/DISCARD/ : { *(.note.GNU-stack) *(.gnu_debuglink) *(.gnu.lto_*) }
}
