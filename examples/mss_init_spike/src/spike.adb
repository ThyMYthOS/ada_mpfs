--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The body of Spike: see the spec.

pragma Suppress (All_Checks);

with Ada.Real_Time;
with Interfaces;
with System;
with System.Storage_Elements;

with Console;
with Fabric;
with Log;
with MPFS_Init_Table;
with MPFS_Registers.CLINT;
with MPFS_Registers.SCB_REGS;
with MPFS_Registers.SYSREG;
with Sink;
with Ticker;
with Uart;

package body Spike is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Mss_Init.Timeout_Policy;
   use MPFS_Init_Table;

   subtype U64 is Interfaces.Unsigned_64;

   --  The registers of the snapshots: all readable before the MMUART has
   --  its clock (those of MMUART0 are read after Open). They are objects of
   --  the register package; only their addresses are used.
   Clock_Config_CR : constant System.Address :=
     MPFS_Registers.SYSREG.SYSREG_Periph.CLOCK_CONFIG_CR'Address;
   Subblk_Clock_CR : constant System.Address :=
     MPFS_Registers.SYSREG.SYSREG_Periph.SUBBLK_CLOCK_CR'Address;
   Soft_Reset_CR   : constant System.Address :=
     MPFS_Registers.SYSREG.SYSREG_Periph.SOFT_RESET_CR'Address;
   MSSIO_Control   : constant System.Address :=
     MPFS_Registers.SCB_REGS.SCB_REGS_Periph.MSSIO_CONTROL_CR'Address;
   MTIME           : constant System.Address :=
     MPFS_Registers.CLINT.CLINT_Periph.MTIME'Address;

   Flush_Budget : constant := 5_000_000;   --  microseconds

   procedure Hex (Value : Word);
   procedure Dec (Value : Natural);
   procedure Prefix (Image : String);
   procedure Snapshot (Image : String; Index : Positive);
   procedure Hex_Field (Name : String; Value : Word);
   procedure Port_State (Image : String; Name : String; Item : Uart.Port);
   procedure Hex (Value : System.Address);

   procedure Hex (Value : Word) is
   begin
      Console.Put_Hex (U64 (Value), 8);
   end Hex;

   procedure Hex (Value : System.Address) is
   begin
      Console.Put_Hex
        (U64 (System.Storage_Elements.To_Integer (Value)), 8);
   end Hex;

   procedure Dec (Value : Natural) is
   begin
      Console.Put_Dec (U64 (Value));
   end Dec;

   procedure Prefix (Image : String) is
   begin
      Console.Put (Image);
      Console.Put (": ");
   end Prefix;

   procedure Hex_Field (Name : String; Value : Word) is
   begin
      Console.Put (" ");
      Console.Put (Name);
      Console.Put (" ");
      Hex (Value);
   end Hex_Field;

   --  The state of a port, read when it is idle: the divisor of 115200 baud
   --  is DLR 0x16, DMR 0.
   procedure Port_State (Image : String; Name : String; Item : Uart.Port) is
      State : constant Uart.State := Uart.Read_State (Item);
   begin
      Prefix (Image);
      Console.Put (Name);
      Hex_Field ("LCR", State.LCR);
      Hex_Field ("MCR", State.MCR);
      Hex_Field ("DLR", Word (State.DLR));
      Hex_Field ("DMR", Word (State.DMR));
      Console.Put_Line ("");
   end Port_State;

   --  After phase Index: the registers that say what the clocks and the IO
   --  banks are doing, and the ratio of mcycle to mtime over 200 us (80
   --  where the CPU is at 80 MHz and mtime at 1 MHz; "mtime stopped" if it
   --  does not count).
   procedure Snapshot (Image : String; Index : Positive) is
      M0 : constant U64 := Mss_Init.Read_64 (MTIME);
      C0 : constant U64 := Mss_Init.Cycles;
      C1, M1 : U64;
   begin
      Mss_Init.Wait (200);
      M1 := Mss_Init.Read_64 (MTIME);
      C1 := Mss_Init.Cycles;
      Prefix (Image);
      Console.Put ("snapshot ");
      Dec (Index);
      Hex_Field ("CLOCK_CONFIG_CR", Mss_Init.Read (Clock_Config_CR));
      Hex_Field ("MSSIO_CONTROL_CR", Mss_Init.Read (MSSIO_Control));
      Hex_Field ("SUBBLK_CLOCK_CR", Mss_Init.Read (Subblk_Clock_CR));
      Hex_Field ("SOFT_RESET_CR", Mss_Init.Read (Soft_Reset_CR));
      if M1 > M0 then
         Console.Put (", mcycle/mtime ");
         Console.Put_Dec ((C1 - C0) * 100 / (M1 - M0) / 100);
         Console.Put (".");
         Console.Put_Dec ((C1 - C0) * 100 / (M1 - M0) mod 100);
         Console.Put (" (");
         Console.Put_Dec (C1 - C0);
         Console.Put (" / ");
         Console.Put_Dec (M1 - M0);
         Console.Put (")");
      else
         Console.Put (", mtime stopped");
      end if;
      Console.Put_Line ("");
   end Snapshot;

   procedure Run
     (Image       : String;
      Policy      : Mss_Init.Timeout_Policy;
      Tick_Count  : Natural;
      Period_Ms   : Positive;
      Before_Tick : Tick_Hook := null)
   is
      Result  : Mss_Init.Run_Result;
      Printed : Natural := 0;
      T0, T1  : U64;
      Control : Word;
      Late    : Boolean;
      Ticking : Boolean;
   begin
      Prefix (Image);
      Console.Put ("MSS init from ");
      Console.Put_Line (XML_Source);
      Prefix (Image);
      Console.Put_Line (Design);
      Prefix (Image);
      Console.Put ("xml sha256 ");
      Console.Put_Line (XML_SHA256);
      Prefix (Image);
      Dec (Step_Count);
      Console.Put (" table entries in ");
      Dec (Phase_Count);
      Console.Put (" phases, a poll that times out ");
      if Policy = Mss_Init.Stop then
         Console.Put_Line ("stops the sequence");
      else
         Console.Put_Line ("is reported and the sequence goes on");
      end if;

      for Index in Phases'Range loop
         declare
            P : Phase renames Phases (Index);
            Before : constant Natural := Result.Executed;
            Timeouts_Before : constant Natural := Result.Timeouts;
         begin
            Mss_Init.Run_Phase (Index, Policy, Result);
            Prefix (Image);
            Console.Put ("phase ");
            Dec (Index);
            Console.Put (" ");
            Console.Put (Texts (P.Name_First .. P.Name_Last));
            Console.Put (": entries ");
            Dec (P.First);
            Console.Put ("-");
            Dec (P.Last);
            Console.Put (", ");
            Dec (Result.Executed - Before);
            Console.Put (" run, ");
            Dec (Result.Timeouts - Timeouts_Before);
            Console.Put (" poll timeout(s), mtime ");
            Console.Put_Hex (Mss_Init.Read_64 (MTIME), 8);
            Console.Put_Line ("");
            while Printed < Result.Timeouts
              and then Printed < Mss_Init.Max_Timeouts
            loop
               Printed := Printed + 1;
               declare
                  T : Mss_Init.Timeout renames Result.Seen (Printed);
                  S : Step renames Steps (T.Step);
               begin
                  Prefix (Image);
                  Console.Put ("TIMEOUT entry ");
                  Dec (T.Step);
                  Console.Put (": ");
                  Console.Put (Texts (S.Text_First .. S.Text_Last));
                  Console.Put (", ");
                  Hex (S.Register);
                  Console.Put (" and ");
                  Hex (S.Mask);
                  Console.Put (" is ");
                  Hex (T.Value and S.Mask);
                  Console.Put (", wanted ");
                  Hex (S.Value);
                  Console.Put_Line ("");
               end;
            end loop;
            Snapshot (Image, Index);
         end;
         exit when Result.Stopped;
      end loop;

      --  The proofs: they read what the sequence is meant to have made.
      T0 := Mss_Init.Read_64 (MTIME);
      Mss_Init.Wait (100);
      T1 := Mss_Init.Read_64 (MTIME);
      Prefix (Image);
      Console.Put ("mtime ");
      Console.Put_Hex (T0, 8);
      Console.Put (" then ");
      Console.Put_Hex (T1, 8);
      Console.Put (" after 100 us by mcycle: ");
      if T1 > T0 then
         Console.Put_Line ("advancing");
      else
         Console.Put_Line ("NOT advancing");
      end if;
      Control := Mss_Init.Read (PLL_Control);
      Prefix (Image);
      Console.Put ("MSS PLL: PLL_CTRL ");
      Hex (Control);
      Console.Put (", LOCK ");
      if (Control and PLL_Control_Lock) /= 0 then
         Console.Put_Line ("1");
      else
         Console.Put_Line ("0");
      end if;

      --  The hardware is configured (or the sequence has stopped): from
      --  here on the log goes out, by interrupt on MMUART2.
      Sink.Open;
      Fabric.Attach;
      Late := not Sink.Flush (Flush_Budget);
      Port_State (Image, "MMUART2", Uart.MMUART2);
      Prefix (Image);
      Dec (Result.Executed);
      Console.Put (" of ");
      Dec (Step_Count);
      Console.Put (" entries run, ");
      Dec (Result.Timeouts);
      Console.Put_Line (" poll timeout(s)");
      if Log.Dropped > 0 then
         Prefix (Image);
         Dec (Log.Dropped);
         Console.Put (" bytes dropped (the log did not fit in the ring of ");
         Dec (Log.Capacity);
         Console.Put_Line (" bytes)");
      end if;
      if Late then
         Prefix (Image);
         Console.Put_Line ("the sink did not send the log in time");
      end if;
      Late := not Sink.Flush (Flush_Budget) or else Late;

      --  What went through the ring before this line: a test counts the
      --  bytes that arrived before it.
      declare
         Through : constant Natural := Log.Accepted;
      begin
         Prefix (Image);
         Console.Put ("log: ");
         Dec (Through);
         Console.Put (" bytes through the ring, ");
         Dec (Log.Dropped);
         Console.Put (" dropped, ");
         Dec (Sink.Interrupts);
         Console.Put_Line (" sink interrupt(s)");
      end;

      --  The interrupts of the fabric so far (Fabric): the first occurrence
      --  is not lost if only the console is watched. The status lines on
      --  MMUART0 carry the table on.
      declare
         Any : Boolean := False;
      begin
         Prefix (Image);
         Console.Put ("fabric interrupts before the loop: ");
         for Item in Fabric.Index loop
            if Fabric.Occurred (Item) then
               if Any then
                  Console.Put (", ");
               end if;
               Dec (Fabric.Id_Of (Item));
               Console.Put (" x");
               Dec (Fabric.Count_Of (Item));
               Any := True;
            end if;
         end loop;
         if not Any then
            Console.Put ("none");
         end if;
         Console.Put_Line ("");
      end;
      --  The status lines on MMUART0 need a sequence that ended well and an
      --  mtime that counts (the proof above): the loop waits on it.
      Ticking := not Result.Stopped and then T1 > T0;
      Prefix (Image);
      if Ticking then
         Console.Put ("status line on MMUART0 (");
         Dec (Uart.Tick_Baud);
         Console.Put (" baud) every ");
         Dec (Period_Ms);
         Console.Put_Line (" ms");
      elsif not Result.Stopped then
         Console.Put_Line
           ("mtime did not advance: no status lines on MMUART0");
      else
         Console.Put_Line ("no status lines on MMUART0: the sequence stopped");
      end if;
      Prefix (Image);
      if Result.Stopped then
         Console.Put_Line ("MSS INIT FAILED");
      elsif Result.Timeouts > 0 then
         Console.Put_Line ("MSS INIT DONE WITH TIMEOUTS");
      else
         Console.Put_Line ("MSS INIT OK");
      end if;
      Late := not Sink.Flush (Flush_Budget) or else Late;
      pragma Unreferenced (Late);

      --  One status line per period on MMUART0, after the log has been sent
      --  (Tick_Count lines, or without end if it is 0). The period is
      --  absolute (delay until): the relative delay is not in the profile.
      if Ticking then
         Ticker.Open;
         declare
            use type Ada.Real_Time.Time;
            Period : constant Ada.Real_Time.Time_Span :=
              Ada.Real_Time.Milliseconds (Period_Ms);
            Next   : Ada.Real_Time.Time := Ada.Real_Time.Clock;
            Count  : Natural := 0;
         begin
            while Tick_Count = 0 or else Count < Tick_Count loop
               Next := Next + Period;
               delay until Next;
               Count := Count + 1;
               if Before_Tick /= null then
                  Before_Tick (Count);
               end if;
               declare
                  Control : constant Word := Mss_Init.Read (PLL_Control);
               begin
                  Ticker.Put_Tick
                    (Count, Mss_Init.Read_64 (MTIME), Control,
                     (Control and PLL_Control_Lock) /= 0);
               end;
            end loop;
         end;
      end if;
   end Run;

end Spike;
