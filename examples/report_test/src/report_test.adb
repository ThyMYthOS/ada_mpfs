--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The first test application of the Test_Report protocol. It checks what the
--  hart class of the image promises: the hart id (E51 = 0, U54 = 1 .. 4) and
--  the floating-point extensions in misa, which the E51 does not have and the
--  U54 does (the reason for the two ABIs, see examples/bare_hello). It
--  reports the name report_test_e51 or report_test_u54: a row of tests.list.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;
with System.Machine_Code;
with Test_Report;

procedure Report_Test is
   function Misa return U64;

   function Misa return U64 is
      Value : U64;
   begin
      System.Machine_Code.Asm
        ("csrr %0, misa",
         Outputs  => U64'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Misa;

   Id      : constant U64 := Hart_Id;
   Ext     : constant U64 := Misa;
   --  Extension bits of misa: bit 0 is A, bit n the n-th letter.
   Has_F   : constant Boolean := (Ext / 2 ** 5) mod 2 = 1;
   Has_D   : constant Boolean := (Ext / 2 ** 3) mod 2 = 1;
   Has_C   : constant Boolean := (Ext / 2 ** 2) mod 2 = 1;
   Is_E51  : constant Boolean := Id = 0;
begin
   Test_Report.Start (if Is_E51 then "report_test_e51" else "report_test_u54");
   Test_Report.Info ("hart", Id);
   Test_Report.Check (Id <= 4, "the hart id is 0 .. 4");
   Test_Report.Check (Has_C, "misa has the compressed extension");
   if Is_E51 then
      Test_Report.Check (not Has_F and not Has_D, "the E51 has no F and no D");
   else
      Test_Report.Check (Has_F and Has_D, "a U54 has F and D");
   end if;
   Test_Report.Finish;
end Report_Test;
