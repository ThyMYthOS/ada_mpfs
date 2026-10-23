/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 * Derived from examples/common/ld/place-lim.ld of this repository (same author, Apache-2.0), whose
 * layout follows the common RAM layout of the GNAT bare-board runtimes; split from the placement.
 *
 * sections.ld -- the SECTIONS of every image linked with the runtime mpfs_rts, for every
 * placement. A placement script (place-lim.ld, place-scratchpad.ld, place-envm.ld) includes
 * mpfs-memory.ld, binds the region names below to MEMORY regions with REGION_ALIAS, and then
 * includes this file; after the load sections it includes app-sections.ld, the hook of the
 * application (empty in the runtime):
 *
 *   REGION_TEXT       code, read-only data, .eh_frame        (VMA = LMA)
 *   REGION_DATA       VMA of .data and the small-data sections
 *   REGION_DATA_LOAD  LMA of the same: the same region as REGION_DATA, or the one the boot
 *                     stage loads from (place-envm.ld); start.S copies when they differ
 *   REGION_RAM        .bss, the stacks, the heap and the trap record
 *   REGION_FAST_TEXT  VMA of .fast_text (ITIM), REGION_FAST_DATA VMA of .fast_data (DTIM),
 *   REGION_FAST_LOAD  LMA of both
 *
 * Layout of REGION_RAM, from the bottom:
 *
 *   .bss | interrupt stacks | .noinit | stack of the environment task | heap ... | trap record
 *
 * The values that vary with the partition come from --defsym (link-time interface, master plan
 * #41 section 4.2): __stack_size, __interrupt_stack_size, __mpfs_harts_mask, __mpfs_boot_role
 * and the MPFS_*_LENGTH symbols of mpfs-memory.ld. None has a default: a link without one
 * fails ("undefined symbol ... referenced in expression"), and an invalid value fails an
 * ASSERT at the end of this file.
 *
 * Symbols for the runtime and the start code:
 *   __data_load __data_start __data_end __bss_start __bss_end
 *   __interrupt_stack_start __interrupt_stack_end __stack_start __stack_end
 *   _end __heap_start __heap_end   (the heap ends where the trap record starts)
 *   __global_pointer$  __eh_frame_start __eh_frame_end  (for the zero-cost exceptions, R8)
 *   __gnat_gdb_cpu_first_id  (a 32-bit constant for the debugger: the lowest hart of the mask)
 *   __mpfs_trap_record  (the 32 bytes the trap stub of start.S writes, see there)
 */

ENTRY(_start)
OUTPUT_ARCH("riscv")

SECTIONS
{
	.text : ALIGN(4) {
		__text = .;
		/* start.S first: _start is the first instruction of the lowest segment (QEMU's
		 * -kernel starts every hart at the lowest loaded address, not at e_entry). */
		KEEP (*(SORT_NONE(.start)))
		*(.text .text.* .gnu.linkonce.t*)
		*(.gnu.warning)
	} > REGION_TEXT

	.init : { KEEP(*(.init)) } > REGION_TEXT

	.ctors : { KEEP(SORT_BY_NAME(*)(.ctors)) } > REGION_TEXT
	.dtors : { KEEP(SORT_BY_NAME(*)(.dtors)) } > REGION_TEXT

	.rodata : {
		*(.rdata)
		*(.rodata .rodata.* .gnu.linkonce.r*)
		. = ALIGN(4);
	} > REGION_TEXT

	/* The unwind tables for R8, registered with __register_frame_info (start, end). The zero
	 * word after __eh_frame_end terminates the list for libgcc, as crtend.o does in a hosted
	 * link; it is not part of the range. */
	.eh_frame : ALIGN(8) {
		__eh_frame_start = .;
		KEEP (*(.eh_frame))
		__eh_frame_end = .;
		LONG(0)
		. = ALIGN(4);
	} > REGION_TEXT

	.gcc_except_table : {
		*(.gcc_except_table .gcc_except_table.*)
	} > REGION_TEXT

	/* The debugger asks for the hardware id of the first CPU of the runtime. It is no longer
	 * hard-wired (the upstream board exports 1 from s-bbbopa.ads): it is the lowest hart of
	 * the partition. Nothing in the image refers to the symbol, so the section is the only
	 * definition; that also makes the unit of the library that exports the upstream constant
	 * unnecessary, so it is not pulled in. */
	.mpfs_gdb : ALIGN(4) {
		__gnat_gdb_cpu_first_id = .;
		LONG((__mpfs_harts_mask & 1) ? 0 :
		     ((__mpfs_harts_mask & 2) ? 1 :
		      ((__mpfs_harts_mask & 4) ? 2 :
		       ((__mpfs_harts_mask & 8) ? 3 : 4))));
	} > REGION_TEXT

	.data : ALIGN(8) {
		__data_start = .;
		*(.data .data.* .gnu.linkonce.d*)
	} > REGION_DATA AT> REGION_DATA_LOAD

	.srodata : ALIGN(8) /* both the virtual and the load address */
	{
		PROVIDE( __global_pointer$ = . + 0x800 );
		*(.srodata.cst16)
		*(.srodata.cst8)
		*(.srodata.cst4)
		*(.srodata.cst2)
		*(.srodata .srodata.*)
	} > REGION_DATA AT> REGION_DATA_LOAD

	.sdata : ALIGN(8)
	{
		*(.sdata .sdata.*)
		*(.gnu.linkonce.s.*)
	} > REGION_DATA AT> REGION_DATA_LOAD

	.sdata2 : ALIGN(8)
	{
		*(.sdata2 .sdata2.*)
		*(.gnu.linkonce.s2.*)
		. = ALIGN(8);
		__data_end = .;
	} > REGION_DATA AT> REGION_DATA_LOAD

	/* Where start.S copies .data from: the same as __data_start unless the image is loaded
	 * somewhere else than it runs. */
	__data_load = LOADADDR(.data);

	/* Code and data that belong in the local memories: ITIM (code) and, on the E51, DTIM
	 * (data). The VMA is in the local memory, the LMA in REGION_FAST_LOAD. Nothing copies
	 * them before the ITIM work package (P1.11): until then both must be empty, see the
	 * ASSERT below. */
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

	/* The hook of the application: an application that places code or data of its own (in the
	 * ITIM or DTIM, in a region of its own) ships its own app-sections.ld and puts its -L in
	 * front of the runtime's; ld takes the first INCLUDE it finds in the -L order. The file of the
	 * runtime is empty: the runtime does not declare sections for what an application chooses.
	 * It comes before .bss, the stacks and the trap record, which end the RAM region. */
	INCLUDE app-sections.ld

	.bss (NOLOAD) : ALIGN(8) {
		__bss_start = .;
		*(.sbss*)
		*(.gnu.linkonce.sb.*)
		*(.bss .bss.*)
		*(.gnu.linkonce.b.*)
		*(COMMON)
		. = ALIGN(8);
		__bss_end = .;
	} > REGION_RAM

	/* The interrupt stacks are allocated by System.BB.Interrupts (the runtime of the tasking
	 * profiles); the trap handler finds them between these two symbols. */
	.interrupt_stacks (NOLOAD) : ALIGN(16) {
		__interrupt_stack_start = .;
		*(.noinit.interrupt_stacks)
		. = ALIGN(16);
		__interrupt_stack_end = .;
	} > REGION_RAM

	/* Not cleared: Linker_Section (".noinit") of Ada objects. After the interrupt stacks:
	 * the first rule that matches takes an input section, and .noinit.* would take theirs. */
	.noinit (NOLOAD) : ALIGN(8) {
		*(.noinit .noinit.*)
	} > REGION_RAM

	.stack (NOLOAD) : ALIGN(16) {
		__stack_start = .;
		. += __stack_size;
		__stack_end = .;
	} > REGION_RAM

	_end = .;
	__heap_start = .;

	/* The last 32 bytes of the RAM region: the trap record. A fixed place for a given partition,
	 * whatever the image, and the heap stops in front of it. */
	.trap_record (ORIGIN(REGION_RAM) + LENGTH(REGION_RAM) - 32) (NOLOAD) : {
		__mpfs_trap_record = .;
		. += 32;
	} > REGION_RAM
	__heap_end = __mpfs_trap_record;

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

/* ---- Checks. A violated one stops the link with the message. ---- */

/* The partition data. */
ASSERT(__mpfs_harts_mask != 0 && (__mpfs_harts_mask & ~0x1f) == 0,
       "__mpfs_harts_mask must name harts 0 .. 4 (bits 0 .. 4) and at least one")
/* __mpfs_boot_role is read by start.S only and has no check here: a link without it must fail
 * as "undefined reference" (the script would report "undefined symbol referenced in expression"
 * if it used it), and a value other than 0 and 1 is the business of the partition data. */

/* The stacks: sizes and addresses are multiples of 16 (the ABI), the stack is not empty. */
ASSERT(__stack_size != 0,
       "__stack_size is 0: the stack of the environment task would be empty")
ASSERT((__stack_size & 15) == 0,
       "__stack_size is not a multiple of 16 (stack alignment of the RISC-V ABI)")
ASSERT((__interrupt_stack_size & 15) == 0,
       "__interrupt_stack_size is not a multiple of 16 (stack alignment of the RISC-V ABI)")
ASSERT((__stack_start & 15) == 0 && (__stack_end & 15) == 0,
       "the stack of the environment task is not 16-byte aligned")
ASSERT((__interrupt_stack_start & 15) == 0 && (__interrupt_stack_end & 15) == 0,
       "the interrupt stacks are not 16-byte aligned")
ASSERT(__interrupt_stack_end - __interrupt_stack_start <= __interrupt_stack_size,
       "the interrupt stacks of the runtime are larger than __interrupt_stack_size")

/* .data and .bss are copied and cleared in units of 8 bytes. */
ASSERT(((__data_start | __data_end | __data_load | __bss_start | __bss_end) & 7) == 0,
       ".data and .bss are not 8-byte aligned (start.S copies and clears in 8-byte units)")

/* The regions this placement needs exist: a zero length is deliberate for the regions an image
 * does not own, and a placement into one of them must say so instead of reporting an overflow
 * of some section. */
ASSERT(LENGTH(REGION_TEXT) != 0,
       "the region of the code is empty: its MPFS_*_LENGTH symbol is 0")
ASSERT(LENGTH(REGION_DATA) != 0 && LENGTH(REGION_DATA_LOAD) != 0,
       "the region of .data is empty: its MPFS_*_LENGTH symbol is 0")
ASSERT(LENGTH(REGION_RAM) != 0,
       "the region of .bss, stacks and heap is empty: its MPFS_*_LENGTH symbol is 0")

/* No overlap: the regions of RAM follow each other, and the heap lies behind the stacks and in
 * front of the trap record. */
ASSERT(__bss_end <= __interrupt_stack_start && __interrupt_stack_end <= __stack_start,
       "bss and the stacks overlap")
ASSERT(__stack_end <= __heap_start,
       "the stack and the heap overlap")
ASSERT(__heap_start <= __heap_end,
       "the image does not fit: .bss, the stacks and the trap record leave no room for the heap")
ASSERT((__mpfs_trap_record & 7) == 0,
       "the trap record is not 8-byte aligned: the RAM region does not end on a multiple of 8")

/* QEMU's -kernel (and the reset code of an image loaded by a debugger) starts the harts at the
 * lowest loaded address, not at e_entry: _start must be the first byte of the lowest segment. */
ASSERT(_start == ADDR(.text) && ADDR(.text) == LOADADDR(.text),
       "_start is not at the start of .text: start.S must come first in .text")
ASSERT((SIZEOF(.rodata) == 0 || LOADADDR(.rodata) > LOADADDR(.text)) &&
       (SIZEOF(.eh_frame) == 0 || LOADADDR(.eh_frame) > LOADADDR(.text)) &&
       (SIZEOF(.gcc_except_table) == 0 || LOADADDR(.gcc_except_table) > LOADADDR(.text)) &&
       (SIZEOF(.mpfs_gdb) == 0 || LOADADDR(.mpfs_gdb) > LOADADDR(.text)) &&
       (SIZEOF(.init) == 0 || LOADADDR(.init) > LOADADDR(.text)) &&
       (SIZEOF(.ctors) == 0 || LOADADDR(.ctors) > LOADADDR(.text)) &&
       (SIZEOF(.dtors) == 0 || LOADADDR(.dtors) > LOADADDR(.text)) &&
       (SIZEOF(.data) == 0 || LOADADDR(.data) > LOADADDR(.text)) &&
       (SIZEOF(.srodata) == 0 || LOADADDR(.srodata) > LOADADDR(.text)) &&
       (SIZEOF(.sdata) == 0 || LOADADDR(.sdata) > LOADADDR(.text)) &&
       (SIZEOF(.sdata2) == 0 || LOADADDR(.sdata2) > LOADADDR(.text)) &&
       (SIZEOF(.fast_text) == 0 || LOADADDR(.fast_text) > LOADADDR(.text)) &&
       (SIZEOF(.fast_data) == 0 || LOADADDR(.fast_data) > LOADADDR(.text)),
       "a loadable section lies below .text: _start is not at the start of the lowest segment")

/* Nothing loads .fast_text and .fast_data yet. */
ASSERT(SIZEOF(.fast_text) == 0 && SIZEOF(.fast_data) == 0,
       ".fast_text and .fast_data are not loaded before the ITIM work package (P1.11)")
