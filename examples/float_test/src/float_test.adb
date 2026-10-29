--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  float_test: floating point on both hart classes of the runtime
--  crates/mpfs_rts. The E51 has no FPU (-march=rv64imac -mabi=lp64: every
--  operation is a call into libgcc, the square root is the software one of
--  the runtime), the U54 has one (-march=rv64imafdc -mabi=lp64d, fsqrt.d).
--  Both must give the answers of IEEE 754:
--
--    - arithmetic and its rounding, compared bit for bit (the expected bit
--      patterns are the correctly rounded results, computed outside this
--      program);
--    - the rounding attributes and the conversions to integer;
--    - Sqrt: exact on the U54 (fsqrt.d and fsqrt.s round correctly), within
--      2 ulp of the exact value on the E51 (software square root, see
--      Software_Ulps: it measures 1 ulp low for 2.0);
--    - the 'Image of Float and Long_Float against the text of a reference
--      run (the host compiler, 15.3.1).
--
--  The operands are volatile, so that nothing is folded by the compiler.
--  Reported with Test_Report as float_test_e51 and float_test_u54.

with Ada.Numerics.Elementary_Functions;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Unchecked_Conversion;
with Bare_Console;
with Interfaces;
with Test_Report;

procedure Float_Test is

   use type Bare_Console.U64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   function Bits is new Ada.Unchecked_Conversion
     (Long_Float, Interfaces.Unsigned_64);
   function Bits is new Ada.Unchecked_Conversion
     (Float, Interfaces.Unsigned_32);

   Software_Ulps : constant := 2;
   --  Tolerance of Sqrt on the E51 (a hart without FPU)

   Is_E51 : constant Boolean := Bare_Console.Hart_Id = 0;

   --  Operands that the compiler cannot see through (nothing assigns them)
   pragma Warnings (Off, "is not modified");
   D_1_5  : Long_Float := 1.5 with Volatile;
   D_2_25 : Long_Float := 2.25 with Volatile;
   D_10   : Long_Float := 10.0 with Volatile;
   D_4    : Long_Float := 4.0 with Volatile;
   D_0_1  : Long_Float := 0.1 with Volatile;
   D_0_2  : Long_Float := 0.2 with Volatile;
   D_1    : Long_Float := 1.0 with Volatile;
   D_3    : Long_Float := 3.0 with Volatile;
   D_2_53 : Long_Float := 9007199254740992.0 with Volatile;
   D_2    : Long_Float := 2.0 with Volatile;
   D_16   : Long_Float := 16.0 with Volatile;
   D_025  : Long_Float := 0.25 with Volatile;
   D_M2_7 : Long_Float := -2.7 with Volatile;
   D_2_5  : Long_Float := 2.5 with Volatile;
   D_M2_5 : Long_Float := -2.5 with Volatile;
   D_Big  : Long_Float := 123456789012.0 with Volatile;
   D_M0_1 : Long_Float := -0.1 with Volatile;
   D_2_60 : Long_Float := 1152921504606846976.0 with Volatile;
   D_Rt_2 : Long_Float := 1.4142135623730951 with Volatile;
   I_M7   : Integer := -7 with Volatile;

   F_1_5  : Float := 1.5 with Volatile;
   F_2_25 : Float := 2.25 with Volatile;
   F_2_24 : Float := 16777216.0 with Volatile;
   F_1    : Float := 1.0 with Volatile;
   F_3    : Float := 3.0 with Volatile;
   F_2    : Float := 2.0 with Volatile;
   F_0_1  : Float := 0.1 with Volatile;
   F_375  : Float := 3.75 with Volatile;
   F_1E10 : Float := 1.0E10 with Volatile;

   pragma Warnings (On, "is not modified");

   D, D2 : Long_Float;
   F     : Float;

   function Within
     (Got, Want : Interfaces.Unsigned_64; Ulps : Interfaces.Unsigned_64)
      return Boolean
   is (if Got >= Want then Got - Want <= Ulps else Want - Got <= Ulps);
   --  Positive values: the distance of the bit patterns is the distance in ulp

   function Within
     (Got, Want : Interfaces.Unsigned_32; Ulps : Interfaces.Unsigned_32)
      return Boolean
   is (if Got >= Want then Got - Want <= Ulps else Want - Got <= Ulps);

   Tolerance : constant Interfaces.Unsigned_64 :=
     (if Is_E51 then Software_Ulps else 0);

