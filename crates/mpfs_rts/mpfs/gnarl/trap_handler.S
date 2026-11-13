/*
 * SPDX-FileCopyrightText: 2019 AdaCore
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * Derived from alire-project/bb-runtimes riscv/src/trap_handler.S @ 09e7cd6
 * (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC: the guard word at
 * the lower end of the interrupt stack (issue #91). The context save and restore are the
 * upstream code. See crates/mpfs_rts/README.md, "Interrupt stack".
 *
 * The guard word is the address of __interrupt_stack_start stored at __interrupt_stack_start:
 * the lowest 8 bytes of the stack, which nothing but an overflow writes. It is armed before
 * main (an entry of .preinit_array, which start.S runs) and by Initialize_Interrupts, and
 * checked at the exit of every trap, here, and in the last chance handler of the runtime
 * (Ada.Exceptions.Last_Chance_Handler, which reads the same word). The stored value is the
 * address of the word so that the check is `la`, `ld`, `bne` and needs no constant. An
 * overflow leaves exactly that value there only if the overrunning frame stores the address
 * of the stack bottom at the very word.
 *
 * Only the tasking profiles link this file, and only an image that uses the interrupt stack
 * (the object that declares it, System.BB.Interrupts, pulls this file in), so nothing here
 * costs an image that has no interrupt stack. __interrupt_stack_start == __interrupt_stack_end
 * means "no stack": the arming does nothing.
 */
/* @req RTS-023 */

#include "riscv_def.h"

        /* Arm the guard word of the interrupt stack. Called before main through .preinit_array
         * (no arguments, a0 - a7 are not used) and by System.BB.Interrupts.Initialize_Interrupts.
         * One 64-bit store, the memory is ECC (a partial store would read the old word). */
        .section .text.__mpfs_interrupt_guard_arm,"ax",@progbits
        .globl __mpfs_interrupt_guard_arm
        .type __mpfs_interrupt_guard_arm,@function
__mpfs_interrupt_guard_arm:
        la      t0, __interrupt_stack_start
        la      t1, __interrupt_stack_end
        bgeu    t0, t1, 1f              /* no interrupt stack in this image */
        sd      t0, 0(t0)
1:      ret
        .size __mpfs_interrupt_guard_arm, . - __mpfs_interrupt_guard_arm

        .section .preinit_array,"aw",@preinit_array
        .balign 8
        .dword __mpfs_interrupt_guard_arm

        .section .text
        .globl __gnat_trap_entry
        .type __gnat_trap_entry,@function

        /* The trap handler must be 4-byte align not to override the
         * mode field of the mtvec register.
         */
        .align 4

__gnat_trap_entry:

        /* In this piece of code the words trap and interrupt have the same
         * meaning. Trap is more correct with regards to the architecture,
         * but interrupt is historically used in the run-time for symbols like
         * __interrupt_stacks_start.
         */

        /* Note that we can erase tp (Thread Pointer) value here because it
         * designed for thread local storage (TLS) that we do not provide in
         * Ravenscar run-time.
         */

        /* The argument registers (a0-7) must be preserved until the call to
         * __gnat_trap_handler because they may contain arguments for system
         * calls.
         */

        /* Check if sp is already in an interrupt stack (nested interrupt) */
        la      tp, __interrupt_stack_start
        bgt     tp, sp, not_in_interrupt_stack // SP is below the interrupt stack
        la      tp, __interrupt_stack_end
        blt     tp, sp, not_in_interrupt_stack // SP is above the interrupt stack

        mv      tp, sp
        j       in_interrupt_stack

not_in_interrupt_stack:
        /* Load the interrupt stack pointer */
        la      tp, interrupt_stack_table
        LREG    tp, 0(tp)

in_interrupt_stack:

        /* At this point gp contains the stack pointer for the trap */

