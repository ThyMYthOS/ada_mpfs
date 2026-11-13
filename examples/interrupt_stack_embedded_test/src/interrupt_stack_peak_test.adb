--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  interrupt_stack_peak_test: the first unwind inside a trap handler fits
--  the interrupt stack with a margin of 50 % (issue #91). The program paints
--  the interrupt stack, executes the illegal instruction of
--  examples/trap_test (fault.S), and the last chance handler (Istack_Handler)
--  reads the high-water mark after it has reported. The embedded profile
--  makes libgcc sort its frame descriptions at the first exception of the
--  program, here the one of the trap: that is the deepest use of the stack.
--  Build it with a large --interrupt-stack-size to measure the peak: the
--  report says it.
--
--  Reported with Test_Report as <Test_Name.Peak>_e51 or _u54.

with Ada.Real_Time;
with Bare_Console;
with Istack_Check;
with Istack_Handler;
pragma Unreferenced (Istack_Handler);
--  Only for the handler it exports
with Test_Name;
with Test_Report;

procedure Interrupt_Stack_Peak_Test is

   use type Ada.Real_Time.Time;
   use type Bare_Console.U64;

   procedure Fault
     with Import, Convention => C, External_Name => "trap_test_fault";

   Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   --  Links the tasking part of the runtime in the light-tasking profile,
   --  which is what installs the trap handler there

begin
   Test_Report.Start
     (if Bare_Console.Hart_Id = 0 then Test_Name.Peak & "_e51"
      else Test_Name.Peak & "_u54");
   Istack_Check.Start (Istack_Check.Peak_Of_Trap);
   Fault;

   --  Not reached.
   Test_Report.Check
     (Ada.Real_Time.Clock < Start, "the illegal instruction did not trap");
   Test_Report.Finish;
end Interrupt_Stack_Peak_Test;
