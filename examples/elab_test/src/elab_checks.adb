--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Elab_A;
with Elab_B;
with Elab_C;
with Elab_Log; use Elab_Log;
with Test_Report;

package body Elab_Checks is

   procedure Chain is
   begin
      Test_Report.Check
        (Position (Unit_A) /= 0 and then Position (Unit_B) /= 0
         and then Position (Unit_C) /= 0,
         "every unit was elaborated before the main program");
      Test_Report.Check
        (Position (Unit_A) < Position (Unit_B)
         and then Position (Unit_B) < Position (Unit_C),
         "the units are elaborated in the order of their dependences");
      Test_Report.Check
        (Elab_A.Value = 42, "a constant computed by a call (elaboration)");
      Test_Report.Check
        (Elab_B.Sum = 43, "a unit that uses its predecessor's constant");
      Test_Report.Check
        (Elab_C.Product = 86, "and the next one the value of the one before");
      Test_Report.Check
        (Elab_A.Noted_At < Elab_B.Noted_At
         and then Elab_B.Noted_At < Elab_C.Noted_At,
         "the statements of the bodies ran in that order too");
   end Chain;

end Elab_Checks;
