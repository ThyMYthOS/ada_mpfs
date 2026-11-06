--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

with Ada.Unchecked_Conversion;
with Bare_Console;
with Interfaces;
with Test_Report;

package body Reject is

   use type Bare_Console.U64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  The layout of the rejection record (start.S): Magic and Hart are the
   --  two halves of one 64-bit store.
   type Reject_Record is record
      Kind   : Interfaces.Unsigned_64;
      Addr   : Interfaces.Unsigned_64;
      Cause  : Interfaces.Unsigned_64;
      Magic  : Interfaces.Unsigned_32;
      Hart   : Interfaces.Unsigned_32;
   end record
     with Size => 256;
   for Reject_Record use record
      Kind  at  0 range 0 .. 63;
      Addr  at  8 range 0 .. 63;
      Cause at 16 range 0 .. 63;
      Magic at 24 range 0 .. 31;
      Hart  at 28 range 0 .. 31;
   end record;

   Itim_Magic    : constant := 16#4D49_5449#;
   Kind_Code     : constant := 1;
   Store_Fault   : constant := 7;
   No_Trap       : constant := 16#FFFF_FFFF_FFFF_FFFF#;
   Itim_Base     : constant := 16#0180_0000#;
   Itim_Length   : constant := 16#2000#;

   type Record_Ptr is access constant Reject_Record;
   function To_Ptr is new Ada.Unchecked_Conversion
     (System.Address, Record_Ptr);

   ----------
   -- Hook --
   ----------

   procedure Hook (Record_Address : System.Address) is
      Rec : Reject_Record renames To_Ptr (Record_Address).all;
   begin
      Test_Report.Start ("itim_reject_test_e51");
      Test_Report.Check
        (Rec.Magic = Itim_Magic, "start.S rejected the image (magic ITIM)");
      Test_Report.Check
        (Bare_Console.U64 (Rec.Hart) = Bare_Console.Hart_Id,
         "the record names this hart");
      Test_Report.Check
        (Rec.Kind = Kind_Code, "the rejected range is the code (.fast_text)");
      Test_Report.Check
        (Rec.Cause = Store_Fault or else Rec.Cause = No_Trap,
         "a store access fault, or the word read back wrongly");
      Test_Report.Check
        (Rec.Addr >= Itim_Base and then Rec.Addr < Itim_Base + Itim_Length,
         "the address that failed is in the ITIM of the E51");
      Test_Report.Info ("kind", Bare_Console.U64 (Rec.Kind));
      Test_Report.Info ("address", Bare_Console.U64 (Rec.Addr));
      Test_Report.Info ("mcause", Bare_Console.U64 (Rec.Cause));
      Test_Report.Finish;
   end Hook;

end Reject;
