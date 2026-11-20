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
--     pmp pmpaddr0 ones 0x<16 hex digits>
--     pmp pmpaddr width <bits>
--
--  The last two: pmpaddr0 as it reads back after all ones (64 bits) were
--  written to it (pmp_ones), and the number of its highest bit set plus
--  one, the width of pmpaddr the hart implements (WARL).

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;

procedure Pmp_Probe is
   function Mask return U64
     with Import, Convention => C, External_Name => "pmp_mask";

   function Ones return U64
     with Import, Convention => C, External_Name => "pmp_ones";

   M     : constant U64 := Mask;
   O     : constant U64 := Ones;
   Rest  : U64 := M;
   Count : U64 := 0;
   Width : U64 := 0;
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

   Rest := O;
   while Rest /= 0 loop
      Width := Width + 1;
      Rest := Rest / 2;
   end loop;
   Put ("pmp pmpaddr0 ones ");
   Put_Hex (O, 16);
   Put_Line ("");
   Put ("pmp pmpaddr width ");
   Put_Dec (Width);
   Put_Line ("");
end Pmp_Probe;
