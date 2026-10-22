--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  fp_context_test: the callee-saved floating-point registers fs0 .. fs11
--  belong to the task, not to the processor (regression test for defect no. 1
--  of the master plan: context_switch.S restored them from the context of the
--  task that was switched out). Three tasks of package Holders keep a
--  different value in each of the twelve registers across delay until (two of
--  them) and across the timer interrupt (the third, which never waits); the
--  environment task lets them run for 300 ms and then asks each for the
--  registers it lost.
--
--  U54 only: the E51 has no floating-point registers (its context and its
--  trap frame have none, see crates/mpfs_rts/README.md).
--
--  Reported with Test_Report as fp_context_test_u54.

with Ada.Real_Time; use Ada.Real_Time;

with Bare_Console;
with Holders;
with Interfaces;
with Test_Report;

procedure Fp_Context_Test is

   use type Interfaces.Unsigned_32;

   Limit : constant Time := Clock + Milliseconds (2_000);

begin
   Test_Report.Start ("fp_context_test_u54");
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   delay until Clock + Milliseconds (300);
   Holders.Results.Stop;

   --  The workers end their loop after their next wake-up (2 ms) or pass.
   while not Holders.Results.All_Finished and then Clock < Limit loop
      delay until Clock + Milliseconds (10);
   end loop;

   Test_Report.Check (Holders.Results.All_Finished, "all three tasks ended");

   for T in Holders.Which loop
      Test_Report.Info
        ((case T is
            when Holders.A    => "checks of task A",
            when Holders.B    => "checks of task B",
            when Holders.Spin => "checks of the spinning task"),
         Bare_Console.U64 (Holders.Results.Rounds (T)));
      Test_Report.Info
        ((case T is
            when Holders.A    => "lost registers of task A (mask)",
            when Holders.B    => "lost registers of task B (mask)",
            when Holders.Spin => "lost registers of the spinning task (mask)"),
         Bare_Console.U64 (Holders.Results.Bad (T)));
   end loop;

   Test_Report.Check
     (Holders.Results.Rounds (Holders.A) >= 20
      and Holders.Results.Rounds (Holders.B) >= 20,
      "A and B each checked at least 20 times across delay until");
   Test_Report.Check
     (Holders.Results.Rounds (Holders.Spin) >= 2_000,
      "the spinning task checked at least 2000 times");
   Test_Report.Check
     (Holders.Results.Bad (Holders.A) = 0,
      "task A kept fs0 - fs11 across delay until");
   Test_Report.Check
     (Holders.Results.Bad (Holders.B) = 0,
      "task B kept fs0 - fs11 across delay until");
   Test_Report.Check
     (Holders.Results.Bad (Holders.Spin) = 0,
      "the spinning task kept fs0 - fs11 across the timer interrupts");

   Test_Report.Finish;
end Fp_Context_Test;
