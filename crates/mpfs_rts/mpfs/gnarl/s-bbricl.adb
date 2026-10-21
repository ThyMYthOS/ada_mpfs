--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1

with Interfaces;

with MPFS_Registers;
with MPFS_Registers.CLINT;

package body System.BB.RISCV_CLINT is

   package Regs renames MPFS_Registers.CLINT;

   --  The PAC has the msip and mtimecmp registers of the five harts as
   --  arrays (4 * hart and 0x4000 + 8 * hart); the layout is the SVD's.

   pragma Compile_Time_Error
     (Regs.MTIMECMP_Registers'Length /= Max_Hart + 1
      or else Regs.MSIP_Registers'Length /= Max_Hart + 1,
      "the CLINT of the PAC does not have five harts");

   -----------
   -- Mtime --
   -----------

   function Mtime return Counter is
   begin
      return Counter (Regs.CLINT_Periph.MTIME);
   end Mtime;

   --------------
   -- Mtimecmp --
   --------------

   function Mtimecmp (Hart : Hart_Id) return Counter is
   begin
      return Counter (Regs.CLINT_Periph.MTIMECMP (Hart));
   end Mtimecmp;

   ------------------
   -- Set_Mtimecmp --
   ------------------

   procedure Set_Mtimecmp (Hart : Hart_Id; Value : Counter) is
   begin
      Regs.CLINT_Periph.MTIMECMP (Hart) :=
        MPFS_Registers.UInt64 (Interfaces.Unsigned_64 (Value));
   end Set_Mtimecmp;

   ----------
   -- MSIP --
   ----------

   function MSIP (Hart : Hart_Id) return Boolean is
   begin
      return Regs.CLINT_Periph.MSIP (Hart).MSIP;
   end MSIP;

   ----------------
   -- Clear_MSIP --
   ----------------

   procedure Clear_MSIP (Hart : Hart_Id) is
      Value : Regs.MSIP_Register := Regs.CLINT_Periph.MSIP (Hart);
   begin
      Value.MSIP := False;
      Regs.CLINT_Periph.MSIP (Hart) := Value;
   end Clear_MSIP;

end System.BB.RISCV_CLINT;