begin
   if Is_E51 then
      Test_Report.Start ("float_test_e51");
   else
      Test_Report.Start ("float_test_u54");
   end if;
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   --  Arithmetic, Long_Float
   D := D_1_5 + D_2_25;
   Test_Report.Check (Bits (D) = 16#400E_0000_0000_0000#, "1.5 + 2.25 = 3.75");
   D := D_10 / D_4;
   Test_Report.Check (Bits (D) = 16#4004_0000_0000_0000#, "10.0 / 4.0 = 2.5");
   D := D_0_1 + D_0_2;
   Test_Report.Check
     (Bits (D) = 16#3FD3_3333_3333_3334#,
      "0.1 + 0.2 is the double 0.30000000000000004");
   D := D_1 / D_3;
   Test_Report.Check
     (Bits (D) = 16#3FD5_5555_5555_5555#, "1.0 / 3.0 rounds to nearest");
   D := D_2_53 + D_1;
   Test_Report.Check
     (Bits (D) = 16#4340_0000_0000_0000#,
      "2**53 + 1 rounds to even (2**53)");
   D := D_1_5 * D_M0_1 * D_10;
   Test_Report.Check
     (Bits (D) = 16#BFF8_0000_0000_0001#,
      "1.5 * (-0.1) * 10.0 = -1.5000000000000002");

   --  Arithmetic, Float
   F := F_1_5 + F_2_25;
   Test_Report.Check
     (Bits (F) = 16#4070_0000#, "1.5 + 2.25 = 3.75 (Float)");
   F := F_2_24 + F_1;
   Test_Report.Check
     (Bits (F) = 16#4B80_0000#, "2**24 + 1 rounds to even (Float)");
   F := F_1 / F_3;
   Test_Report.Check
     (Bits (F) = 16#3EAA_AAAB#, "1.0 / 3.0 rounds to nearest (Float)");
   D := Long_Float (F_0_1);
   Test_Report.Check
     (Bits (D) = 16#3FB9_9999_A000_0000#, "Long_Float (0.1 as Float)");
   F := Float (D_0_1);
   Test_Report.Check
     (Bits (F) = 16#3DCC_CCCD#, "Float (0.1 as Long_Float)");

   --  Conversions and the rounding attributes
   Test_Report.Check
     (Integer (D_2_5) = 3 and Integer (D_M2_5) = -3,
      "Integer (2.5) = 3 and Integer (-2.5) = -3 (away from zero)");
   Test_Report.Check
     (Bits (Long_Float'Truncation (D_M2_7)) = Bits (-2.0)
      and Bits (Long_Float'Floor (D_M2_7)) = Bits (-3.0)
      and Bits (Long_Float'Ceiling (D_M2_7)) = Bits (-2.0)
      and Bits (Long_Float'Rounding (D_M2_7)) = Bits (-3.0),
      "Truncation, Floor, Ceiling and Rounding of -2.7");
   Test_Report.Check
     (Long_Long_Integer (D_Big) = 123_456_789_012
      and Bits (Long_Float (I_M7)) = Bits (-7.0),
      "conversions between integer and floating point");

   --  Square root
   D := Ada.Numerics.Long_Elementary_Functions.Sqrt (D_16);
   Test_Report.Check (Bits (D) = Bits (4.0), "Sqrt (16.0) = 4.0");
   D := Ada.Numerics.Long_Elementary_Functions.Sqrt (D_025);
   Test_Report.Check (Bits (D) = Bits (0.5), "Sqrt (0.25) = 0.5");
   D2 := Ada.Numerics.Long_Elementary_Functions.Sqrt (D_2);
   Test_Report.Info ("Sqrt (2.0), bits", Bare_Console.U64 (Bits (D2)));
   Test_Report.Check
     (Within (Bits (D2), 16#3FF6_A09E_667F_3BCD#, Tolerance),
      (if Is_E51
       then "Sqrt (2.0) within 2 ulp (software square root)"
       else "Sqrt (2.0) is exact (fsqrt.d)"));
   F := Ada.Numerics.Elementary_Functions.Sqrt (F_2);
   Test_Report.Info ("Sqrt (2.0) Float, bits", Bare_Console.U64 (Bits (F)));
   Test_Report.Check
     (Within (Bits (F), 16#3FB5_04F3#, Interfaces.Unsigned_32 (Tolerance)),
      (if Is_E51
       then "Sqrt (2.0) Float within 2 ulp (software square root)"
       else "Sqrt (2.0) Float is exact (fsqrt.s)"));

   --  'Image against the reference run
   Test_Report.Check
     (Long_Float'Image (D_1_5) = " 1.50000000000000E+00",
      "Long_Float'Image (1.5)");
   Test_Report.Check
     (Long_Float'Image (D_M0_1) = "-1.00000000000000E-01",
      "Long_Float'Image (-0.1)");
   Test_Report.Check
     (Long_Float'Image (D_2_60) = " 1.15292150460685E+18",
      "Long_Float'Image (2.0**60)");
   Test_Report.Check
     (Long_Float'Image (D_Rt_2) = " 1.41421356237310E+00",
      "Long_Float'Image (1.4142135623730951)");
   Test_Report.Check
     (Float'Image (F_375) = " 3.75000E+00", "Float'Image (3.75)");
   Test_Report.Check
     (Float'Image (F_1E10) = " 1.00000E+10", "Float'Image (1.0E10)");
   Test_Report.Check
     (Float'Image (F_0_1) = " 1.00000E-01", "Float'Image (0.1)");
   Test_Report.Check
     (Float'Image (F) = " 1.41421E+00", "Float'Image (Sqrt (2.0))");

   Test_Report.Finish;
end Float_Test;
