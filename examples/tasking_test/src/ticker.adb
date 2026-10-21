--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Real_Time; use Ada.Real_Time;

package body Ticker is

   use type Interfaces.Unsigned_32;

   Period : constant Time_Span := Milliseconds (10);

   task body Worker is
      Next : Time := Clock;
   begin
      loop
         Ticks := Ticks + 1;
         Next := Next + Period;
         delay until Next;
      end loop;
   end Worker;

end Ticker;
