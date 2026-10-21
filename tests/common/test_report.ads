--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Test_Report -- the one reporting convention every test application shares,
--  so that tests/qemu/run_tests.sh and the hardware runner have exactly one
--  thing to look for. The host tests (tests/host/common/host_report.ads) print
--  the same lines.
--
--  Console protocol (written to MMUART0 through Bare_Console):
--
--    TEST <name>: START          printed by Start
--      ok: <what>                one line per Check that held
--      FAIL: <what>              one line per Check that did not
--      info: <what> = <value>    measurements, never asserted by the runner
--    TEST <name>: PASS           printed by Finish, only if every Check held
--    TEST <name>: FAIL           printed by Finish otherwise
--
--  Finish prints FAIL as well when NO check was made at all: a test that
--  asserts nothing must not be able to report success. It never returns: a
--  bare-board main must not fall off its end, and the runner stops QEMU at the
--  final line.

pragma Restrictions (No_Elaboration_Code);

with Bare_Console;

package Test_Report is

   procedure Start (Name : String);

   procedure Check (Condition : Boolean; What : String);

   procedure Info (What : String; Value : Bare_Console.U64);

   procedure Finish;
   pragma No_Return (Finish);

end Test_Report;
