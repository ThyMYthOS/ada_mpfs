--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  console_noinit_test: with __mpfs_console_init = 0 the runtime writes
--  nothing to set the console up; the boot stage has done it, and on the board
--  it has to be there (an Icicle Kit in boot mode 0: ./x hw run with
--  --uart-standin, which clocks, releases and programs the MMUARTs).
--
--  The test leaves a value in DFR before the first output, which is the first
--  Initialize. DFR is inert while the fractional mode is off, and the
--  Initialize of an init = 1 console writes it (from __mpfs_console_dfr, which
--  is not this value). The line control register is compared before and after
--  too. The output is still there: Put and Get only use the data port and the
--  status.
--
--  Reported as console_noinit_test_e51 or console_noinit_test_u54.

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  The tests are about System.Text_IO, a unit of the runtime

with System.Text_IO;

with MPFS_Registers;
with MPFS_Registers.MMUART;

with Console_Checks;
with Test_Report;

procedure Console_Noinit_Test is

   use type MPFS_Registers.UInt6;
   use type MPFS_Registers.MMUART.LCR_Register;

   package MMUART renames MPFS_Registers.MMUART;

   Port : MMUART.MMUART_Peripheral
     with Import, Address => Console_Checks.Link_Base;

   Sentinel : constant MPFS_Registers.UInt6 := 42;

   Line_Before : constant MMUART.LCR_Register := Port.LCR;
begin
   Port.DFR := (DFR => Sentinel, others => <>);

   Console_Checks.Start ("console_noinit_test");

   Test_Report.Check
     (System.Text_IO.Initialized,
      "Initialize marks the service as initialized");
   Test_Report.Check
     (Port.DFR.DFR = Sentinel,
      "Initialize did not write DFR");
   Test_Report.Check
     (Port.LCR = Line_Before,
      "Initialize did not write LCR");
   Test_Report.Finish;
end Console_Noinit_Test;
