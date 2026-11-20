--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with GNAT.IO;

package body Console is

   use type Interfaces.Unsigned_64;

   Digit : constant String := "0123456789abcdef";

   procedure Put (Text : String) is
   begin
      GNAT.IO.Put (Text);
   end Put;

   procedure Put_Line (Text : String) is
   begin
      GNAT.IO.Put_Line (Text);
   end Put_Line;

   procedure Put_Hex (Value : Interfaces.Unsigned_64; Width : Positive) is
      Rest : Interfaces.Unsigned_64 := Value;
      Text : String (1 .. 16);
   begin
      for I in reverse Text'Range loop
         Text (I) := Digit (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
      end loop;
      Put ("0x");
      Put (Text (17 - Width .. 16));
   end Put_Hex;

   procedure Put_Dec (Value : Interfaces.Unsigned_64) is
      Rest : Interfaces.Unsigned_64 := Value;
      Pow  : Interfaces.Unsigned_64 := 1;
      Pos  : Positive;
   begin
      while Rest / Pow >= 10 loop
         Pow := Pow * 10;
      end loop;
      while Pow > 0 loop
         Pos := Natural (Rest / Pow) + 1;
         Put (Digit (Pos .. Pos));
         Rest := Rest mod Pow;
         Pow := Pow / 10;
      end loop;
   end Put_Dec;

end Console;
