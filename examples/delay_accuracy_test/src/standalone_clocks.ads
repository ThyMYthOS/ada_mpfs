--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Stand-in for the clock part of the partition package that the generator
--  (P1.12, #53; P2 from the XML) writes: Clocks.Rtc_Toggle_Hz is the frequency
--  of the RTC clock, which is what mtime counts (1 MHz in the standalone
--  default; from P2 it comes from the XML). The runtime's Clock_Frequency
--  (System.BB.Board_Parameters, visible as Ada.Real_Time.Time_Unit = 1.0 /
--  Clock_Frequency) has to be that frequency, and the partition package states
--  it in this form, so that a partition whose RTC clock is not the one of the
--  runtime does not compile:
--
--     pragma Compile_Time_Error
--       (Ada.Real_Time.Time_Unit * Clocks.Rtc_Toggle_Hz /= 1.0, "...");
--
--  tests/host/rts_tick compiles this unit with the right value (must compile)
--  and with others (must not).

with Ada.Real_Time;

package Standalone_Clocks is

   package Clocks is
      Rtc_Toggle_Hz : constant := 1_000_000;
   end Clocks;

   pragma Compile_Time_Error
     (Ada.Real_Time.Time_Unit * Clocks.Rtc_Toggle_Hz /= 1.0,
      "Clock_Frequency of the runtime is not Clocks.Rtc_Toggle_Hz");

end Standalone_Clocks;
