--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package body Elab_Log is

   type Positions is array (Unit_Id) of Natural;

   Noted : Natural := 0 with Volatile;
   Place : Positions := [others => 0] with Volatile;

   procedure Note (Id : Unit_Id) is
   begin
      Noted := Noted + 1;
      Place (Id) := Noted;
   end Note;

   function Count return Natural is (Noted);

   function Position (Id : Unit_Id) return Natural is (Place (Id));

end Elab_Log;
