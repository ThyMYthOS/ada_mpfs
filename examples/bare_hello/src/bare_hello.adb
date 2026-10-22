--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Prints its own hart id on MMUART0: "bare hello E51 hart 0" or "bare hello
--  U54 hart <n>". start.S has parked every hart that is not in the mask of the
--  image.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;

procedure Bare_Hello is
   Id : constant U64 := Hart_Id;
begin
   if Id = 0 then
      Put ("bare jello E51 hart ");
   else
      Put ("bare jello U54 hart ");
   end if;
   Put_Dec (Id);
   Put_Line ("");
end Bare_Hello;