save_interrupted_context:

        /* Allocate a frame */
        addi tp, tp, -FRAME_SIZE

        /* Save the context of the interrupted task (Ti) in the interrupt
         * stack.
         */

        SREG x1, 0(tp)
        SREG x2, 1*REGBYTES(tp)
        SREG x3, 2*REGBYTES(tp)
        /* x4 is tp which we don't need to save */
        SREG x5, 4*REGBYTES(tp)
        SREG x6, 5*REGBYTES(tp)
        SREG x7, 6*REGBYTES(tp)
        SREG x8, 7*REGBYTES(tp)
        SREG x9, 8*REGBYTES(tp)
        SREG x10, 9*REGBYTES(tp)
        SREG x11, 10*REGBYTES(tp)
        SREG x12, 11*REGBYTES(tp)
        SREG x13, 12*REGBYTES(tp)
        SREG x14, 13*REGBYTES(tp)
        SREG x15, 14*REGBYTES(tp)
        SREG x16, 15*REGBYTES(tp)
        SREG x17, 16*REGBYTES(tp)
        SREG x18, 17*REGBYTES(tp)
        SREG x19, 18*REGBYTES(tp)
        SREG x20, 19*REGBYTES(tp)
        SREG x21, 20*REGBYTES(tp)
        SREG x22, 21*REGBYTES(tp)
        SREG x23, 22*REGBYTES(tp)
        SREG x24, 23*REGBYTES(tp)
        SREG x25, 24*REGBYTES(tp)
        SREG x26, 25*REGBYTES(tp)
        SREG x27, 26*REGBYTES(tp)
        SREG x28, 27*REGBYTES(tp)
        SREG x29, 28*REGBYTES(tp)
        SREG x30, 29*REGBYTES(tp)
        SREG x31, 30*REGBYTES(tp)

#ifndef __riscv_float_abi_soft
        FSREG f0, 31*REGBYTES(tp)
        FSREG f1, 32*REGBYTES(tp)
        FSREG f2, 33*REGBYTES(tp)
        FSREG f3, 34*REGBYTES(tp)
        FSREG f4, 35*REGBYTES(tp)
        FSREG f5, 36*REGBYTES(tp)
        FSREG f6, 37*REGBYTES(tp)
        FSREG f7, 38*REGBYTES(tp)
        FSREG f8, 39*REGBYTES(tp)
        FSREG f9, 40*REGBYTES(tp)
        FSREG f10, 41*REGBYTES(tp)
        FSREG f11, 42*REGBYTES(tp)
        FSREG f12, 43*REGBYTES(tp)
        FSREG f13, 44*REGBYTES(tp)
        FSREG f14, 45*REGBYTES(tp)
        FSREG f15, 46*REGBYTES(tp)
        FSREG f16, 47*REGBYTES(tp)
        FSREG f17, 48*REGBYTES(tp)
        FSREG f18, 49*REGBYTES(tp)
        FSREG f19, 50*REGBYTES(tp)
        FSREG f20, 51*REGBYTES(tp)
        FSREG f21, 52*REGBYTES(tp)
        FSREG f22, 53*REGBYTES(tp)
        FSREG f23, 54*REGBYTES(tp)
        FSREG f24, 55*REGBYTES(tp)
        FSREG f25, 56*REGBYTES(tp)
        FSREG f26, 57*REGBYTES(tp)
        FSREG f27, 58*REGBYTES(tp)
        FSREG f28, 59*REGBYTES(tp)
        FSREG f29, 60*REGBYTES(tp)
        FSREG f30, 61*REGBYTES(tp)
        FSREG f31, 62*REGBYTES(tp)
#endif

        /* Set the stack pointer for the trap handler */
        mv sp, tp

        /* Save mepc. mepc will not be preserved through trap handler and
         * context switches call but s1 will.
         */
        csrr s1, mepc

        /* Call the trap handler */
        call __gnat_trap_handler

        /* Disable interrupts */
        li      t0, MSTATUS_MIE
        csrc    mstatus, t0

        /* Check the guard word of the interrupt stack (issue #91): the handler returned, so
         * the frames it used are gone, but the word at the lower end of the stack is not the
         * address of its own address if they reached it. Nothing is lost by the check when
         * the word is intact: three instructions. */
        la      t0, __interrupt_stack_start
        ld      t1, 0(t0)
        bne     t0, t1, .Linterrupt_stack_overflow

        /* Check if we need a context switch */
        call __gnat_context_switch_needed
        beqz a0, .Lno_context_switch

        /* Yes, we need a context switch */

        /* The context of the interrupted task (Ti) lives in the interrupt
         * stack because it was saved by the code above.
         */

        /* The call to __gnat_trap_context_switch will save the trap/interrupt
         * context (where we are now) in the context buffer of Ti, load the
         * context of another task, and jump to the code of this other task.
         */

        /* Save interrupt stack pointer in to make sure Ti context is not
         * smashed if a trap occurs when the next task is running.
         */
        la      t0, interrupt_stack_table
        SREG    sp, 0(t0)

        /* Context switch from a trap */
        call __gnat_pre_context_switch
        call __gnat_context_switch

        /* When Ti will be scheduled again, the context switch will restore the
         * trap/interrupt context (where we are now). So the execution will
         * resume from here and the following code will restore Ti context
         * from the interrupt stack and resume Ti.
         */

        /* Deallocate the frame on the interrupt stack */
        addi    t1, sp, FRAME_SIZE
        la      t0, interrupt_stack_table
        SREG    t1, 0(t0)

