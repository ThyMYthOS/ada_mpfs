--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Byte arithmetic that is proved free of run-time errors, and whose contracts
--  say what it computes.

with Interfaces;

package Sample_Math
  with SPARK_Mode
is
   use type Interfaces.Unsigned_32;

   subtype Byte is Interfaces.Unsigned_8;
   subtype Word is Interfaces.Unsigned_32;

   --  Little-endian join of four bytes: byte i has the weight 256 ** i.
   function Join_LE (B0, B1, B2, B3 : Byte) return Word
     with Post => Join_LE'Result =
       Word (B0) + Word (B1) * 256 + Word (B2) * 65_536
       + Word (B3) * 16_777_216;

   --  The byte of a word at a byte position 0 .. 3.
   function Byte_Of (W : Word; Position : Natural) return Byte
     with Pre  => Position <= 3,
          Post => Word (Byte_Of'Result) =
            (case Position is
                when 0      => W mod 256,
                when 1      => (W / 256) mod 256,
                when 2      => (W / 65_536) mod 256,
                when others => W / 16_777_216);

   --  Addition that stops at the largest word instead of wrapping.
   function Saturating_Add (A, B : Word) return Word
     with Post => (if Word'Last - A < B then Saturating_Add'Result = Word'Last
                   else Saturating_Add'Result = A + B);

end Sample_Math;
