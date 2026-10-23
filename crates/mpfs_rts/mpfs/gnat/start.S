/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * start.S -- entry point of every image linked with the runtime mpfs_rts. It replaces the
 * start-ram.S of the upstream board (which sends every hart but hart 1 into a loop and only
 * clears .bss) and is written for the partition model of the master plan: which harts run the
 * image, and whether the image is the primary one (it owns the boot flow) or a secondary one,
 * is decided at link time by two absolute symbols that the partition data sets with --defsym:
 *
 *   __mpfs_harts_mask   bit n = hart n belongs to the partition (E51 = 0, U54 = 1 .. 4)
 *   __mpfs_boot_role    1 = primary, 0 = secondary
 *
 * Both are mandatory: an image linked without one fails with "undefined reference". The
 * layout symbols (__global_pointer$, __stack_end, __data_*, __bss_*, __mpfs_trap_record)
 * come from the placement script (ld/sections.ld).
 *
 * Order, as in master plan #41, work package P1.3:
 *   1. mtvec to the trap stub (before any other instruction can trap), then gp and sp
 *   2. interrupts masked (mstatus.MIE, mie)
 *   3. hart gate: a hart that is not in the mask parks; only on a primary image the parked
 *      hart is prepared for the release of P8 (mie.MSIE, woken by a software interrupt)
 *   4. .data is copied from its load address if that differs from its address; .bss and the
 *      stacks are cleared
 *   5. mstatus.FS (images with an FPU); the constructor arrays (below); main; then __gnat_exit,
 *      which depends on the role
 *
 * The trap stub is what runs a trap until the runtime installs its own handler. It only
 * records mcause, mepc, mtval and mhartid in the 32 bytes at __mpfs_trap_record (the top of
 * the RAM region of the placement, so that a debugger finds it at the same place for a given
 * partition, whatever the image) and halts. It uses no stack and no gp: it must work from the
 * very first instruction. Record layout, little endian:
 *
 *   +0  mcause (64 bit)   +8 mepc (64 bit)   +16 mtval (64 bit)
 *   +24 magic 0x54524150 ("TRAP", low word) and mhartid (high word): one 64-bit store
 *
 * Every store of the stub is a whole 64-bit word: the LIM is ECC memory that is uninitialised
 * at power-up, and a partial store into a word that was never written is a read-modify-write
 * of garbage (an ECC fault inside the trap handler would be a double trap).
 * The magic tells a record from the random content of RAM after power-up. All harts of the
 * partition share the record: until the SMP work package only one hart writes it.
 *
 * The start code also initialises the memory that the program then uses partially: .bss and
 * both kinds of stack are cleared with 64-bit stores (ECC, as above). .noinit and the heap
 * are deliberately left alone; whether the LIM needs zeroing as a whole is a question for the
 * hardware (work packages P1.8 and P1.14).
 *
 * Hart gate, a deliberate deviation: a hart outside the mask is parked on EVERY image, also on
 * a secondary one. The reference runtime of the earlier project and step 1.3 of the work
 * package gate on the primary image only, but QEMU's reset code sends every hart to the entry
 * point with no hart gate of its own, so an ungated secondary image would run on all of them.
 * On hardware nothing but the release of the right hart reaches a secondary image, and the
 * gate costs nothing there. A parked hart of a secondary image has its mtvec, mie and
 * mstatus.MIE written (as every hart before the gate) but gets no mie.MSIE.
 *
 * Constructors (R8): the entries of .preinit_array and then of .init_array (ld/sections.ld
 * puts the two arrays one behind the other, from __preinit_array_start to __init_array_end) are
 * called in order, with no arguments, before main. The embedded runtime has exactly one of its own: the
 * frame_dummy of crtbegin.o, which registers .eh_frame with libgcc (__register_frame_info), so
 * that the unwinder finds the frame descriptions without .eh_frame_hdr; link-zcx.spec puts
 * crtbegin.o and crtend.o around the link, and C code with constructors is run the same way.
 * This is what __libc_init_array does, written out here because the light and light-tasking
 * runtimes link without libc (-nolibc), where a call would not resolve, and a weak call to an
 * undefined symbol is out of the reach of auipc/addi from an image placed above 0x8000_0000.
 * The arrays are empty in an image without constructors: one compare, nothing called. Run on
 * the one hart of the image; the SMP work package (P8) lets only the first hart of the mask
 * do this, a second registration of .eh_frame would corrupt libgcc's list.
 *
 * Test seam: if an image defines __mpfs_early_trap_hook, the stub jumps to it with the address
 * of the record in a0 instead of halting (examples/trap_test reports the record on the console
 * this way). The hook runs on the stack and gp the trap found, so it is for tests and must not
 * be used by the runtime.
 */

#define MSTATUS_MIE 0x00000008
#define MSTATUS_FS  0x00006000
#define MIE_MSIE    0x00000008

/* MSS_RESET_CR of the system registers: writing 0xDEAD resets the MSS (what the upstream board
 * does when a program ends). */
#define MSS_RESET_CR 0x20002018
#define MSS_RESET    0xDEAD

/* 0x54524150 = lui 0x54524, addi 0x150 */
#define TRAP_MAGIC_HI 0x54524
#define TRAP_MAGIC_LO 0x150

	.section .start,"ax",@progbits
	.globl _start
	.type _start,@function

