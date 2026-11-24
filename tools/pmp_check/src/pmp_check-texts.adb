--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Texts of a bounded length for the messages of the checker.

package body Pmp_Check.Texts
  with SPARK_Mode
is
   use type Interfaces.Unsigned_64;

   Digits_Of : constant String (1 .. 16) := "0123456789abcdef";

   procedure Clear (T : in out Text) is
   begin
      T.Len := 0;
   end Clear;

   procedure Append (T : in out Text; S : String) is
   begin
      for C of S loop
         exit when T.Len >= T.Capacity;
         T.Len := T.Len + 1;
         T.Data (T.Len) := C;
      end loop;
   end Append;

   procedure Append_Hex (T : in out Text; V : U64) is
      Buffer : String (1 .. 16) := [others => '0'];
      First  : Positive range 1 .. 16 := 16;
      Rest   : U64 := V;
   begin
      for I in reverse Buffer'Range loop
         Buffer (I) := Digits_Of (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
         if Buffer (I) /= '0' then
            First := I;
         end if;
      end loop;
      Append (T, "0x");
      Append (T, Buffer (First .. 16));
   end Append_Hex;

   procedure Append_Address (T : in out Text; A : Address) is
   begin
      Append_Hex (T, U64 (A));
   end Append_Address;

   procedure Append_Natural (T : in out Text; N : Natural) is
      Buffer : String (1 .. 10) := [others => '0'];
      First  : Positive range 1 .. 10 := 10;
      Rest   : Natural := N;
   begin
      for I in reverse Buffer'Range loop
         Buffer (I) := Digits_Of (Rest mod 10 + 1);
         Rest := Rest / 10;
         if Buffer (I) /= '0' then
            First := I;
         end if;
      end loop;
      Append (T, Buffer (First .. 10));
   end Append_Natural;

   procedure Append_Range (T : in out Text; First, Last : Address) is
   begin
      Append (T, "[");
      Append_Address (T, First);
      Append (T, ", ");
      Append_Address (T, Last);
      Append (T, "]");
   end Append_Range;

end Pmp_Check.Texts;
