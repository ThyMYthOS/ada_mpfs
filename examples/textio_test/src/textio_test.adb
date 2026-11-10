--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  textio_test: System.Text_IO, the console of the runtime, on the MMUART
--  of its hart (MMUART0 on the E51, MMUART1 on U54 hart 1) with
--  __mpfs_console_init = 1. Everything of this report goes out through it
--  (the body of Bare_Console in src/), so the lines on the serial port are
--  the first check; the program checks what it can read:
--
--    - the first output initialised the service (Initialized);
--    - the registers of that MMUART are those of the link symbols: 8N1, the
--      divisor, DFR and the fractional mode, the FIFOs (Console_Checks);
--    - GNAT.IO (Put, Put_Line, New_Line) reaches the same port;
--    - the receiving side: with MCR.LOOP every byte put comes back through
--      Is_Rx_Ready and Get (no console.in needed, so the same image runs on
--      the board).
--
--  Reported as textio_test_e51 or textio_test_u54.

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  The tests are about System.Text_IO, a unit of the runtime

with GNAT.IO;

with System.Text_IO;

with Console_Checks;
with Test_Name;
with Test_Report;

procedure Textio_Test is
begin
   Console_Checks.Start (Test_Name.Base);

   Test_Report.Check
     (System.Text_IO.Initialized,
      "the first output initialised the console");
   Console_Checks.Programmed (Console_Checks.Hart_Base);

   GNAT.IO.Put ("  ok: GNAT.IO.Put");
   GNAT.IO.Put (" and Put_Line reach the console");
   GNAT.IO.New_Line;
   GNAT.IO.Put_Line ("  ok: New_Line ends a line with CR LF");

   Console_Checks.Loopback;
   Test_Report.Finish;
end Textio_Test;