_start:
	/* 1. The trap stub first, then gp and sp. */
	la      t0, __mpfs_trap_stub
	csrw    mtvec, t0
.option push
.option norelax
	la      gp, __global_pointer$
.option pop
	la      sp, __stack_end

	/* 2. Interrupts off before anything can park: wfi wakes on any pending interrupt that is
	 * enabled in mie even with mstatus.MIE clear, and a hart handed over from an earlier
	 * stage may carry a stale mie. */
	li      t0, MSTATUS_MIE
	csrc    mstatus, t0
	csrw    mie, zero

	/* 3. Hart gate: continue only if bit mhartid of the mask is set. */
	csrr    t1, mhartid
	li      t0, 1
	sll     t0, t0, t1
	lui     t2, %hi(__mpfs_harts_mask)
	addi    t2, t2, %lo(__mpfs_harts_mask)
	and     t0, t0, t2
	bnez    t0, .Lrun

	/* Not a hart of this partition. On a secondary image it belongs to somebody else and is
	 * left alone; on the primary image it is parked, prepared for the release of P8 (a software
	 * interrupt wakes it; mstatus.MIE stays clear, so it takes no trap). */
	lui     t2, %hi(__mpfs_boot_role)
	addi    t2, t2, %lo(__mpfs_boot_role)
	beqz    t2, .Lpark
	li      t0, MIE_MSIE
	csrw    mie, t0
.Lpark:
	wfi
	j       .Lpark

.Lrun:
	/* 4. .data: copy from the load address if the image is not loaded where it runs
	 * (place-envm.ld). The script makes the three symbols multiples of 8. */
	la      a0, __data_start
	la      a1, __data_end
	la      a2, __data_load
	beq     a0, a2, 2f
	bgeu    a0, a1, 2f
1:
	ld      t0, (a2)
	sd      t0, (a0)
	addi    a0, a0, 8
	addi    a2, a2, 8
	bltu    a0, a1, 1b
2:
	/* .bss */
	la      a0, __bss_start
	la      a1, __bss_end
	bgeu    a0, a1, 4f
3:
	sd      zero, (a0)
	addi    a0, a0, 8
	bltu    a0, a1, 3b
4:
	/* The interrupt stacks and the stack of the environment task (sp is at the top of the
	 * latter and nothing has been pushed yet). The sizes are multiples of 16 (ASSERT). */
	la      a0, __interrupt_stack_start
	la      a1, __interrupt_stack_end
	bgeu    a0, a1, 6f
5:
	sd      zero, (a0)
	addi    a0, a0, 8
	bltu    a0, a1, 5b
6:
	la      a0, __stack_start
	la      a1, __stack_end
	bgeu    a0, a1, 8f
7:
	sd      zero, (a0)
	addi    a0, a0, 8
	bltu    a0, a1, 7b
8:

#ifndef __riscv_float_abi_soft
	/* 5. Enable the FPU (U54 images; the E51 has none). */
	li      t0, MSTATUS_FS
	csrs    mstatus, t0
#endif

	/* The constructors: .preinit_array and .init_array are one run of 8-byte entries (ASSERT in
	 * the script), called from the first to the last; s0 and s1 survive the calls. */
	la      s0, __preinit_array_start
	la      s1, __init_array_end
9:
	bgeu    s0, s1, 10f
	ld      t0, (s0)
	jalr    t0
	addi    s0, s0, 8
	j       9b
10:

	call    main
	call    __gnat_exit
	.size _start, . - _start

	/* The end of the program, depending on the role. A primary image resets the MSS; a
	 * secondary image must not touch the system registers and halts its hart. s-macres.adb
	 * (System.Machine_Reset.Stop, and with it abort) ends here too. */
	.globl __gnat_exit
	.type __gnat_exit,@function
__gnat_exit:
	lui     t2, %hi(__mpfs_boot_role)
	addi    t2, t2, %lo(__mpfs_boot_role)
	beqz    t2, .Lhalt
	li      t0, MSS_RESET_CR
	li      t1, MSS_RESET
	sw      t1, (t0)
.Lhalt:
	wfi
	j       .Lhalt
	.size __gnat_exit, . - __gnat_exit

	.weak   _exit
	.set    _exit, __gnat_exit

	/* The trap stub (see the header). 4-byte aligned: the low bits of mtvec select the mode. */
	.balign 4
	.globl __mpfs_trap_stub
	.type __mpfs_trap_stub,@function
__mpfs_trap_stub:
	la      t0, __mpfs_trap_record
	csrr    t1, mcause
	sd      t1, 0(t0)
	csrr    t1, mepc
	sd      t1, 8(t0)
	csrr    t1, mtval
	sd      t1, 16(t0)
	lui     t2, TRAP_MAGIC_HI
	addi    t2, t2, TRAP_MAGIC_LO
	csrr    t1, mhartid
	slli    t1, t1, 32
	or      t2, t2, t1
	sd      t2, 24(t0)
	fence

	.weak   __mpfs_early_trap_hook
	la      t1, __mpfs_early_trap_hook
	beqz    t1, .Ltrap_halt
	mv      a0, t0
	jr      t1
.Ltrap_halt:
	wfi
	j       .Ltrap_halt
	.size __mpfs_trap_stub, . - __mpfs_trap_stub
