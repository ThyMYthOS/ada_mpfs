--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  interrupt_stack_halt_test: the last chance handler of the runtime (this
--  image has none of its own) halts with the message "interrupt stack
--  overflow" when the guard word of the interrupt stack is not intact, and
--  not with the report of the exception that it was called for (issue #91).
--  The program overwrites the guard word, as an overrun does, and then
--  executes the illegal instruction of examples/trap_test: the trap handler
--  raises Program_Error, which ends in the last chance handler on the
--  interrupt stack without the trap handler returning, so the check at the
--  exit of the trap handler is not the one that finds it. The stack has its
--  default size and nothing but the guard word is touched, so the test does
--  not depend on what lies below the stack.
--
--  Not a test that reports (the verdict would need a last chance handler of
--  its own, which would not be the one of the runtime): tests/host/rts_istack
--  runs the image under QEMU and reads the console, which says "interrupt
--  stack overflow" and not "Unhandled".
--
--  @verifies RTS-023

with Ada.Real_Time;
with Istack;

procedure Interrupt_Stack_Halt_Test is

   use type Ada.Real_Time.Time;

   procedure Fault
     with Import, Convention => C, External_Name => "trap_test_fault";

   Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   --  Links the tasking part of the runtime in the light-tasking profile

begin
   Istack.Clobber_Guard;
   Fault;

   --  Not reached.
   if Ada.Real_Time.Clock < Start then
      null;
   end if;
end Interrupt_Stack_Halt_Test;
