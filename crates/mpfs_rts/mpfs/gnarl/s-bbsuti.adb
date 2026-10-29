--  SPDX-FileCopyrightText: 1999-2002 Universidad Politecnica de Madrid
--  SPDX-FileCopyrightText: 2003-2005 The European Space Agency
--  SPDX-FileCopyrightText: 2003-2019 AdaCore
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes src/s-bbsuti__riscv_clint.adb
--  @ 09e7cd6 (GPL-3.0-or-later WITH GCC-exception-3.1); modified for
--  PolarFire SoC.
--
--  The timer of the executing hart: mtime and the mtimecmp of this hart
--  (0x4000 + 8 * mhartid), through System.BB.RISCV_CLINT and the PAC. The
--  alarm is a one-shot: Set_Alarm arms it, Clear_Alarm_Interrupt disarms it.
--  The 64-bit registers are accessed with one 64-bit load or store (RV64).

with Interfaces; use Interfaces;

with System.BB.Board_Parameters;
with System.BB.CPU_Specific;
with System.BB.Hart;
with System.BB.RISCV_CLINT;

separate (System.BB.Board_Support)

package body Time is

   package BBBOPA renames System.BB.Board_Parameters;
   package CLINT renames System.BB.RISCV_CLINT;

   ----------------
   -- Read_Clock --
   ----------------

   function Read_Clock return BB.Time.Time is
      Result : constant Unsigned_64 := Unsigned_64 (CLINT.Mtime);
   begin
      return BB.Time.Time (Result * BBBOPA.Clock_Scale);
   end Read_Clock;

   ---------------------------
   -- Install_Alarm_Handler --
   ---------------------------

   procedure Install_Alarm_Handler
     (Handler : BB.Interrupts.Interrupt_Handler)
   is
   begin
      CPU_Specific.Install_Trap_Handler
        (Handler, CPU_Specific.Timer_Trap);
   end Install_Alarm_Handler;

   ---------------
   -- Set_Alarm --
   ---------------

   procedure Set_Alarm (Ticks : BB.Time.Time) is
   begin
      --  mtimecmp of the executing hart; one 64-bit store, so no intermediate
      --  value can raise a spurious timer interrupt
      CLINT.Set_Mtimecmp
        (Hart.Id, CLINT.Counter (Unsigned_64 (Ticks) / BBBOPA.Clock_Scale));
   end Set_Alarm;

   ---------------------------
   -- Clear_Alarm_Interrupt --
   ---------------------------

   procedure Clear_Alarm_Interrupt is
   begin
      CLINT.Set_Mtimecmp (Hart.Id, CLINT.Counter'Last);
   end Clear_Alarm_Interrupt;

end Time;
