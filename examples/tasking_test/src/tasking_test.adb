--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  tasking_test: the tasking runtime of crates/mpfs_rts runs on the hart of
--  the image (E51 = hart 0, U54 = hart 1 .. 4): the timer of that hart
--  (mtimecmp of the CLINT, indexed by mhartid) wakes tasks up.
--
--    - tasks of different priority that wait for the same instant run in
--      priority order, and not before that instant (Order);
--    - Clock advances, and delay until returns neither early nor late;
--    - a periodic task (Ticker.Worker, 10 ms) runs at its rate.
--
--  Reported with Test_Report as tasking_test_e51, tasking_test_u54 (hart 1) or
--  tasking_test_u54h2 .. 4, the rows of tests/qemu/tests.list.

with Ada.Real_Time; use Ada.Real_Time;

with Bare_Console;
with Interfaces;
with Order;
with Test_Report;
with Ticker;

procedure Tasking_Test is

   use type Interfaces.Unsigned_32;
   use type Order.Who;

   procedure Start;

   procedure Start is
   begin
      case Bare_Console.Hart_Id is
         when 0      => Test_Report.Start ("tasking_test_e51");
         when 1      => Test_Report.Start ("tasking_test_u54");
         when 2      => Test_Report.Start ("tasking_test_u54h2");
         when 3      => Test_Report.Start ("tasking_test_u54h3");
         when others => Test_Report.Start ("tasking_test_u54h4");
      end case;
   end Start;

   T0, T1 : Time;
   Before : Interfaces.Unsigned_32;
   Gained : Interfaces.Unsigned_32;

begin
   Start;
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   --  Two tasks of different priority wake up at Order.Release.
   delay until Order.Release + Milliseconds (50);
   Test_Report.Check (Order.Log.Count = 2, "both tasks woke up");
   Test_Report.Check
     (Order.Log.Woke_At (Order.High) >= Order.Release
      and Order.Log.Woke_At (Order.Low) >= Order.Release,
      "neither woke up before its time");
   Test_Report.Check
     (Order.Log.Position (Order.High) = 1
      and Order.Log.Position (Order.Low) = 2,
      "the task of the higher priority ran first");

   --  Clock and delay until.
   T0 := Clock;
   delay until T0 + Milliseconds (20);
   T1 := Clock;
   Test_Report.Check
     (T1 - T0 >= Milliseconds (20), "delay until does not return early");
   Test_Report.Check
     (T1 - T0 < Milliseconds (500), "delay until does not return too late");
   Test_Report.Check (T1 > T0, "Clock advances");

   --  The periodic task: 200 ms of a 10 ms period.
   Before := Ticker.Ticks;
   T0 := Clock;
   delay until T0 + Milliseconds (200);
   Gained := Ticker.Ticks - Before;
   Test_Report.Info ("ticks in 200 ms", Bare_Console.U64 (Gained));
   Test_Report.Check
     (Gained >= 12, "the 10 ms task ran at least 12 times in 200 ms");
   Test_Report.Check
     (Gained <= 28, "the 10 ms task ran at most 28 times in 200 ms");

   Test_Report.Finish;
end Tasking_Test;
