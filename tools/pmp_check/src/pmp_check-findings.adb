--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The findings of the checker.

package body Pmp_Check.Findings
  with SPARK_Mode
is
   procedure Add (L : in out List; C : Rule_Code; Prod : Boolean; Path : String; Message : Texts.Text) is
   begin
      if L.Count = Max_Findings then
         if L.Dropped < Natural'Last then
            L.Dropped := L.Dropped + 1;
         end if;
         if Severity_Of (C, Prod) = Error and then L.Dropped_Errors < Natural'Last then
            L.Dropped_Errors := L.Dropped_Errors + 1;
         end if;
         return;
      end if;
      L.Count := L.Count + 1;
      L.Items (L.Count).C := C;
      L.Items (L.Count).Sev := Severity_Of (C, Prod);
      Texts.Clear (L.Items (L.Count).Path);
      Texts.Append (L.Items (L.Count).Path, Path);
      Texts.Clear (L.Items (L.Count).Message);
      Texts.Append (L.Items (L.Count).Message, Texts.Image (Message));
   end Add;

   function Errors (L : List) return Natural is
      N : Natural := 0;
   begin
      if L.Dropped_Errors > 0 then
         return L.Dropped_Errors;    --  at least that many; enough to refuse
      end if;
      for I in 1 .. L.Count loop
         if L.Items (I).Sev = Error then
            N := N + 1;
         end if;
         pragma Loop_Invariant (N <= I);
      end loop;
      return N;
   end Errors;

end Pmp_Check.Findings;
