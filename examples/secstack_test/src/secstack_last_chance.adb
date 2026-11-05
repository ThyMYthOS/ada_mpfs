--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with System; use System;

with Bare_Console;
with Secstack_Cases;
with Test_Report;

package body Secstack_Last_Chance is

   procedure Handler (Msg : System.Address; Line : Integer) is
      Size : constant Natural := Secstack_Cases.Taken;
   begin
      Calls := Calls + 1;
      Test_Report.Check (Calls = 1, "the last chance handler is called once");
      Test_Report.Check
        (Msg /= Null_Address and then Line > 0,
         "it gets the place of the raise");
      Test_Report.Info ("taken before the overflow", Bare_Console.U64 (Size));
      Test_Report.Check
        (Size <= Expected_Size
         and then Size > Expected_Size - 2 * Secstack_Cases.Chunk,
         "the exhausted stack has the default of the profile");
      Test_Report.Finish;
   end Handler;

end Secstack_Last_Chance;
