--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  The CLINT of PolarFire SoC, indexed by hart: mtime, mtimecmp (Hart) at
--  0x4000 + 8 * Hart and msip (Hart) at 4 * Hart, through the PAC
--  (MPFS_Registers.CLINT). The timer of the executing hart is
--  Mtimecmp (System.BB.Hart.Id); the runtime never writes the mtimecmp or the
--  msip of another hart by itself (an IPI to another hart is the SMP work
--  package, P8).

pragma Restrictions (No_Elaboration_Code);

package System.BB.RISCV_CLINT is
   pragma Preelaborate;

   Max_Hart : constant := 4;
   --  The harts of the SoC: the E51 is hart 0, the U54 cores are 1 .. 4

   subtype Hart_Id is Natural range 0 .. Max_Hart;

   type Counter is mod 2 ** 64;

   function Mtime return Counter;
   --  The 64-bit time counter, read with one 64-bit access

   function Mtimecmp (Hart : Hart_Id) return Counter;

   procedure Set_Mtimecmp (Hart : Hart_Id; Value : Counter);
   --  One 64-bit store: on RV64 it is atomic, no intermediate value can
   --  raise a timer interrupt

   function MSIP (Hart : Hart_Id) return Boolean;
   --  The software interrupt pending bit of a hart

   procedure Clear_MSIP (Hart : Hart_Id);
   --  Clear the software interrupt of a hart (the hart clears its own)

end System.BB.RISCV_CLINT;
