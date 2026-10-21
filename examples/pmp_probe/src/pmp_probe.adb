--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Counts the PMP entries of the hart that runs it: pmp_mask (pmp_mask.S)
--  writes and reads back pmpaddr0 .. pmpaddr15 (a WARL register reads zero
--  where the entry does not exist). Prints
--
--     pmp probe hart <n>
--     pmp entries <count>
--     pmp mask 0x<4 hex digits>

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;

procedure Pmp_Probe is
   function Mask return U64
     with Import, Convention => C, External_Name => "pmp_mask";

   M     : constant U64 := Mask;
   Rest  : U64 := M;
   Count : U64 := 0;
begin
   for I in 0 .. 15 loop
      if Rest mod 2 = 1 then
         Count := Count + 1;
      end if;
      Rest := Rest / 2;
   end loop;

   Put ("pmp probe hart ");
   Put_Dec (Hart_Id);
   Put_Line ("");
   Put ("pmp entries ");
   Put_Dec (Count);
   Put_Line ("");
   Put ("pmp mask ");
   Put_Hex (M, 4);
   Put_Line ("");
end Pmp_Probe;
