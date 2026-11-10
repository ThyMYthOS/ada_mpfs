--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package body Gates is

   use Ada.Real_Time;

   protected body Gate is

      entry Wait when Opened is
      begin
         Through := True;
         Time := Clock;
      end Wait;

      procedure Open is
      begin
         Opened := True;
      end Open;

      function Passed return Boolean is (Through);

      function Passed_At return Ada.Real_Time.Time is (Time);

   end Gate;

   protected body Stock is

      procedure Put (N : Positive) is
      begin
         Items := Items + N;
         Available := True;
      end Put;

      entry Take when Available is
      begin
         Items := Items - 1;
         Done := Done + 1;
         Available := Items > 0;
      end Take;

      function Taken return Natural is (Done);

   end Stock;

   protected body Probe is

      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event)
      is
         pragma Unreferenced (Event);
      begin
         Count := Count + 1;
         Time := Clock;
      end Handle;

      function Runs return Natural is (Count);

      function Last_Run return Ada.Real_Time.Time is (Time);

   end Probe;

   task body Waiter is
   begin
      Gate.Wait;
      delay until Time_Last;
   end Waiter;

   task body Consumer is
   begin
      for Item in 1 .. 3 loop
         Stock.Take;
      end loop;
      delay until Time_Last;
   end Consumer;

end Gates;
