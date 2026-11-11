--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The limits of delay_accuracy_test on the board (DELAY_ACCURACY=hardware,
--  P1.14, #55): the acceptance of work package P1.6 (#47), "deviation <= 2
--  ticks plus interrupt latency".

package Accuracy_Limits is

   Strict : constant Boolean := True;

   Interrupt_Latency_Ticks : constant := 18;
   --  The time from the expiry of mtimecmp to the first instruction of the
   --  task that was woken: trap entry, the alarm handler (timing events, alarm
   --  queue), the context switch and a Clock read. Measured on the Icicle Kit
   --  (P1.14, #55) on the E51 and on U54 harts 1 to 4 at 80 MHz (79 cycles per
   --  tick): the largest deviation of any delay in all runs is 15 ticks (the
   --  1 ms delay), the smallest 9 (E51) or 11 (U54). So the latency is about
   --  13 ticks; 18 leaves a margin of 5 (docs/lab/results/p1.md).

   Max_Late_Ticks : constant := 2 + Interrupt_Latency_Ticks;
   --  one tick for the comparison (mtime >= mtimecmp is seen at the next tick
   --  of mtime), one for the rounding of the read after the wake-up, plus the
   --  latency

   Rounds : constant := 50;
   --  delays per interval

   Idle_Max_Instret : constant := 20_000;
   --  Instructions the hart may retire while every task sleeps for 100 ms. An
   --  idle task that polls instead of executing wfi retires tens of
   --  millions in that time (80 cycles per tick at 80 MHz); the wake-up
   --  itself costs a few hundred.

end Accuracy_Limits;
