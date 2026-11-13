/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
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
 *   REGION_FAST_TEXT  ITIM, REGION_FAST_DATA DTIM, REGION_FAST_LOAD the region the image holds
 *                     their bytes in: names for the hook of the application, the runtime defines
 *                     no section in them
 *
 * Layout of REGION_RAM, from the bottom:
 *
 *   .bss | interrupt stacks | .noinit | stack of the environment task | heap ... | trap record
 *
 * The values that vary with the partition come from --defsym (link-time interface,
 * see config/README.md): __stack_size, __interrupt_stack_size, __mpfs_harts_mask, __mpfs_boot_role
 * and the MPFS_*_LENGTH symbols of mpfs-memory.ld. None has a default: a link without one
 * fails ("undefined symbol ... referenced in expression"), and an invalid value fails an
 * ASSERT at the end of this file.
 *
 * Symbols for the runtime and the start code:
 *   __data_load __data_start __data_end __bss_start __bss_end
 *   __interrupt_stack_start __interrupt_stack_end __stack_start __stack_end
 *   _end __heap_start __heap_end   (the heap ends where the trap record starts)
 *   __global_pointer$  __eh_frame_start __eh_frame_end  (for the zero-cost exceptions)
 *   __preinit_array_start/_end __init_array_start/_end __fini_array_start/_end  (the constructor
 *                      arrays, 8-byte entries; start.S calls the first two before main)
 *   __gnat_gdb_cpu_first_id  (a 32-bit constant for the debugger: the lowest hart of the mask)
 *   __mpfs_trap_record  (the 32 bytes the trap stub of start.S writes, see there)
 *   __fast_text_start/_end/_load and __fast_data_start/_end/_load  (defined by the hook of the
 *                      application for code in the ITIM and data in the DTIM; the runtime checks the
 *                      memory and copies, with start_fast.S; empty by default)
 */
