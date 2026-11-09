--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  console_none_test: with the console "none" (__mpfs_console_base = 0) Put of
--  System.Text_IO has no effect.
--
--    - Initialize does not touch a register, not even those of MMUART0 (the
--      test leaves a value in its DFR and finds it again), although
--      __mpfs_console_init is 1;
--    - Is_Tx_Ready is true, Is_Rx_Ready is false and Get returns NUL;
--    - Put of a text that looks like a failure of this test writes nothing:
--      the report goes out on MMUART0 (Bare_Console), and tests/qemu/
--      run_tests.sh fails the test if a "  FAIL:" line shows up there. A
--      driver that fell back to MMUART0 would print it.
--
--  Reported as console_none_test_e51 or console_none_test_u54.
--
--  @verifies RTS-014

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  The test is about System.Text_IO, a unit of the runtime

with System.Text_IO;

with MPFS_Registers;
with MPFS_Registers.MMUART;

with Bare_Console;
with Test_Report;

procedure Console_None_Test is

   use type Bare_Console.U64;
   use type MPFS_Registers.UInt6;

   Port : MPFS_Registers.MMUART.MMUART_Peripheral
     renames MPFS_Registers.MMUART.MMUART0_LO_Periph;

   Sentinel : constant MPFS_Registers.UInt6 := 42;

   Stray : constant String :=
     "  FAIL: System.Text_IO.Put wrote to a console that is none" &
     Character'Val (13) & Character'Val (10);
begin
   Port.DFR := (DFR => Sentinel, others => <>);

   if Bare_Console.Hart_Id = 0 then
      Test_Report.Start ("console_none_test_e51");
   else
      Test_Report.Start ("console_none_test_u54");
   end if;

   System.Text_IO.Initialize;
   Test_Report.Check
     (System.Text_IO.Initialized,
      "Initialize marks the service as initialized");
   Test_Report.Check
     (Port.DFR.DFR = Sentinel,
      "Initialize wrote no register of MMUART0");

   Test_Report.Check
     (System.Text_IO.Is_Tx_Ready,
      "Is_Tx_Ready is always true");
   Test_Report.Check
     (not System.Text_IO.Is_Rx_Ready,
      "Is_Rx_Ready is always false");
   Test_Report.Check
     (System.Text_IO.Get = ASCII.NUL,
      "Get returns NUL");

   for C of Stray loop
      System.Text_IO.Put (C);
   end loop;
   Test_Report.Check
     (Port.DFR.DFR = Sentinel,
      "Put wrote no register of MMUART0 either");

   Test_Report.Finish;
end Console_None_Test;
