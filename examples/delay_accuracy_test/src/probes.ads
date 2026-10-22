--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What the test watches while it is not running itself:
--
--    Observer  a task of lower priority than the main program. It runs only
--              while the main program sleeps and then reads the mtimecmp of
--              the own hart, which is the alarm of the main program's delay.
--    Event     a timing event whose handler runs in the alarm interrupt and
--              records mtime.
--    Idle_Event  a timing event that fires while every task sleeps: its
--              handler looks at the pc of the interrupted instruction. If the
--              idle task was in wfi, the instruction in front of that pc is
--              the wfi.

with Ada.Real_Time.Timing_Events;
with Interfaces;
with System;

package Probes is

   protected Observed with Priority => System.Priority'Last is
      procedure Arm;
      --  The main program is about to sleep: let the observer sample
      entry Wait_Armed;
      procedure Sampled (Mtimecmp, Mtime : Interfaces.Unsigned_64);
      function Mtimecmp return Interfaces.Unsigned_64;
      function Mtime return Interfaces.Unsigned_64;
      function Samples return Natural;
   private
      Armed       : Boolean := False;
      Count       : Natural := 0;
      Cmp_Sample  : Interfaces.Unsigned_64 := 0;
      Time_Sample : Interfaces.Unsigned_64 := 0;
   end Observed;

   task Observer with Priority => 5, Storage_Size => 4096;

   protected Fired with Priority => System.Interrupt_Priority'Last is
      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event);
      function Count return Natural;
      function Mtime return Interfaces.Unsigned_64;
      --  mtime at the last run of the handler
   private
      Runs     : Natural := 0;
      At_Mtime : Interfaces.Unsigned_64 := 0;
   end Fired;

   Event : Ada.Real_Time.Timing_Events.Timing_Event;

   protected Idle with Priority => System.Interrupt_Priority'Last is
      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event);
      function Runs return Natural;
      function In_Wfi return Natural;
      --  How often the handler found the instruction in front of the
      --  interrupted pc to be a wfi
      function Mepc return Interfaces.Unsigned_64;
   private
      Count : Natural := 0;
      Hits  : Natural := 0;
      Pc    : Interfaces.Unsigned_64 := 0;
   end Idle;

   Idle_Event : Ada.Real_Time.Timing_Events.Timing_Event;

end Probes;
