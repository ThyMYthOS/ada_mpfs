--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package body Sample_Math
  with SPARK_Mode
is

   use type Interfaces.Unsigned_32;

   function Join_LE (B0, B1, B2, B3 : Byte) return Word is
     (Word (B0) + Word (B1) * 256 + Word (B2) * 65_536
      + Word (B3) * 16_777_216);

   function Byte_Of (W : Word; Position : Natural) return Byte is
   begin
      return Byte (Interfaces.Shift_Right (W, 8 * Position) mod 256);
   end Byte_Of;

   function Saturating_Add (A, B : Word) return Word is
   begin
      if Word'Last - A < B then
         return Word'Last;
      else
         return A + B;
      end if;
   end Saturating_Add;

end Sample_Math;