.Lno_context_switch:

        /* Remain in M-mode after mret */
        li      t0, MSTATUS_MPP
        csrs    mstatus, t0

        /* Enable interrupt after mret */
        li      t0, MSTATUS_MPIE
        csrs    mstatus, t0

        /* Restore mepc */
        csrw    mepc, s1

        /* Use tp as temporary register again */
        mv      tp, sp

        /* Restore Ti context */

load_interrupted_context:

        LREG x1, 0*REGBYTES(tp)
        LREG x2, 1*REGBYTES(tp)
        LREG x3, 2*REGBYTES(tp)
        /* x4 is tp which we didn't save here */
        LREG x5, 4*REGBYTES(tp)
        LREG x6, 5*REGBYTES(tp)
        LREG x7, 6*REGBYTES(tp)
        LREG x8, 7*REGBYTES(tp)
        LREG x9, 8*REGBYTES(tp)
        LREG x10, 9*REGBYTES(tp)
        LREG x11, 10*REGBYTES(tp)
        LREG x12, 11*REGBYTES(tp)
        LREG x13, 12*REGBYTES(tp)
        LREG x14, 13*REGBYTES(tp)
        LREG x15, 14*REGBYTES(tp)
        LREG x16, 15*REGBYTES(tp)
        LREG x17, 16*REGBYTES(tp)
        LREG x18, 17*REGBYTES(tp)
        LREG x19, 18*REGBYTES(tp)
        LREG x20, 19*REGBYTES(tp)
        LREG x21, 20*REGBYTES(tp)
        LREG x22, 21*REGBYTES(tp)
        LREG x23, 22*REGBYTES(tp)
        LREG x24, 23*REGBYTES(tp)
        LREG x25, 24*REGBYTES(tp)
        LREG x26, 25*REGBYTES(tp)
        LREG x27, 26*REGBYTES(tp)
        LREG x28, 27*REGBYTES(tp)
        LREG x29, 28*REGBYTES(tp)
        LREG x30, 29*REGBYTES(tp)
        LREG x31, 30*REGBYTES(tp)

#ifndef __riscv_float_abi_soft
        FLREG f0, 31*REGBYTES(tp)
        FLREG f1, 32*REGBYTES(tp)
        FLREG f2, 33*REGBYTES(tp)
        FLREG f3, 34*REGBYTES(tp)
        FLREG f4, 35*REGBYTES(tp)
        FLREG f5, 36*REGBYTES(tp)
        FLREG f6, 37*REGBYTES(tp)
        FLREG f7, 38*REGBYTES(tp)
        FLREG f8, 39*REGBYTES(tp)
        FLREG f9, 40*REGBYTES(tp)
        FLREG f10, 41*REGBYTES(tp)
        FLREG f11, 42*REGBYTES(tp)
        FLREG f12, 43*REGBYTES(tp)
        FLREG f13, 44*REGBYTES(tp)
        FLREG f14, 45*REGBYTES(tp)
        FLREG f15, 46*REGBYTES(tp)
        FLREG f16, 47*REGBYTES(tp)
        FLREG f17, 48*REGBYTES(tp)
        FLREG f18, 49*REGBYTES(tp)
        FLREG f19, 50*REGBYTES(tp)
        FLREG f20, 51*REGBYTES(tp)
        FLREG f21, 52*REGBYTES(tp)
        FLREG f22, 53*REGBYTES(tp)
        FLREG f23, 54*REGBYTES(tp)
        FLREG f24, 55*REGBYTES(tp)
        FLREG f25, 56*REGBYTES(tp)
        FLREG f26, 57*REGBYTES(tp)
        FLREG f27, 58*REGBYTES(tp)
        FLREG f28, 59*REGBYTES(tp)
        FLREG f29, 60*REGBYTES(tp)
        FLREG f30, 61*REGBYTES(tp)
        FLREG f31, 62*REGBYTES(tp)
#endif

        /* Return from trap */
        mret

        /* The interrupt stack overflowed: there is nothing to return to (the saved context
         * may be gone, and the memory below the stack is damaged). Continue on the stack of
         * the environment task, which is in no use that matters, and end in the last chance
         * handler with the message "interrupt stack overflow" (an Ada procedure of
         * System.BB.Interrupts that raises Program_Error; it does not return: no restart
         * of the partition). */
.Linterrupt_stack_overflow:
        la      sp, __stack_end
        call    __mpfs_interrupt_stack_overflow
        .size __gnat_trap_entry, . - __gnat_trap_entry
