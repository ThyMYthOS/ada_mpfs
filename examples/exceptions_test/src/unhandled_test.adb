--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  unhandled_test: an exception that nobody handles propagates through the
--  frames of the environment task, finds no handler (the unwinder reaches the
--  end of the stack: _start has no frame description) and ends in the last
--  chance handler (Last_Chance), which reports the verdict. If the exception
--  is handled after all, or the call returns, the check below fails.
--
--  Reported with Test_Report as unhandled_test_e51 or unhandled_test_u54.

with Bare_Console;
with Failing;
with Last_Chance;
with Test_Report;

procedure Unhandled_Test is
begin
   case Bare_Console.Hart_Id is
      when 0      => Test_Report.Start ("unhandled_test_e51");
      when others => Test_Report.Start ("unhandled_test_u54");
   end case;

   Failing.Run (3);

   --  Not reached.
   Test_Report.Check (False, "Failing.Run returned");
   Test_Report.Info ("handler calls", Bare_Console.U64 (Last_Chance.Calls));
   Test_Report.Finish;
end Unhandled_Test;
