--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The callee-saved floating-point registers fs0 .. fs11 (f8, f9, f18 ..
--  f27) as bit patterns: Load puts a different value into each, Mismatch
--  tells which of them lost it. fmv.d.x and fmv.x.d move the bits unchanged
--  (no canonical NaN), so the patterns are arbitrary 64-bit values.
--
--  This is deliberately not ABI-clean: Load changes registers that the ABI
--  makes the caller's (the compiler is not told, or it would save and
--  restore them around Load and undo it). The program is written so that
--  this is harmless: nothing in it computes with a Float or a Long_Float,
--  so no code of the program keeps a value in fs0 .. fs11 (the host suite
--  tests/host/rts_context checks that against the disassembly of the image).

with Interfaces;

package Fp_Regs is

   Step : constant Interfaces.Unsigned_64 := 16#0101_0101_0101_0101#;

   procedure Load (Seed : Interfaces.Unsigned_64);
   --  fs<i> := Seed + i * Step, for i in 0 .. 11

   function Mismatch (Seed : Interfaces.Unsigned_64)
     return Interfaces.Unsigned_32;
   --  Bit i is set if fs<i> is not Seed + i * Step; 0 if all twelve hold
   --  their value

end Fp_Regs;
