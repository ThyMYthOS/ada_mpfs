--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  elab_tasking_test: the checks of elab_test (the order of elaboration and
--  the values of three dependent units, sources of examples/elab_test) and a
--  library-level task of the highest priority: the declarative part of its
--  body was elaborated after the units of the chain, and its statements ran,
--  before the main program started.
--
--  Reported with Test_Report as elab_tasking_test_e51 or _u54 (and as
--  elab_embedded_test_* by the example of the embedded profile).

with Ada.Real_Time; use Ada.Real_Time;

with Bare_Console;
with Elab_Checks;
with Elab_Log;
with Elab_Tasks;
with Test_Name;
with Test_Report;

procedure Elab_Tasking_Test is

   use type Bare_Console.U64;

   Before_Main : constant Natural := Elab_Log.Count;
   --  What the log held when the main program started

begin
   Test_Report.Start
     (if Bare_Console.Hart_Id = 0 then Test_Name.Base & "_e51"
      else Test_Name.Base & "_u54");
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   Elab_Checks.Chain;
   Test_Report.Check
     (Before_Main = 4,
      "the task's declarative part was elaborated before main");
   Test_Report.Check
     (Elab_Log.Position (Elab_Log.Unit_Task) = 4,
      "after the units of the chain, at the activation of the task");

   Test_Report.Check
     (Elab_Tasks.Started, "and the task has run before the main program");
   delay until Clock + Milliseconds (20);
   Test_Report.Check
     (Elab_Log.Count = 4, "nothing else noted itself in the log later");

   Test_Report.Finish;
end Elab_Tasking_Test;
