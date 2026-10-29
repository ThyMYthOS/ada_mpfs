--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The limits of delay_accuracy_test on the board (DELAY_ACCURACY=hardware,
--  P1.14, #55): the acceptance of work package P1.6 (#47), "deviation <= 2
--  ticks plus interrupt latency".

package Accuracy_Limits is

   Strict : constant Boolean := True;

   Interrupt_Latency_Ticks : constant := 30;
   --  The time from the expiry of mtimecmp to the first instruction of the
   --  task that was woken: trap entry, the alarm handler (timing events, alarm
   --  queue), the context switch and a Clock read. A placeholder (30 us is 18
   --  000 cycles at 600 MHz, a generous bound for the roughly thousand
   --  instructions of that path) until the hardware run (P1.14) has measured
   --  it; the measured maximum is reported as an info line.

   Max_Late_Ticks : constant := 2 + Interrupt_Latency_Ticks;
   --  one tick for the comparison (mtime >= mtimecmp is seen at the next tick
   --  of mtime), one for the rounding of the read after the wake-up, plus the
   --  latency

   Rounds : constant := 50;
   --  delays per interval

   Idle_Max_Instret : constant := 20_000;
   --  Instructions the hart may retire while every task sleeps for 100 ms. An
   --  idle task that polls instead of executing wfi retires tens of
   --  millions in that time (600 cycles per tick at 600 MHz); the wake-up
   --  itself costs a few hundred.

end Accuracy_Limits;
