--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  secstack_light_test: the secondary stack of the light runtime of
--  crates/mpfs_rts (no tasking, no propagation of exceptions). Functions
--  whose result has a size that the caller does not know return it on the
--  secondary stack (the same checks as secstack_test: the results, the
--  balance); the stack has the default of the profile (16 KiB), and exhausting
--  it ends in the last chance handler (Secstack_Last_Chance) with the
--  Storage_Error of the runtime, which reports the size and the verdict.
--
--  Reported with Test_Report as secstack_light_test_e51 or
--  secstack_light_test_u54.
--
--  @verifies RTS-013

with System.Secondary_Stack;

with Bare_Console;
with Secstack_Cases;
with Secstack_Last_Chance;
with Test_Report;

procedure Secstack_Light_Test is

   package SS renames System.Secondary_Stack;
   use type SS.Mark_Id;

   --  The default size of a secondary stack in the light profile
   --  (crates/mpfs_rts/gen_runtime.sh).
   Default_Size : constant := 16 * 1024;

   Mark : SS.Mark_Id;

begin
   case Bare_Console.Hart_Id is
      when 0      => Test_Report.Start ("secstack_light_test_e51");
      when others => Test_Report.Start ("secstack_light_test_u54");
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

   --  The overflow ends in the last chance handler, which finishes the test.
   Secstack_Last_Chance.Expected_Size := Default_Size;
   Secstack_Cases.Exhaust;

   --  Not reached.
   Test_Report.Check (False, "Exhaust returned");
   Test_Report.Finish;
end Secstack_Light_Test;
