--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Exceptions; use Ada.Exceptions;

with Failing;
with Test_Report;

package body Last_Chance is

   procedure Handler (Except : Exception_Occurrence) is
   begin
      Calls := Calls + 1;
      Test_Report.Check (Calls = 1, "the last chance handler is called once");
      Test_Report.Check
        (Exception_Identity (Except) = Failing.Boom'Identity,
         "the handler gets the exception that nobody handled");
      Test_Report.Check
        (Exception_Message (Except) = Failing.Message,
         "the handler gets its message");
      Test_Report.Finish;
   end Handler;

end Last_Chance;
