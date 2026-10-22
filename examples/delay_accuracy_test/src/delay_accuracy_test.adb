--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  delay_accuracy_test: the tickless timer and the idle of the runtime
--  (master plan #41, work package P1.6, #47).
--
--    - mtimecmp of the own hart is the next alarm and nothing else: the
--      maximum (disarmed) at the start, the alarm of the delay while the main
--      program sleeps, the maximum again after the wake-up, and mip.MTIP is
--      clear whenever no alarm is due (no spurious tick);
--    - a delay until never returns early, and its deviation from the
--      requested instant, read from mtime, is within
--      Accuracy_Limits.Max_Late_Ticks (the acceptance of #47 on the board:
--      2 ticks plus the interrupt latency; under QEMU only a loose bound,
--      because mtime follows the host's clock); mcycle gives it in cycles;
--    - a delay until in the past returns at once and arms nothing, a timing
--      event in the past runs at once;
--    - idle: while every task sleeps the hart is in wfi. The instructions
--      retired (minstret) during a delay of 100 ms are counted: a few hundred
--      on the board (strict), millions for an idle task that polls. QEMU's
--      minstret does not count executed instructions, so it is reported
--      there and not asserted;
--    - Clock_Frequency: Standalone_Clocks states at compile time that
--      Time_Unit is 1 / Clocks.Rtc_Toggle_Hz.
--
--  Reported with Test_Report as delay_accuracy_test_e51,
--  delay_accuracy_test_u54 (hart 1) or delay_accuracy_test_u54h2 .. 4, the
--  rows of tests/qemu/tests.list. On the board (P1.14) it is built with
--  DELAY_ACCURACY=hardware; QEMU is the "-" column of the test table of #41.

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  The test is about the units of the runtime: System.BB.RISCV_CLINT

with Ada.Real_Time; use Ada.Real_Time;
with Ada.Real_Time.Timing_Events;

with Accuracy_Limits;
with Bare_Console;
with CSR;
with Interfaces;
with Probes;
with Standalone_Clocks;
pragma Unreferenced (Standalone_Clocks);
--  withed for its Compile_Time_Error
with Test_Report;

with System.BB.RISCV_CLINT;

procedure Delay_Accuracy_Test is

   package CLINT renames System.BB.RISCV_CLINT;

   use type Interfaces.Integer_64;
   use type Interfaces.Unsigned_64;
   use type CLINT.Counter;

   subtype I64 is Interfaces.Integer_64;
   subtype U64 is Bare_Console.U64;

   Hart : constant CLINT.Hart_Id := CLINT.Hart_Id (Bare_Console.Hart_Id);

   Max_Counter : constant CLINT.Counter := CLINT.Counter'Last;

   Intervals : constant array (1 .. 5) of Natural :=
     [1_000, 2_000, 5_000, 10_000, 50_000];
   --  microseconds = ticks of mtime

   Limit : constant I64 := Accuracy_Limits.Max_Late_Ticks;

   Idle_Rounds : constant := 10;

   procedure Start;

   procedure Start is
   begin
      case Bare_Console.Hart_Id is
         when 0      => Test_Report.Start ("delay_accuracy_test_e51");
         when 1      => Test_Report.Start ("delay_accuracy_test_u54");
         when 2      => Test_Report.Start ("delay_accuracy_test_u54h2");
         when 3      => Test_Report.Start ("delay_accuracy_test_u54h3");
         when others => Test_Report.Start ("delay_accuracy_test_u54h4");
      end case;
   end Start;

   function Ticks (T : Time) return I64;
   --  The value of mtime at which T falls (Epoch is mtime 0, a tick is 1 us)

   function Ticks (T : Time) return I64 is
      Seconds : Seconds_Count;
      Part    : Time_Span;
   begin
      Split (T, Seconds, Part);
      return I64 (Seconds) * 1_000_000 + I64 (Part / Tick);
   end Ticks;

   function Now return I64 is (I64 (CLINT.Mtime));
   --  mtime, read through the PAC: independent of Ada.Real_Time.Clock

   procedure Info (What : String; V : I64);

   procedure Info (What : String; V : I64) is
   begin
      Test_Report.Info (What, (if V < 0 then 0 else U64 (V)));
   end Info;

   Late_Max, Late_Sum : array (Intervals'Range) of I64 := [others => 0];
   --  per interval
   Late_Min   : I64 := I64'Last;
   Worst      : I64 := 0;

   Target     : Time;
   Late       : I64;
   Samples_0  : Natural;
   Observed   : Natural := 0;
   Total      : Natural := 0;
   Any_Early  : Boolean := False;
   Armed_OK   : Boolean := True;
   Cleared_OK : Boolean := True;
   Pending_OK : Boolean := True;

   Instret_0, Instret_1 : Interfaces.Unsigned_64;
   Cycle_0, Cycle_1     : Interfaces.Unsigned_64;
   Mtime_0, Mtime_1     : I64;

begin
   Start;
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   --  Nothing has armed the timer yet.
   Test_Report.Check
     (CLINT.Mtimecmp (Hart) = Max_Counter,
      "mtimecmp of this hart is the maximum at the start (disarmed)");
   Test_Report.Check
     ((CSR.Mip and CSR.MTIP) = 0,
      "no timer interrupt is pending at the start (no spurious tick)");

   --  Delays of several lengths, repeatedly: the deviation from the
   --  requested instant.
   for I in Intervals'Range loop
      for Round in 1 .. Accuracy_Limits.Rounds loop
         Target := Clock + Microseconds (Intervals (I));
         Samples_0 := Probes.Observed.Samples;
         Probes.Observed.Arm;
         delay until Target;
         Late := Now - Ticks (Target);

         Total := Total + 1;
         Any_Early := Any_Early or else Late < 0;
         Late_Min := I64'Min (Late_Min, Late);
         Late_Max (I) := I64'Max (Late_Max (I), Late);
         Late_Sum (I) := Late_Sum (I) + Late;
         Worst := I64'Max (Worst, Late);

         --  The observer, of lower priority, ran while the main program
         --  slept (it does not if the instant had passed before the delay
         --  began): mtimecmp was the alarm of this delay, exactly.
         if Probes.Observed.Samples = Samples_0 + 1 then
            Observed := Observed + 1;
            Armed_OK := Armed_OK
              and then Probes.Observed.Mtimecmp
                         = Interfaces.Unsigned_64 (Ticks (Target));
         end if;
         --  After the wake-up the alarm is acknowledged, nothing is armed.
         Cleared_OK := Cleared_OK and then CLINT.Mtimecmp (Hart) = Max_Counter;
         Pending_OK := Pending_OK and then (CSR.Mip and CSR.MTIP) = 0;
      end loop;
   end loop;

   Test_Report.Info ("delays", U64 (Total));
   Test_Report.Info ("delays in which the observer ran", U64 (Observed));
   Test_Report.Check
     ((if Accuracy_Limits.Strict then Observed * 10 >= Total * 9
       else Observed > 0),
      "the observer ran while the main program slept");
   Test_Report.Check
     (Armed_OK,
      "while the main program sleeps mtimecmp of this hart is its alarm");
   Test_Report.Check
     (Cleared_OK,
      "after the wake-up mtimecmp is the maximum again (nothing armed)");
   Test_Report.Check (Pending_OK, "and no timer interrupt is pending");
   Test_Report.Check
     (not Any_Early,
      "delay until never returns early (mtime >= the requested instant)");

   Info ("late min, all delays [ticks]", Late_Min);
   for I in Intervals'Range loop
      declare
         Avg : constant I64 := Late_Sum (I) / I64 (Accuracy_Limits.Rounds);
      begin
         case I is
            when 1 =>
               Info ("late avg 1 ms [ticks]", Avg);
               Info ("late max 1 ms [ticks]", Late_Max (I));
            when 2 =>
               Info ("late avg 2 ms [ticks]", Avg);
               Info ("late max 2 ms [ticks]", Late_Max (I));
            when 3 =>
               Info ("late avg 5 ms [ticks]", Avg);
               Info ("late max 5 ms [ticks]", Late_Max (I));
            when 4 =>
               Info ("late avg 10 ms [ticks]", Avg);
               Info ("late max 10 ms [ticks]", Late_Max (I));
            when others =>
               Info ("late avg 50 ms [ticks]", Avg);
               Info ("late max 50 ms [ticks]", Late_Max (I));
         end case;
      end;
   end loop;
   if Accuracy_Limits.Strict then
      Test_Report.Check
        (Worst <= Limit,
         "the deviation of delay until is at most 2 ticks plus the latency");
   else
      Test_Report.Check
        (Worst <= Limit,
         "the deviation of delay until is within the loose bound of QEMU");
   end if;

   --  A delay until in the past (or now) returns at once and arms nothing.
   Mtime_0 := Now;
   delay until Clock - Milliseconds (1);
   delay until Clock;
   Mtime_1 := Now;
   Info ("two delays in the past took [ticks]", Mtime_1 - Mtime_0);
   Test_Report.Check
     (Mtime_1 - Mtime_0 <= Limit, "delay until in the past returns at once");
   Test_Report.Check (CLINT.Mtimecmp (Hart) = Max_Counter, "and arms nothing");

   --  A timing event in the past: mtimecmp is set to a value in the past and
   --  the interrupt is pending at once.
   Mtime_0 := Now;
   Ada.Real_Time.Timing_Events.Set_Handler
     (Probes.Event, Clock - Milliseconds (1), Probes.Fired.Handle'Access);
   delay until Clock + Microseconds (Natural (Limit) + 100);
   Test_Report.Check
     (Probes.Fired.Count = 1, "a timing event in the past has run, once");
   Info ("it ran after [ticks]", I64 (Probes.Fired.Mtime) - Mtime_0);
   Test_Report.Check
     (I64 (Probes.Fired.Mtime) - Mtime_0 <= Limit,
      "and without waiting for another tick");
   Test_Report.Check
     (CLINT.Mtimecmp (Hart) = Max_Counter and then (CSR.Mip and CSR.MTIP) = 0,
      "its alarm is acknowledged (mtimecmp the maximum, MTIP clear)");

   --  Idle: the alarm interrupt finds the hart in wfi. A timing event 10 ms
   --  ahead of the main program's delay runs in the interrupt; mepc is the
   --  instruction after the wfi that the interrupt woke up. An idle task
   --  that polls has no wfi in front of its pc.
   for Round in 1 .. Idle_Rounds loop
      Ada.Real_Time.Timing_Events.Set_Handler
        (Probes.Idle_Event, Clock + Milliseconds (10),
         Probes.Idle.Handle'Access);
      delay until Clock + Milliseconds (20);
   end loop;
   Info ("idle: alarm interrupts", I64 (Probes.Idle.Runs));
   Info ("idle: found the hart in wfi", I64 (Probes.Idle.In_Wfi));
   Test_Report.Check
     (Probes.Idle.Runs = Idle_Rounds and then Probes.Idle.In_Wfi = Idle_Rounds,
      "every alarm interrupt while all tasks sleep found the hart in wfi");

   --  And nothing else runs for 100 ms: count the instructions.
   Mtime_0 := Now;
   Cycle_0 := CSR.Mcycle;
   Instret_0 := CSR.Minstret;
   delay until Clock + Milliseconds (100);
   Instret_1 := CSR.Minstret;
   Cycle_1 := CSR.Mcycle;
   Mtime_1 := Now;
   Info ("idle: mtime ticks", Mtime_1 - Mtime_0);
   Info ("idle: mcycle", I64 (Cycle_1 - Cycle_0));
   Info ("idle: minstret", I64 (Instret_1 - Instret_0));
   Info ("idle: mcycle per mtime tick",
         I64 (Cycle_1 - Cycle_0) / I64'Max (1, Mtime_1 - Mtime_0));
   if Accuracy_Limits.Strict then
      Test_Report.Check
        (I64 (Instret_1 - Instret_0) <= Accuracy_Limits.Idle_Max_Instret,
         "while every task sleeps the hart retires next to no instructions");
   end if;

   Test_Report.Finish;
end Delay_Accuracy_Test;
