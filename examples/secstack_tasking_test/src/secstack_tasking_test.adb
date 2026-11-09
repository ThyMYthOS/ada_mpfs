--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  secstack_tasking_test: the secondary stack of the light-tasking runtime of
--  crates/mpfs_rts (tasks, no propagation of exceptions). The checks of
--  secstack_test that this runtime can do: the results, the balance, the
--  independence of the stacks of two tasks that work at the same time (the
--  task has its own, 4096 bytes); the stack of the environment task has the
--  default of the profile (8 KiB), and exhausting it ends in the last chance
--  handler (Secstack_Last_Chance) with the Storage_Error of the runtime,
--  which reports the size and the verdict.
--
--  Reported with Test_Report as secstack_tasking_test_e51 or
--  secstack_tasking_test_u54.
--
--  @verifies RTS-013

with Ada.Real_Time; use Ada.Real_Time;

with System.Secondary_Stack;

with Bare_Console;
with Secstack_Cases;
with Secstack_Last_Chance;
with Secstack_Worker;
with Test_Report;

procedure Secstack_Tasking_Test is

   package SS renames System.Secondary_Stack;
   use type SS.Mark_Id;

   --  The default size of a secondary stack in the light-tasking profile
   --  (crates/mpfs_rts/gen_runtime.sh).
   Default_Size : constant := 8 * 1024;

   Start_Mark : constant SS.Mark_Id := SS.SS_Mark;
   Mark       : SS.Mark_Id;
   Deadline   : Time;
   Beside_Ok  : Boolean := True;
   Balanced   : Boolean := True;

begin
   case Bare_Console.Hart_Id is
      when 0      => Test_Report.Start ("secstack_tasking_test_e51");
      when others => Test_Report.Start ("secstack_tasking_test_u54");
   end case;

   Test_Report.Check
     (Secstack_Cases.Repeat ('x', 1000) = [1 .. 1000 => 'x'],
      "a String of 1000 characters is returned");
   Test_Report.Check
     (Secstack_Cases.Join ("abc", "defg") = "abcdefg",
      "a String made of two is returned");
   Test_Report.Check
     (Secstack_Cases.Is_Pattern (Secstack_Cases.Pattern (7, 300), 7),
      "a String computed from its length is returned");

   Mark := SS.SS_Mark;
   Test_Report.Check
     (Secstack_Cases.Is_Nested (Secstack_Cases.Nested (20), 20),
      "20 levels of results made of results are right");
   Test_Report.Check
     (SS.SS_Mark = Mark, "the stack is where it was after the statement");
   Test_Report.Check
     (SS.SS_Get_Max >= 8 * 20,
      "the high-water mark covers the deepest point");

   --  A task with its own stack, at the same time as this one.
   Deadline := Clock + Seconds (5);
   while not Secstack_Worker.Done and then Clock < Deadline loop
      Mark := SS.SS_Mark;
      if not Secstack_Cases.Is_Nested (Secstack_Cases.Nested (8), 8) then
         Beside_Ok := False;
      end if;
      if SS.SS_Mark /= Mark then
         Balanced := False;
      end if;
      delay until Clock + Milliseconds (1);
   end loop;
   Test_Report.Check
     (Beside_Ok, "the environment task works beside the task");
   Test_Report.Check (Balanced, "its stack is balanced meanwhile");
   Test_Report.Check (Secstack_Worker.Done, "the task finished");
   Test_Report.Check
     (Secstack_Worker.Content_Ok,
      "the results of the task are right while the other task works too");
   Test_Report.Check
     (Secstack_Worker.Reusable, "the task's last results are right");
   Test_Report.Check
     (SS.SS_Mark = Start_Mark, "the environment task's stack is balanced");

   --  The overflow ends in the last chance handler, which finishes the test.
   Secstack_Last_Chance.Expected_Size := Default_Size;
   Secstack_Cases.Exhaust;

   --  Not reached.
   Test_Report.Check (False, "Exhaust returned");
   Test_Report.Finish;
end Secstack_Tasking_Test;
