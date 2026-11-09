--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  protected_test: protected objects and timing events of the tasking
--  runtime, on the hart of the image.
--
--    - the caller of an entry whose barrier is False waits, and is let
--      through after the barrier became True and not before (Gate);
--    - an entry that is called again and again takes one item per Put and
--      waits again when the stock is empty (Stock);
--    - a timing event runs its handler once, not before its time (Probe),
--      and one that is cancelled does not run.
--
--  The bounds are wide: QEMU's mtime follows the host clock. Reported with
--  Test_Report as protected_test_e51 or protected_test_u54 (and as
--  protected_embedded_test_* by the example of the embedded profile).
--
--  @verifies RTS-021

with Ada.Real_Time; use Ada.Real_Time;
with Ada.Real_Time.Timing_Events;

with Bare_Console;
with Gates;
with Test_Name;
with Test_Report;

procedure Protected_Test is

   use type Bare_Console.U64;
   use type Ada.Real_Time.Timing_Events.Timing_Event_Handler;

   T0        : Time;
   Cancelled : Boolean;

begin
   Test_Report.Start
     (if Bare_Console.Hart_Id = 0 then Test_Name.Base & "_e51"
      else Test_Name.Base & "_u54");
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   --  An entry with a false barrier.
   delay until Clock + Milliseconds (20);
   Test_Report.Check
     (not Gates.Gate.Passed, "a caller waits while the barrier is false");
   T0 := Clock;
   Gates.Gate.Open;
   delay until Clock + Milliseconds (20);
   Test_Report.Check
     (Gates.Gate.Passed, "the caller is let through once the barrier is true");
   Test_Report.Check
     (Gates.Gate.Passed_At >= T0, "and not before the barrier became true");

   --  An entry that takes one item at a time.
   Test_Report.Check
     (Gates.Stock.Taken = 0, "nothing is taken from an empty stock");
   Gates.Stock.Put (1);
   delay until Clock + Milliseconds (20);
   Test_Report.Check (Gates.Stock.Taken = 1, "one item put, one item taken");
   delay until Clock + Milliseconds (20);
   Test_Report.Check
     (Gates.Stock.Taken = 1, "the consumer waits again at an empty stock");
   Gates.Stock.Put (2);
   delay until Clock + Milliseconds (20);
   Test_Report.Check
     (Gates.Stock.Taken = 3, "two items put, two more items taken");

   --  A timing event runs its handler once, and not before its time.
   T0 := Clock;
   Ada.Real_Time.Timing_Events.Set_Handler
     (Gates.Event, T0 + Milliseconds (40), Gates.Probe.Handle'Access);
   Test_Report.Check
     (Ada.Real_Time.Timing_Events.Current_Handler (Gates.Event)
      = Gates.Probe.Handle'Access,
      "the handler is set");
   delay until T0 + Milliseconds (20);
   Test_Report.Check
     (Gates.Probe.Runs = 0, "the handler has not run before its time");
   delay until T0 + Milliseconds (100);
   Test_Report.Check (Gates.Probe.Runs = 1, "the handler has run once");
   Test_Report.Check
     (Gates.Probe.Last_Run >= T0 + Milliseconds (40),
      "and not before the time of the event");
   Test_Report.Check
     (Ada.Real_Time.Timing_Events.Current_Handler (Gates.Event) = null,
      "an event that has run has no handler");

   --  A cancelled event does not run.
   T0 := Clock;
   Ada.Real_Time.Timing_Events.Set_Handler
     (Gates.Event, T0 + Milliseconds (40), Gates.Probe.Handle'Access);
   Ada.Real_Time.Timing_Events.Cancel_Handler (Gates.Event, Cancelled);
   Test_Report.Check (Cancelled, "Cancel_Handler cancels a pending event");
   delay until T0 + Milliseconds (100);
   Test_Report.Check
     (Gates.Probe.Runs = 1, "a cancelled event does not run");

   Test_Report.Finish;
end Protected_Test;
