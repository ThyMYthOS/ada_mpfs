--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  interrupt_stack_overflow_test: an interrupt handler that uses more stack
--  than the interrupt stack has ends the program with the message "interrupt
--  stack overflow", and does not hang (issue #91). Built with a small stack
--  (the IMAGE_ line of example.conf: --interrupt-stack-size 2048, which is
--  enough for the alarm interrupt below). The handler of a timing event
--  runs in the interrupt context, on the interrupt stack; Istack.Overrun
--  uses a frame as large as the whole stack, which reaches below it, and
--  overwrites the guard word at its lower end, nothing else. The trap handler
--  checks the guard word when the handler returns, raises Program_Error with
--  the message, and the last chance handler of the test (Istack_Handler)
--  receives it.
--
--  Reported with Test_Report as <Test_Name.Overflow>_e51 or _u54.
--
--  @verifies RTS-023

pragma Suppress (All_Checks);

with Ada.Real_Time;
with Ada.Real_Time.Timing_Events;
with Bare_Console;
with Istack_Check;
with Istack_Handler;
pragma Unreferenced (Istack_Handler);
--  Only for the handler it exports
with Istack_Overrun;
with Test_Name;
with Test_Report;

procedure Interrupt_Stack_Overflow_Test is

   use Ada.Real_Time;
   use type Bare_Console.U64;

begin
   Test_Report.Start
     (if Bare_Console.Hart_Id = 0 then Test_Name.Overflow & "_e51"
      else Test_Name.Overflow & "_u54");
   Istack_Check.Start (Istack_Check.Overrun_In_Handler);
   Timing_Events.Set_Handler
     (Istack_Overrun.Event, Clock + Milliseconds (1),
      Istack_Overrun.Probe.Handle'Access);

   --  Not "delay until": the alarm interrupt would then find the idle task
   --  running, which has no secondary stack, and the handler of the embedded
   --  profile needs one for Exception_Message. The main program runs.

   declare
      Deadline : constant Time := Clock + Milliseconds (100);
   begin
      while Clock < Deadline loop
         null;
      end loop;
   end;

   --  Not reached: the program ends in the last chance handler.
   Test_Report.Check (False, "the overrun of the interrupt stack was found");
   Test_Report.Finish;
end Interrupt_Stack_Overflow_Test;
