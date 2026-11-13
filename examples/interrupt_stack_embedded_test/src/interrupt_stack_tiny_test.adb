--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  interrupt_stack_tiny_test: a program whose interrupt stack is far too
--  small ends with the message "interrupt stack overflow" and does not hang
--  (issue #91). The IMAGE_ line of example.conf gives it a stack of 512
--  bytes (--interrupt-stack-size 512): the trap frame alone is 256 bytes on
--  the E51 and all of it on the U54, so the handler, the raise and the print
--  of the last chance handler run below the lower end of the stack, over
--  whatever lies there (a few hundred bytes of the .bss of the runtime).
--
--  The program executes the illegal instruction of examples/trap_test. The
--  trap handler raises Program_Error, which ends in the last chance handler
--  of the runtime (this image has none of its own): it finds the guard word
--  at the lower end of the stack overwritten and halts with the message,
--  not with the report of the exception that it was called for.
--
--  A test of the light-tasking profile only: what an overrun destroys is
--  whatever lies below the stack, and the unwinder of the embedded profile
--  needs 8 KiB, which on a stack of this size treads on the heap and the
--  libgcc tables before anything can check the guard word (the software
--  guard finds an overrun after it has happened; interrupt_stack_halt_test
--  and interrupt_stack_overflow_test do not depend on the neighbours).
--
--  Not a test that reports (the verdict would need a last chance handler of
--  its own, which would not be the one of the runtime): tests/host/rts_istack
--  runs the image under QEMU and reads the console, which says "interrupt
--  stack overflow" and not "Unhandled".
--
--  @verifies RTS-023

with Ada.Real_Time;

procedure Interrupt_Stack_Tiny_Test is

   use type Ada.Real_Time.Time;

   procedure Fault
     with Import, Convention => C, External_Name => "trap_test_fault";

   Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   --  Links the tasking part of the runtime

begin
   Fault;

   --  Not reached.
   if Ada.Real_Time.Clock < Start then
      null;
   end if;
end Interrupt_Stack_Tiny_Test;
