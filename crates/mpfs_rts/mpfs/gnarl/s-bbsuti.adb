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
--  (0x4000 + 8 * mhartid), through System.BB.RISCV_CLINT and the PAC.
--
--  Tickless (master plan #41, work package P1.6): there is no periodic tick.
--  The generic code (System.BB.Time) calls Set_Alarm with the next alarm of
--  the hart (the earliest of the delayed tasks and the timing events, or
--  Time'Last if there is none) and Clear_Alarm_Interrupt in its alarm handler.
--
--    - mtimecmp is the only state. The machine timer interrupt (mip.MTIP) is
--      the level mtime >= mtimecmp, an unsigned 64-bit comparison, so writing
--      mtimecmp is also the acknowledge: it takes the level away. Clear_Alarm_
--      Interrupt writes the maximum, 2**64 - 1, which mtime reaches after
--      584 000 years at 1 MHz: "no alarm". Time'Last is the same value, so
--      "no alarm" needs no special case and there is no wrap-around to handle.
--    - An alarm in the past (or now) is not an error: mtime >= mtimecmp holds
--      at once and the interrupt is taken as soon as mstatus.MIE allows it. It
--      is also what a delay until that expires between the clock read and the
--      store needs (the kernel runs with MIE clear there).
--    - No spurious interrupt: mtimecmp is not reset by the hardware (QEMU: 0,
--      the SoC: unspecified), and mie.MTIE is set by Install_Alarm_Handler,
--      so the register is disarmed first. After that it holds either the
--      maximum or the value that Set_Alarm wrote.
--    - Every access to the 64-bit registers is one load or store (RV64): a
--      clock read cannot tear and an mtimecmp write has no intermediate value
--      that could raise or hide an interrupt (the RV32 code needs the
--      three-word sequence for this).
--    - Clock is monotonic because mtime is: one counter, read at the same
--      rate by every reader, never written by the runtime.
with Interfaces; use Interfaces;

with System.BB.Board_Parameters;
with System.BB.CPU_Specific;
with System.BB.Hart;
with System.BB.RISCV_CLINT;

separate (System.BB.Board_Support)

package body Time is

   package BBBOPA renames System.BB.Board_Parameters;
   package CLINT renames System.BB.RISCV_CLINT;

   pragma Compile_Time_Error
     (BBBOPA.Clock_Scale /= 1,
      "Time is mtime ticks: with a Clock_Scale other than 1 Read_Clock could "
      & "wrap and Set_Alarm would lose the low bits");

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
      --  Disarm first: Install_Trap_Handler sets mie.MTIE, and a stale
      --  mtimecmp (0 after reset in QEMU) would raise a timer interrupt as
      --  soon as mstatus.MIE is set
      Clear_Alarm_Interrupt;

      CPU_Specific.Install_Trap_Handler
        (Handler, CPU_Specific.Timer_Trap);
   end Install_Alarm_Handler;

   ---------------
   -- Set_Alarm --
   ---------------

   procedure Set_Alarm (Ticks : BB.Time.Time) is
   begin
      --  mtimecmp of the executing hart; one 64-bit store, so no intermediate
      --  value can raise a spurious timer interrupt. Ticks in the past or
      --  equal to the clock: the interrupt is pending at once. Time'Last: no
      --  alarm.
      CLINT.Set_Mtimecmp
        (Hart.Id, CLINT.Counter (Unsigned_64 (Ticks) / BBBOPA.Clock_Scale));
   end Set_Alarm;

   ---------------------------
   -- Clear_Alarm_Interrupt --
   ---------------------------

   procedure Clear_Alarm_Interrupt is
   begin
      --  Acknowledge: mtimecmp above any reachable mtime takes mip.MTIP away
      CLINT.Set_Mtimecmp (Hart.Id, CLINT.Counter'Last);
   end Clear_Alarm_Interrupt;

end Time;
