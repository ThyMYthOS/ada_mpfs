--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The protected objects of protected_test, and the tasks that call their
--  entries (Ravenscar: library level, one entry per object, one task at a
--  time in an entry queue, a barrier that is one Boolean variable).
--
--    Gate    an entry whose barrier is False until Open.
--    Stock   an entry that takes one item and waits while there is none.
--    Probe   the handler of the timing events: it runs in the alarm
--            interrupt, so its ceiling is Interrupt_Priority'Last.

with Ada.Real_Time;
with Ada.Real_Time.Timing_Events;
with System;

package Gates is

   protected Gate with Priority => System.Priority'Last is
      entry Wait;
      procedure Open;
      function Passed return Boolean;
      --  True once the caller of Wait has been let through
      function Passed_At return Ada.Real_Time.Time;
   private
      Opened  : Boolean := False;
      Through : Boolean := False;
      Time    : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end Gate;

   protected Stock with Priority => System.Priority'Last is
      procedure Put (N : Positive);
      entry Take;
      function Taken return Natural;
   private
      Items     : Natural := 0;
      Available : Boolean := False;
      Done      : Natural := 0;
   end Stock;

   protected Probe with Priority => System.Interrupt_Priority'Last is
      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event);
      function Runs return Natural;
      function Last_Run return Ada.Real_Time.Time;
   private
      Count : Natural := 0;
      Time  : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end Probe;

   Event : Ada.Real_Time.Timing_Events.Timing_Event;

   task Waiter with Priority => 10, Storage_Size => 4096;
   --  Calls Gate.Wait

   task Consumer with Priority => 8, Storage_Size => 4096;
   --  Takes three items from Stock

end Gates;
