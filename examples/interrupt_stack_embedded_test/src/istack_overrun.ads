--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The timing event whose handler runs in the interrupt context, on the
--  interrupt stack, and overruns it (Istack.Overrun).

with Ada.Real_Time.Timing_Events;
with System;

package Istack_Overrun is

   protected Probe with Priority => System.Interrupt_Priority'Last is
      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event);
   end Probe;

   Event : Ada.Real_Time.Timing_Events.Timing_Event;

end Istack_Overrun;
