--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Istack;

package body Istack_Overrun is

   protected body Probe is

      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event)
      is
         pragma Unreferenced (Event);
      begin
         Istack.Overrun;
      end Handle;

   end Probe;

end Istack_Overrun;
