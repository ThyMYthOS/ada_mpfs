--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  elab_test: the elaboration of the units of the program, before its main
--  procedure runs (the constructors of the runtime and the binder's order of
--  elaboration). Three units that depend on each other (Elab_A, Elab_B and
--  Elab_C) note themselves in a log and compute a value from the value of
--  the unit before; the main program checks the order and the values, and
--  that nothing else was elaborated. The program of a tasking profile adds a
--  library-level task (examples/elab_tasking_test).
--
--  Reported with Test_Report as elab_test_e51 or elab_test_u54.
--
--  @verifies RTS-018

with Bare_Console;
with Elab_Checks;
with Elab_Log;
with Test_Name;
with Test_Report;

procedure Elab_Test is

   use type Bare_Console.U64;

begin
   Test_Report.Start
     (if Bare_Console.Hart_Id = 0 then Test_Name.Base & "_e51"
      else Test_Name.Base & "_u54");
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   Elab_Checks.Chain;
   Test_Report.Check
     (Elab_Log.Count = 3, "no other unit noted itself in the log");

   Test_Report.Finish;
end Elab_Test;
