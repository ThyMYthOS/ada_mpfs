--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Host_Report -- the reporting convention of every native Ada host test. It
--  prints the same lines as the Test_Report of the target tests, so one reader
--  (the runners, a person, CI) understands every level:
--
--    TEST <name>: START
--      ok: <what>               one line per Check that held
--      FAIL: <what>             one line per Check that did not
--    TEST <name>: PASS|FAIL     printed by Finish
--
--  The exit status fails closed. Start sets it to Failure; only a Finish
--  after at least one check, none of which failed, sets it back to Success. A
--  test that fails a check, makes no check, ends in an unhandled exception or
--  never reaches Finish therefore exits non-zero.

package Host_Report is

   procedure Start (Name : String);

   procedure Check (Condition : Boolean; What : String);

   --  Prints the verdict and sets the exit status.
   procedure Finish;

   --  The number of checks that did not hold so far.
   function Failures return Natural;

end Host_Report;
