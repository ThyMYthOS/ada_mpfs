--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  unhandled_task_test: an exception that a task does not handle ends in the
--  last chance handler (Last_Chance), like one of the environment task, and
--  does not disappear silently. The environment task waits for it; if the
--  handler is not called within a second, the test fails.
--
--  Reported with Test_Report as unhandled_task_test_e51 or
--  unhandled_task_test_u54.

with Ada.Real_Time; use Ada.Real_Time;

with Bare_Console;
with Failing_Task;
pragma Unreferenced (Failing_Task);
with Last_Chance;
with Test_Report;

procedure Unhandled_Task_Test is
begin
   case Bare_Console.Hart_Id is
      when 0      => Test_Report.Start ("unhandled_task_test_e51");
      when others => Test_Report.Start ("unhandled_task_test_u54");
   end case;

   for I in 1 .. 100 loop
      delay until Clock + Milliseconds (10);
   end loop;

   --  Not reached if the exception of the task ends in the handler.
   Test_Report.Check (False, "the last chance handler was not called");
   Test_Report.Info ("handler calls", Bare_Console.U64 (Last_Chance.Calls));
   Test_Report.Finish;
end Unhandled_Task_Test;
