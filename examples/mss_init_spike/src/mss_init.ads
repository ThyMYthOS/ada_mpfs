--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The interpreter of the table MPFS_Init_Table: runs the register sequence
--  of the MSS set-up, one phase at a time. The order and the values are the
--  table's (generated from hw/mss_init.py); this unit only knows what a
--  Write, a Modify, a Poll, a Wait and a Skip_If_Clear do.
--
--  Time is counted in cycles of the hart (mcycle): MTIME does not count
--  before the reference clock is set up, and the CPU stays on its boot clock
--  because the table has no clock switch, so Cycles_Per_Microsecond holds.

with Interfaces;

with MPFS_Init_Table;

package Mss_Init is

   --  What a poll that runs out of its budget does: Stop ends the sequence
   --  (the image for the board), Continue records it and goes on (the image
   --  for QEMU, where the registers of the PLLs and the PHY are plain memory
   --  that reads 0 and no poll can succeed).
   type Timeout_Policy is (Stop, Continue);

   --  The CPU clock of the Icicle Kit after a reset (measured, hw/README.md).
   Cycles_Per_Microsecond : constant := 80;

   Max_Timeouts : constant := 16;

   type Timeout is record
      Step  : Natural := 0;                    --  the entry of the table
      Value : MPFS_Init_Table.Word := 0;       --  the word the last read gave
   end record;

   type Timeout_List is array (1 .. Max_Timeouts) of Timeout;

   type Run_Result is record
      Executed : Natural := 0;       --  entries run (a skipped one is not)
      Timeouts : Natural := 0;       --  polls that ran out of their budget
      Stopped  : Boolean := False;   --  a timeout under Stop
      Seen     : Timeout_List;       --  the first Max_Timeouts of them
   end record;

   --  Runs the entries of phase Index (1 .. MPFS_Init_Table.Phase_Count).
   --  A Run_Result that is Stopped is left as it is.
   procedure Run_Phase
     (Index  : Positive;
      Policy : Timeout_Policy;
      Result : in out Run_Result)
     with Pre => Index <= MPFS_Init_Table.Phase_Count;

   function Read (Address : MPFS_Init_Table.Word) return MPFS_Init_Table.Word;

   --  A 64-bit register (CLINT.MTIME), read in one access.
   function Read_64 (Address : MPFS_Init_Table.Word)
     return Interfaces.Unsigned_64;

   --  Cycles of the hart (mcycle).
   function Cycles return Interfaces.Unsigned_64;

   --  Busy wait of at least Microseconds, by Cycles.
   procedure Wait (Microseconds : MPFS_Init_Table.Word);

end Mss_Init;
