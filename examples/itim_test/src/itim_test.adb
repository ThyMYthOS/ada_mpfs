--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  itim_test: the copy step of start.S for the code and data that an
--  application runs from the local memories. The memory behind the ranges is
--  ordinary RAM here (ld/app-sections.ld: QEMU does not model the ITIM;
--  examples/itim_reject_test has the real ITIM address), so what is checked
--  is the step itself:
--
--    - the function in .fast_text and the table in .fast_data lie inside the
--      ranges that the application's linker script names (__fast_text_start
--      .. __fast_text_end and so on);
--    - those ranges are not where the image holds the bytes
--      (__fast_*_load): a copy was needed;
--    - the code was copied: its bytes at the run address equal those at the
--      load address;
--    - the function returns the right sum (the hart fetches what start.S
--      stored: fence.i), and the table has its initial values and can be
--      changed.
--
--  Reported as itim_test_e51.
--
--  @verifies RTS-017

pragma Suppress (All_Checks);

with Fast;
with Interfaces;
with System;
with System.Storage_Elements;
with Test_Report;

procedure Itim_Test is

   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_8;
   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;

   Text_Start : constant Character
     with Import, Convention => C, External_Name => "__fast_text_start";
   Text_End   : constant Character
     with Import, Convention => C, External_Name => "__fast_text_end";
   Text_Load  : constant Character
     with Import, Convention => C, External_Name => "__fast_text_load";
   Data_Start : constant Character
     with Import, Convention => C, External_Name => "__fast_data_start";
   Data_End   : constant Character
     with Import, Convention => C, External_Name => "__fast_data_end";
   Data_Load  : constant Character
     with Import, Convention => C, External_Name => "__fast_data_load";

   type Byte_Array is array (Natural range <>) of Interfaces.Unsigned_8;

   function Inside (A, First, Last : System.Address) return Boolean is
     (A >= First and then A < Last);

   Sum  : Integer;
   Same : Boolean := True;

   pragma Warnings (Off, "is not modified");
   Hart : Integer := 0 with Volatile;
   pragma Warnings (On, "is not modified");

begin
   Test_Report.Start ("itim_test_e51");

   Test_Report.Check
     (Text_End'Address > Text_Start'Address, "the code range is not empty");
   Test_Report.Check
     (Data_End'Address > Data_Start'Address, "the data range is not empty");
   Test_Report.Check
     (Inside (Fast.Add'Address, Text_Start'Address, Text_End'Address),
      "Add lies in the code range");
   Test_Report.Check
     (Inside (Fast.Table'Address, Data_Start'Address, Data_End'Address),
      "Table lies in the data range");
   Test_Report.Check
     (Text_Load'Address /= Text_Start'Address
      and then Data_Load'Address /= Data_Start'Address,
      "the image holds the bytes elsewhere than they run (a copy was needed)");

   declare
      Len  : constant Natural :=
        Natural (Text_End'Address - Text_Start'Address);
      Run  : Byte_Array (0 .. Len - 1)
        with Import, Address => Text_Start'Address;
      Load : Byte_Array (0 .. Len - 1)
        with Import, Address => Text_Load'Address;
   begin
      for I in Run'Range loop
         if Run (I) /= Load (I) then
            Same := False;
         end if;
      end loop;
      Test_Report.Check
        (Same, "the code at the run address equals the loaded bytes");
   end;

   Sum := Fast.Add (Hart + 40, 2);
   Test_Report.Check (Sum = 42, "Add executes from its range: 40 + 2 = 42");

   Test_Report.Check
     (Fast.Table (1) = 16#0123_4567_89AB_CDEF#
      and then Fast.Table (2) = 16#FEDC_BA98_7654_3210#
      and then Fast.Table (3) = 1
      and then Fast.Table (4) = 2,
      "Table has its initial values");
   Fast.Table (3) := Fast.Table (3) + 40;
   Test_Report.Check (Fast.Table (3) = 41, "Table is writable");

   Test_Report.Finish;
end Itim_Test;
