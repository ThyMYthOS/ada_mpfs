--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with System.Machine_Code; use System.Machine_Code;

package body Fp_Regs is

   use type Interfaces.Unsigned_64;

   Regs_Up : constant String :=
     ".irp r, fs0, fs1, fs2, fs3, fs4, fs5, fs6, fs7, fs8, fs9, fs10, fs11";
   Regs_Down : constant String :=
     ".irp r, fs11, fs10, fs9, fs8, fs7, fs6, fs5, fs4, fs3, fs2, fs1, fs0";

   ----------
   -- Load --
   ----------

   procedure Load (Seed : Interfaces.Unsigned_64) is
      Value : Interfaces.Unsigned_64;
   begin
      --  No clobber list for fs0 .. fs11: see the specification.
      Asm
        ("mv %0, %1" & ASCII.LF
         & Regs_Up & ASCII.LF
         & "fmv.d.x \r, %0" & ASCII.LF
         & "add %0, %0, %2" & ASCII.LF
         & ".endr",
         Outputs  => Interfaces.Unsigned_64'Asm_Output ("=&r", Value),
         Inputs   =>
           [Interfaces.Unsigned_64'Asm_Input ("r", Seed),
            Interfaces.Unsigned_64'Asm_Input ("r", Step)],
         Volatile => True);
   end Load;

   --------------
   -- Mismatch --
   --------------

   function Mismatch (Seed : Interfaces.Unsigned_64)
     return Interfaces.Unsigned_32
   is
      Mask     : Interfaces.Unsigned_64;
      Expected : Interfaces.Unsigned_64;
      Got      : Interfaces.Unsigned_64;
      Last     : constant Interfaces.Unsigned_64 := Seed + 11 * Step;
   begin
      --  fs11 first: each step shifts the mask up and puts the verdict of
      --  one register at bit 0, so that fs0 ends at bit 0 and fs11 at bit 11.
      Asm
        ("li %0, 0" & ASCII.LF
         & "mv %1, %3" & ASCII.LF
         & Regs_Down & ASCII.LF
         & "fmv.x.d %2, \r" & ASCII.LF
         & "xor %2, %2, %1" & ASCII.LF
         & "snez %2, %2" & ASCII.LF
         & "slli %0, %0, 1" & ASCII.LF
         & "or %0, %0, %2" & ASCII.LF
         & "sub %1, %1, %4" & ASCII.LF
         & ".endr",
         Outputs  =>
           [Interfaces.Unsigned_64'Asm_Output ("=&r", Mask),
            Interfaces.Unsigned_64'Asm_Output ("=&r", Expected),
            Interfaces.Unsigned_64'Asm_Output ("=&r", Got)],
         Inputs   =>
           [Interfaces.Unsigned_64'Asm_Input ("r", Last),
            Interfaces.Unsigned_64'Asm_Input ("r", Step)],
         Volatile => True);
      return Interfaces.Unsigned_32 (Mask);
   end Mismatch;

end Fp_Regs;
