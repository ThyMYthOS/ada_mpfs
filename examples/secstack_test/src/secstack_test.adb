--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  secstack_test: the secondary stack of the embedded runtime of
--  crates/mpfs_rts. Functions whose result has a size that the caller does
--  not know return it on the secondary stack; this is checked
--
--    - for the results themselves (a String of any length, a function with
--      such a function in it, 20 levels deep);
--    - for the balance: the stack is where it was after the statement;
--    - for the size: the stack of the environment task has the default of the
--      profile (16 KiB), the stack of a task the size of its aspect (4096
--      bytes), and exhausting either raises Storage_Error, after which the
--      stack is usable again;
--    - for the independence of the stacks of two tasks that work at the same
--      time.
--
--  Reported with Test_Report as secstack_test_e51 or secstack_test_u54.
--
--  @verifies RTS-013

with Ada.Real_Time; use Ada.Real_Time;

with System.Secondary_Stack;

with Bare_Console;
with Secstack_Cases;
with Secstack_Worker;
with Test_Report;

procedure Secstack_Test is

   package SS renames System.Secondary_Stack;
   use type SS.Mark_Id;

   --  The default size of a secondary stack in the embedded profile
   --  (crates/mpfs_rts/gen_runtime.sh).
   Default_Size : constant := 16 * 1024;

   Start_Mark : constant SS.Mark_Id := SS.SS_Mark;
   Mark       : SS.Mark_Id;
   Deadline   : Time;
   Size       : Natural;
   Beside_Ok  : Boolean := True;
   Balanced   : Boolean := True;

begin
   case Bare_Console.Hart_Id is
      when 0      => Test_Report.Start ("secstack_test_e51");
      when others => Test_Report.Start ("secstack_test_u54");
   end case;

   --  The results.
   Test_Report.Check
     (Secstack_Cases.Repeat ('x', 1000) = [1 .. 1000 => 'x'],
      "a String of 1000 characters is returned");
   Test_Report.Check
     (Secstack_Cases.Join ("abc", "defg") = "abcdefg",
      "a String made of two is returned");
   Test_Report.Check
     (Secstack_Cases.Is_Pattern (Secstack_Cases.Pattern (7, 300), 7),
      "a String computed from its length is returned");
   Test_Report.Check
     (Secstack_Cases.Repeat ('x', 0)'Length = 0,
      "an empty String is returned");

   --  Nested results, and the stack after the statement.
   Mark := SS.SS_Mark;
   Test_Report.Check
     (Secstack_Cases.Is_Nested (Secstack_Cases.Nested (20), 20),
      "20 levels of results made of results are right");
   Test_Report.Check
     (SS.SS_Mark = Mark, "the stack is where it was after the statement");
   Test_Report.Check
     (SS.SS_Get_Max >= 8 * 20,
      "the high-water mark covers the deepest point");

   --  The size of the stack of the environment task, and the overflow.
   Mark := SS.SS_Mark;
   begin
      Secstack_Cases.Exhaust;
      Test_Report.Check (False, "the exhausted stack raises Storage_Error");
   exception
      when Storage_Error =>
         Test_Report.Check (True, "the exhausted stack raises Storage_Error");
   end;
   Size := Secstack_Cases.Taken;
   Test_Report.Info ("taken before the overflow", Bare_Console.U64 (Size));
   Test_Report.Check
     (Size <= Default_Size
      and then Size > Default_Size - 2 * Secstack_Cases.Chunk,
      "the stack of the environment task has the default of the profile");
   SS.SS_Release (Mark);
   Test_Report.Check
     (Secstack_Cases.Is_Nested (Secstack_Cases.Nested (20), 20),
      "the stack is usable after the overflow");
   Test_Report.Check
     (SS.SS_Mark = Mark, "the release brought the stack back");

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
     (Secstack_Worker.Overflowed,
      "the exhausted stack of the task raises Storage_Error");
   Test_Report.Info
     ("task: taken before the overflow",
      Bare_Console.U64 (Secstack_Worker.Size));
   Test_Report.Check
     (Secstack_Worker.Size <= Secstack_Worker.Stack_Size
      and then Secstack_Worker.Size
        > Secstack_Worker.Stack_Size - 2 * Secstack_Cases.Chunk,
      "the stack of the task has the size of its aspect");
   Test_Report.Check
     (Secstack_Worker.Reusable,
      "the stack of the task is usable after the overflow");
   Test_Report.Check
     (SS.SS_Mark = Start_Mark, "the environment task's stack is balanced");

   Test_Report.Finish;
end Secstack_Test;