/* @req RTS-004, RTS-017, RTS-022 */

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
	.fini : { KEEP(*(.fini)) } > REGION_TEXT

	.ctors : { KEEP(SORT_BY_NAME(*)(.ctors)) } > REGION_TEXT
	.dtors : { KEEP(SORT_BY_NAME(*)(.dtors)) } > REGION_TEXT

	/* The constructor arrays that __libc_init_array of the C library runs before main (the
	 * embedded runtime: frame_dummy of crtbegin.o is the only entry that the runtime itself
	 * has, it registers .eh_frame with libgcc). The symbols are defined here, not
	 * PROVIDEd, so that the weak references of __libc_init_array always bind to them: an
	 * image without constructors has empty arrays and start.S calls nothing. The arrays hold
	 * absolute addresses of the static link (no relocation at run time) and stay in the
	 * region of the code. */
	.preinit_array : ALIGN(8) {
		__preinit_array_start = .;
		KEEP (*(.preinit_array))
		__preinit_array_end = .;
	} > REGION_TEXT

	.init_array : ALIGN(8) {
		__init_array_start = .;
		KEEP (*(SORT_BY_INIT_PRIORITY(.init_array.*) SORT_BY_INIT_PRIORITY(.ctors.*)))
		KEEP (*(.init_array EXCLUDE_FILE (*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o) .ctors))
		__init_array_end = .;
	} > REGION_TEXT

	.fini_array : ALIGN(8) {
		__fini_array_start = .;
		KEEP (*(SORT_BY_INIT_PRIORITY(.fini_array.*) SORT_BY_INIT_PRIORITY(.dtors.*)))
		KEEP (*(.fini_array EXCLUDE_FILE (*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o) .dtors))
		__fini_array_end = .;
	} > REGION_TEXT

	.rodata : {
		*(.rdata)
		*(.rodata .rodata.* .gnu.linkonce.r*)
		. = ALIGN(4);
	} > REGION_TEXT

	/* The unwind tables of the zero-cost exceptions. The embedded runtime is linked with crtbegin.o first and crtend.o
	 * last (link-zcx.spec): the empty .eh_frame of crtbegin.o is the first input, so
	 * __eh_frame_start is its __EH_FRAME_BEGIN__, which frame_dummy passes to libgcc's
	 * __register_frame_info (run from .init_array by start.S), and the zero word of crtend.o
	 * ends the list. The zero word of this script ends it in an image without crtend.o (light,
	 * light-tasking); it is not part of the range __eh_frame_start .. __eh_frame_end, which is what
	 * a search without registration (a fallback of the zero-cost exceptions) walks. */
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
		*(.tm_clone_table)	/* empty: crtbegin.o and crtend.o of the embedded runtime */
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

	/* The contract between the hook and start.S: for the code (.fast_text, ITIM) and for the data
	 * (.fast_data, DTIM) the hook defines __fast_<kind>_start and __fast_<kind>_end (the run
	 * addresses) and __fast_<kind>_load (where the image holds the bytes). start.S checks that the
	 * memory is there and copies the bytes. A kind that the hook does not define is empty: the
	 * defaults are one address, the start of .data (a real address, so that the pc-relative la of
	 * start.S reaches it from wherever the image is), and nothing is checked or copied. They are
	 * set here, before the hook: an assignment of the hook behind them wins, whereas a PROVIDE
	 * behind the hook would overwrite the hook's assignments of the same names. */
	PROVIDE(__fast_text_start = __data_start);
	PROVIDE(__fast_text_end   = __data_start);
	PROVIDE(__fast_text_load  = __data_start);
	PROVIDE(__fast_data_start = __data_start);
	PROVIDE(__fast_data_end   = __data_start);
	PROVIDE(__fast_data_load  = __data_start);

	/* The hook of the application: an application that places code or data of its own (in the
	 * ITIM or DTIM, in a region of its own) ships its own app-sections.ld and puts its -L in
	 * front of the runtime's; ld takes the first INCLUDE it finds in the -L order. The file of the
	 * runtime is empty: the runtime does not declare sections for what an application chooses.
	 * It comes before .bss, the stacks and the trap record, which end the RAM region.
	 *
	 * Code and data that an application runs from the local memories (ITIM, and on the E51
	 * DTIM) are such a choice: the hook defines the output sections, with the VMA in
	 * REGION_FAST_TEXT or REGION_FAST_DATA and the LMA in REGION_FAST_LOAD, and the three symbols
	 * of each kind that start_fast.S copies and checks by (see above). */
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

	/* The interrupt stacks. System.BB.Interrupts (the runtime of the tasking profiles) declares
	 * one byte for each CPU in .noinit.interrupt_stacks; each of them becomes __interrupt_stack_size
	 * bytes, the stack that the trap handler finds between the two symbols and that the partition
	 * data sizes. An image without that unit has no input here and no stack: start == end. KEEP,
	 * because nothing refers to the bytes themselves. */
	.interrupt_stacks (NOLOAD) : ALIGN(16) {
		__interrupt_stack_start = .;
		KEEP(*(.noinit.interrupt_stacks))
		. = __interrupt_stack_start + (. - __interrupt_stack_start) * __interrupt_stack_size;
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

/* The constructor arrays hold 8-byte entries that start.S loads and calls; an entry of another size
 * (an object that puts a 4-byte word into .init_array) would be read as half of one. */
ASSERT(((__preinit_array_start | __preinit_array_end | __init_array_start | __init_array_end |
         __fini_array_start | __fini_array_end) & 7) == 0,
       ".preinit_array, .init_array or .fini_array is not 8-byte aligned or does not hold whole 8-byte entries")
ASSERT(__preinit_array_start <= __preinit_array_end && __init_array_start <= __init_array_end &&
       __fini_array_start <= __fini_array_end && __preinit_array_end == __init_array_start &&
       __init_array_end <= __fini_array_start,
       "the constructor arrays are not .preinit_array and .init_array in one run, then .fini_array")

/* .eh_frame: the range is 8-byte aligned (libgcc reads it with aligned loads) and in order. */
ASSERT((__eh_frame_start & 7) == 0 && __eh_frame_start <= __eh_frame_end,
       ".eh_frame is not 8-byte aligned or its end lies before its start")

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
       (SIZEOF(.fini) == 0 || LOADADDR(.fini) > LOADADDR(.text)) &&
       (SIZEOF(.preinit_array) == 0 || LOADADDR(.preinit_array) > LOADADDR(.text)) &&
       (SIZEOF(.init_array) == 0 || LOADADDR(.init_array) > LOADADDR(.text)) &&
       (SIZEOF(.fini_array) == 0 || LOADADDR(.fini_array) > LOADADDR(.text)) &&
       (SIZEOF(.ctors) == 0 || LOADADDR(.ctors) > LOADADDR(.text)) &&
       (SIZEOF(.dtors) == 0 || LOADADDR(.dtors) > LOADADDR(.text)) &&
       (SIZEOF(.data) == 0 || LOADADDR(.data) > LOADADDR(.text)) &&
       (SIZEOF(.srodata) == 0 || LOADADDR(.srodata) > LOADADDR(.text)) &&
       (SIZEOF(.sdata) == 0 || LOADADDR(.sdata) > LOADADDR(.text)) &&
       (SIZEOF(.sdata2) == 0 || LOADADDR(.sdata2) > LOADADDR(.text)) &&
       (__fast_text_end == __fast_text_start || __fast_text_load > LOADADDR(.text)) &&
       (__fast_data_end == __fast_data_start || __fast_data_load > LOADADDR(.text)),
       "a loadable section lies below .text: _start is not at the start of the lowest segment")

/* start.S copies .fast_text and .fast_data (whatever the hook defines for them) in 8-byte units, from
 * the load address to the run address; an empty range is nothing to do, a reversed one is a fault
 * of the hook. */
ASSERT(__fast_text_end >= __fast_text_start && __fast_data_end >= __fast_data_start,
       "app-sections.ld: __fast_text_end or __fast_data_end lies below its start")
/* An image with code or data in the local memories must have the start code that checks and
 * copies them (start_fast.o, which Mpfs_Link.Fast_Switches puts on the link line; the hook,
 * included inside SECTIONS, cannot do it). The plain start code would never copy. */
ASSERT((__fast_text_end == __fast_text_start && __fast_data_end == __fast_data_start) ||
       DEFINED(__mpfs_start_fast),
       "a __fast_* range is defined but the start code is start.S: link with Mpfs_Link.Fast_Switches (start_fast.S), nothing would copy it")
ASSERT(((__fast_text_start | __fast_text_end | __fast_text_load) & 7) == 0 &&
       ((__fast_data_start | __fast_data_end | __fast_data_load) & 7) == 0,
       "app-sections.ld: __fast_*_start, _end and _load must be multiples of 8 (start.S copies 64-bit words)")
