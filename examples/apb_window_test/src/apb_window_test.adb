--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The LO and HI windows of the APB peripherals under SYSREG.APBBUS_CR, and
--  whether one PMP window per AMP context separates the peripherals of the
--  two contexts. APBBUS_CR (SYSREG + 16#80#) maps a peripheral into the LO
--  window (16#2000_0000#, AXI bus 5) with its bit 0 and into the HI window
--  (16#2800_0000#, AXI bus 6) with its bit 1.
--
--  The MSS TRM (DS60001702S, 3.8) says that a peripheral accessed in the
--  wrong window answers with PSLVERR, reported to the core as an AXI response
--  error. On the Icicle Kit that was not observed: no access in the wrong
--  window faulted, a read there answered 0 and a write there did not reach
--  the peripheral. So the test checks what was measured, that an access in
--  the wrong window has no effect: a read there does not return the value
--  the peripheral holds, a write there does not change it. Whether the
--  access faults is reported (an info line), not checked. After each access
--  in the wrong window the test reports where an error might have gone: the
--  Bus Error Unit of the hart, mip and the PLIC pending bits of the five bus
--  error sources.
--
--  The values are unambiguous: a non-zero pattern is written through the
--  right window first. The registers: the scratch register SR (offset
--  16#1C#) of MMUART3 and MMUART2 (not the console, no side effect), the
--  load value TIM1LOADVAL (offset 16#4#) of the timer and COMPARE_LOWER
--  (offset 16#14#) of the RTC, which hold what is written (MSS TRM register
--  maps; svd/base/mstimer.yaml, svd/base/msrtc.yaml).
--
--  Every access goes through pmp_try (pmp_probe/pmp_try.S), so that an
--  access fault ends the access instead of the test; a line "next:" before
--  each access shows where a hang stopped it. Steps:
--
--    0. whether APBBUS_CR holds the bit of MMUART3 (the board; neither QEMU
--       nor Renode models it: there the HI steps are left out); the Bus Error
--       Unit is set to record a TileLink bus error (its cause 5) and to
--       raise its PLIC source, the local interrupt off; mie stays 0 (start.S),
--       so nothing is taken;
--    1. all in LO: SR of MMUART3, the timer and the RTC hold a write at LO;
--       at HI a read does not return it and a write does not change it;
--    2. MMUART3 in HI: SR holds a write at HI; at LO a read does not return
--       it and a write, with the posted mode of the AHB-APB bridges off and
--       on (SYSREG.AHBAPB_CR, offset 16#90#), does not change it; the reverse
--       with MMUART2, left in LO: at HI a read does not return SR, a write
--       does not change it;
--    3. RTC and timer in HI, at 16#2812_4000# and 16#2812_5000# (the SVD;
--       the TRM's Table 10-2 shows 16#2012_4FFF# and 16#2012_5FFF#): they
--       hold a write at HI; at LO a read does not return it and a write does
--       not change it;
--    4. in U mode, MMUART3 in HI (context B), MMUART2 in LO (context A), one
--       NAPOT entry RW over the 256 KiB at 16#2010_0000# (A) or
--       16#2810_0000# (B): the own peripheral answers, the other window
--       faults (5, 7) (checked); the other peripheral at its address in the
--       own window (measured);
--    5. APBBUS_CR, AHBAPB_CR, the Bus Error Unit and the PMP back as they
--       were.
--
--  Where an emulator does not model a register at its LO address (the
--  write or the read faults), its checks are left out with an info line;
--  with a HI window (the board) they are made.
--
--  It reports apb_window_test_e51, apb_window_test_u54 (hart 1) or
--  apb_window_test_u54h<n> (harts 2 to 4).
--
--  @verifies HW-004

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with System.Machine_Code;
with System.Storage_Elements;
with Bare_Console; use Bare_Console;
with Pmp_Csr;      use Pmp_Csr;
with Test_Report;

procedure Apb_Window_Test is

   function Try (Op, Addr, User, Value : U64) return U64
     with Import, Convention => C, External_Name => "pmp_try";

   User_Page : U64
     with Import, Convention => C, External_Name => "pmp_user_page";
   Value : U64
     with Import, Volatile, Convention => C, External_Name => "pmp_try_value";

   type Word is mod 2 ** 32;

   SYSREG : constant := 16#2000_2000#;
   Apbbus_CR : Word
     with Volatile, Address => System'To_Address (SYSREG + 16#80#);
   Clock_CR : Word
     with Volatile, Address => System'To_Address (SYSREG + 16#84#);
   Reset_CR : Word
     with Volatile, Address => System'To_Address (SYSREG + 16#88#);
   Ahbapb_CR : Word
     with Volatile, Address => System'To_Address (SYSREG + 16#90#);

   --  SUBBLK_CLOCK_CR and SOFT_RESET_CR: TIMER 4, MMUART2 7, MMUART3 8,
   --  RTC 18. APBBUS_CR: MMUART2 2, MMUART3 3, TIMER 18, RTC 22.
   --  AHBAPB_CR: APB0_POSTED 0, APB1_POSTED 1.
   Blocks    : constant Word := 2 ** 4 or 2 ** 7 or 2 ** 8 or 2 ** 18;
   Hi_Uart2  : constant Word := 2 ** 2;
   Hi_Uart3  : constant Word := 2 ** 3;
   Hi_Timers : constant Word := 2 ** 18 or 2 ** 22;
   Posted    : constant Word := 2 ** 0 or 2 ** 1;

   LO       : constant U64 := 16#2000_0000#;
   HI       : constant U64 := 16#2800_0000#;
   Uart2    : constant U64 := 16#0010_2000#;
   Uart3    : constant U64 := 16#0010_4000#;
   Rtc      : constant U64 := 16#0012_4000#;
   Timer    : constant U64 := 16#0012_5000#;
   SR       : constant U64 := 16#1C#;
   Loadval  : constant U64 := 16#4#;    --  TIM1LOADVAL
   Compare  : constant U64 := 16#14#;   --  COMPARE_LOWER_REG
   Block    : constant U64 := 16#0010_0000#;   --  MMUART1 .. at 256 KiB
   Block_Sz : constant U64 := 16#4_0000#;

   --  The Bus Error Unit of each hart: Microchip's platform HAL,
   --  mpfs_hal/common/mss_beu_def.h (mpfs_hal 2.3.110): MSS_BUS_ERROR_UNIT_H0
   --  16#0170_0000#, one block of 16#1000# per hart; BEU_Type: CAUSE 16#00#,
   --  VALUE 16#08#, ENABLE 16#10#, PLIC_INT 16#18#, ACCRUED 16#20#,
   --  LOCAL_INT 16#28#, each 64 bits; BEU_event_cause 5 is
   --  BEU_EVENT_TILELINK_BUS_ERROR (the enable bits are 2 ** cause). The
   --  PLIC sources are E51_BUS_ERROR_UNIT (182) to U54_4_BUS_ERROR_UNIT
   --  (186) (svd/additions/interrupts.yaml), pending bits 22 .. 26 of the
   --  pending word 5 (PLIC + 16#1000# + 4 * 5).
   Beu_Base   : constant U64 := 16#0170_0000#;
   Beu_Cause  : constant U64 := 16#00#;
   Beu_Value  : constant U64 := 16#08#;
   Beu_Enable : constant U64 := 16#10#;
   Beu_Plic   : constant U64 := 16#18#;
   Beu_Accr   : constant U64 := 16#20#;
   Beu_Local  : constant U64 := 16#28#;
   Bus_Error  : constant U64 := 2 ** 5;
   Plic_Pend5 : constant U64 := 16#0C00_1014#;

   Load  : constant U64 := 0;
   Store : constant U64 := 1;

   Page : constant U64 := 4096;
   UP   : constant U64 :=
     U64 (System.Storage_Elements.To_Integer (User_Page'Address));

   --  What the last access did: 0 (answered) or the mcause; Read the value.
   Result : U64;
   Read   : U64;

   Beu         : U64;
   Beu_Present : Boolean := False;
   Has_Hi      : Boolean;

   function Mip return U64;

   function Mip return U64 is
      V : U64;
   begin
      System.Machine_Code.Asm
        ("csrr %0, mip", Outputs => U64'Asm_Output ("=r", V),
         Volatile => True);
      return V;
   end Mip;

   procedure Show (What : String; V : U64; Width : Positive := 8);

   procedure Show (What : String; V : U64; Width : Positive := 8) is
   begin
      Put ("  info: ");
      Put (What);
      Put (" = ");
      Put_Hex (V, Width);
      Put_Line ("");
   end Show;

   --  A word of a register outside the APB windows (BEU, PLIC) in M mode,
   --  without a line: Result says whether it answered.
   function Peek (Addr : U64) return U64;

   function Peek (Addr : U64) return U64 is
   begin
      Result := Try (Load, Addr, 0, 0);
      return (if Result = 0 then Value else 0);
   end Peek;

   function Peek64 (Addr : U64) return U64;

   function Peek64 (Addr : U64) return U64 is
      Low  : constant U64 := Peek (Addr);
      High : constant U64 := Peek (Addr + 4);
   begin
      return Low or High * 2 ** 32;
   end Peek64;

   procedure Poke (Addr, Data : U64);

   procedure Poke (Addr, Data : U64) is
   begin
      Result := Try (Store, Addr, 0, Data);
      if Result = 0 then
         Result := Try (Store, Addr + 4, 0, 0);
      end if;
   end Poke;

   --  The PLIC pending bits of the bus error sources 182 .. 186 (bit 0 is
   --  the E51's).
   function Beu_Pending return U64 is (Peek (Plic_Pend5) / 2 ** 22 mod 32);

   --  One line after an access in the wrong window: what the Bus Error Unit
   --  of the hart recorded, mip and the PLIC pending bits; then the record
   --  of the Bus Error Unit is cleared for the next access.
   procedure Report_Errors (Name, What : String);

   procedure Report_Errors (Name, What : String) is
   begin
      Put ("  info: errors after ");
      Put (Name);
      Put (", ");
      Put (What);
      Put (": mip ");
      Put_Hex (Mip, 4);
      Put (", plic pending 182..186 ");
      Put_Hex (Beu_Pending, 2);
      if Beu_Present then
         Put (", beu cause ");
         Put_Hex (Peek64 (Beu + Beu_Cause), 2);
         Put (" value ");
         Put_Hex (Peek64 (Beu + Beu_Value), 16);
         Put (" accrued ");
         Put_Hex (Peek64 (Beu + Beu_Accr), 2);
         Poke (Beu + Beu_Cause, 0);
         Poke (Beu + Beu_Value, 0);
         Poke (Beu + Beu_Accr, 0);
      else
         Put (", beu absent");
      end if;
      Put_Line ("");
   end Report_Errors;

   --  One access, announced by a "next:" line and reported with its outcome.
   procedure Access_At (Name, What : String; Op, Addr : U64; User : Boolean;
                        Data : U64 := 0);

   procedure Access_At (Name, What : String; Op, Addr : U64; User : Boolean;
                        Data : U64 := 0) is
   begin
      Put ("  info: next: ");
      Put (Name);
      Put (", ");
      Put_Line (What);
      Result := Try (Op, Addr, (if User then 1 else 0), Data);
      Read := (if Result = 0 and then Op = Load then Value else 0);
      Put ("  info: ");
      Put (Name);
      Put (", ");
      Put (What);
      if Result = 0 then
         Put (": answers");
         if Op = Load then
            Put (", reads ");
            Put_Hex (Read, 8);
         end if;
      else
         Put (": access fault, mcause ");
         Put_Dec (Result);
      end if;
      Put_Line ("");
   end Access_At;

   --  An access in the wrong window: the access, whether it faulted (the
   --  TRM 3.8 expects an AXI error; reported, not checked), and the report
   --  of the errors.
   procedure Wrong (Name, What : String; Op, Addr : U64; Data : U64 := 0);

   procedure Wrong (Name, What : String; Op, Addr : U64; Data : U64 := 0) is
      Saved_Result : U64;
      Saved_Read   : U64;
   begin
      Access_At (Name, What, Op, Addr, False, Data);
      Saved_Result := Result;
      Saved_Read := Read;
      Put ("  info: ");
      Put (Name);
      Put (", ");
      Put (What);
      Put_Line (if Result = 0 then ": wrong window, fault no"
                else ": wrong window, fault yes");
      Report_Errors (Name, What);
      Result := Saved_Result;
      Read := Saved_Read;
   end Wrong;

   --  The separation of one register by the windows: Pattern written at
   --  Own and read back there (Holds); at Other a read must not return it
   --  (No_Read) and a write of Other_Pattern must not change it (No_Write).
   --  Mask selects the bits of the register (SR has 8). If the register
   --  does not answer at Own and there is no HI window (an emulator that
   --  does not model it), the checks are left out.
   procedure Separate_At (Name : String; Own, Other : U64;
                          Pattern, Other_Pattern, Mask : U64;
                          Holds, No_Read, No_Write : String);

   procedure Separate_At (Name : String; Own, Other : U64;
                          Pattern, Other_Pattern, Mask : U64;
                          Holds, No_Read, No_Write : String) is
   begin
      Access_At (Name, "write at its own address", Store, Own, False,
                 Pattern);
      if Result /= 0 and then not Has_Hi then
         Put ("  info: ");
         Put (Name);
         Put_Line (": not modelled here, left out");
         return;
      end if;
      Access_At (Name, "read at its own address", Load, Own, False);
      if Result /= 0 and then not Has_Hi then
         Put ("  info: ");
         Put (Name);
         Put_Line (": not modelled here, left out");
         return;
      end if;
      Test_Report.Check (Result = 0 and then (Read and Mask) = Pattern,
                         Holds);
      Wrong (Name, "read at the other address", Load, Other);
      Test_Report.Check (not (Result = 0 and then (Read and Mask) = Pattern),
                         No_Read);
      Wrong (Name, "write at the other address", Store, Other,
             Other_Pattern);
      Access_At (Name, "read at its own address after that", Load, Own,
                 False);
      Test_Report.Check (Result = 0 and then (Read and Mask) = Pattern,
                         No_Write);
   end Separate_At;

   Saved_Apb   : constant Word := Apbbus_CR;
   Saved_Ahb   : constant Word := Ahbapb_CR;
   Saved_En    : U64 := 0;
   Saved_Plic  : U64 := 0;
   Saved_Local : U64 := 0;
   N           : U64;
begin
   case Hart_Id is
      when 0 => Test_Report.Start ("apb_window_test_e51");
      when 2 => Test_Report.Start ("apb_window_test_u54h2");
      when 3 => Test_Report.Start ("apb_window_test_u54h3");
      when 4 => Test_Report.Start ("apb_window_test_u54h4");
      when others => Test_Report.Start ("apb_window_test_u54");
   end case;
   Test_Report.Info ("hart", Hart_Id);
   Show ("APBBUS_CR at start", U64 (Saved_Apb));
   Show ("AHBAPB_CR at start", U64 (Saved_Ahb));
   Show ("mip at start", Mip);
   Show ("plic pending 182..186 at start", Beu_Pending, 2);

   Clock_CR := Clock_CR or Blocks;
   Reset_CR := Reset_CR and not Blocks;

   --  0. Is there a HI window; the Bus Error Unit.
   Apbbus_CR := Saved_Apb or Hi_Uart3;
   Has_Hi := (Apbbus_CR and Hi_Uart3) /= 0;
   Apbbus_CR := Saved_Apb and not (Hi_Uart2 or Hi_Uart3 or Hi_Timers);
   if not Has_Hi then
      Put_Line ("  info: APBBUS_CR does not hold the bit of MMUART3: no HI "
                & "window here, the HI cases are left out");
   end if;

   Beu := Beu_Base + Hart_Id * 16#1000#;
   Show ("beu address", Beu);
   Show ("beu cause at start", Peek64 (Beu + Beu_Cause), 16);
   if Result /= 0 then
      Put ("  info: beu absent: its cause register faults, mcause ");
      Put_Dec (Result);
      Put_Line ("");
   else
      Beu_Present := True;
      Show ("beu value at start", Peek64 (Beu + Beu_Value), 16);
      Saved_En := Peek64 (Beu + Beu_Enable);
      Show ("beu enable at start", Saved_En, 16);
      Saved_Plic := Peek64 (Beu + Beu_Plic);
      Show ("beu plic_interrupt at start", Saved_Plic, 16);
      Show ("beu accrued at start", Peek64 (Beu + Beu_Accr), 16);
      Saved_Local := Peek64 (Beu + Beu_Local);
      Show ("beu local_interrupt at start", Saved_Local, 16);
      Poke (Beu + Beu_Local, 0);
      Poke (Beu + Beu_Enable, Bus_Error);
      Poke (Beu + Beu_Plic, Bus_Error);
      Poke (Beu + Beu_Cause, 0);
      Poke (Beu + Beu_Value, 0);
      Poke (Beu + Beu_Accr, 0);
      Show ("beu enable after writing the TileLink bus error bit",
            Peek64 (Beu + Beu_Enable), 16);
      Show ("beu plic_interrupt after writing it",
            Peek64 (Beu + Beu_Plic), 16);
      if (Peek64 (Beu + Beu_Enable) and Bus_Error) = 0 then
         Put_Line ("  info: beu enable does not hold the write: the bus "
                   & "error unit is not modelled here, its lines say "
                   & "nothing");
      end if;
   end if;

   --  1. All in LO.
   Separate_At
     ("MMUART3 in LO, SR", LO + Uart3 + SR, HI + Uart3 + SR,
      16#A5#, 16#5A#, 16#FF#,
      "MMUART3 in LO: SR at the LO address holds the write",
      "MMUART3 in LO: a read at the HI address does not return SR",
      "MMUART3 in LO: a write at the HI address does not change SR");
   Separate_At
     ("TIMER in LO, TIM1LOADVAL", LO + Timer + Loadval,
      HI + Timer + Loadval, 16#1234_5678#, 16#8765_4321#, 16#FFFF_FFFF#,
      "TIMER in LO: TIM1LOADVAL at the LO address holds the write",
      "TIMER in LO: a read at the HI address does not return TIM1LOADVAL",
      "TIMER in LO: a write at the HI address does not change TIM1LOADVAL");
   Separate_At
     ("RTC in LO, COMPARE_LOWER", LO + Rtc + Compare, HI + Rtc + Compare,
      16#1F2E_3D4C#, 16#4C3D_2E1F#, 16#FFFF_FFFF#,
      "RTC in LO: COMPARE_LOWER at the LO address holds the write",
      "RTC in LO: a read at the HI address does not return COMPARE_LOWER",
      "RTC in LO: a write at the HI address does not change COMPARE_LOWER");

   if Has_Hi then
      --  2. MMUART3 in HI, MMUART2 left in LO.
      Apbbus_CR := Apbbus_CR or Hi_Uart3;
      Show ("APBBUS_CR with MMUART3 in HI", U64 (Apbbus_CR));
      Ahbapb_CR := Saved_Ahb and not Posted;
      Show ("AHBAPB_CR, posted mode off", U64 (Ahbapb_CR));
      Separate_At
        ("MMUART3 in HI, posted off, SR", HI + Uart3 + SR, LO + Uart3 + SR,
         16#5A#, 16#3C#, 16#FF#,
         "MMUART3 in HI: SR at the HI address holds the write",
         "MMUART3 in HI: a read at the LO address does not return SR",
         "MMUART3 in HI: a write at the LO address, posted mode off, does "
         & "not change SR");
      Ahbapb_CR := Saved_Ahb or Posted;
      Show ("AHBAPB_CR, posted mode on", U64 (Ahbapb_CR));
      Wrong ("MMUART3 in HI, posted on, SR", "write at the LO address",
             Store, LO + Uart3 + SR, 16#C3#);
      Access_At ("MMUART3 in HI, posted on, SR", "read at the HI address",
                 Load, HI + Uart3 + SR, False);
      Test_Report.Check
        (Result = 0 and then Read mod 256 = 16#5A#,
         "MMUART3 in HI: a write at the LO address, posted mode on, does "
         & "not change SR");
      Ahbapb_CR := Saved_Ahb;
      Separate_At
        ("MMUART2 in LO with MMUART3 in HI, SR", LO + Uart2 + SR,
         HI + Uart2 + SR, 16#96#, 16#69#, 16#FF#,
         "MMUART2 in LO: SR at the LO address holds the write",
         "MMUART2 in LO: a read at the HI address does not return SR",
         "MMUART2 in LO: a write at the HI address does not change SR");

      --  3. RTC and TIMER in HI.
      Apbbus_CR := Apbbus_CR or Hi_Timers;
      Show ("APBBUS_CR with RTC and TIMER in HI", U64 (Apbbus_CR));
      Separate_At
        ("TIMER in HI, TIM1LOADVAL", HI + Timer + Loadval,
         LO + Timer + Loadval, 16#0BAD_F00D#, 16#F00D_0BAD#, 16#FFFF_FFFF#,
         "TIMER in HI: TIM1LOADVAL at 0x2812_5004 holds the write",
         "TIMER in HI: a read at the LO address does not return "
         & "TIM1LOADVAL",
         "TIMER in HI: a write at the LO address does not change "
         & "TIM1LOADVAL");
      Separate_At
        ("RTC in HI, COMPARE_LOWER", HI + Rtc + Compare, LO + Rtc + Compare,
         16#2A3B_4C5D#, 16#5D4C_3B2A#, 16#FFFF_FFFF#,
         "RTC in HI: COMPARE_LOWER at 0x2812_4014 holds the write",
         "RTC in HI: a read at the LO address does not return COMPARE_LOWER",
         "RTC in HI: a write at the LO address does not change "
         & "COMPARE_LOWER");
      Apbbus_CR := Apbbus_CR and not Hi_Timers;
   end if;

   --  4. One PMP window per context, in U mode.
   Apbbus_CR := (Apbbus_CR and not Hi_Uart2)
     or (if Has_Hi then Hi_Uart3 else 0);
   N := Count (Mask);
   Test_Report.Check (N >= 2, "the hart has the two entries the test needs");
   if N >= 2 then
      Clear_All;
      Set (0, NAPOT or R or X, Napot_Addr (UP, Page));
      Set (1, NAPOT or R or W, Napot_Addr (LO + Block, Block_Sz));
      Access_At ("context A (LO window)", "U reads SR of MMUART2 at LO",
                 Load, LO + Uart2 + SR, True);
      Test_Report.Check (Result = 0,
                         "context A: U reaches its peripheral in LO");
      Access_At ("context A (LO window)", "U reads SR of MMUART3 at HI",
                 Load, HI + Uart3 + SR, True);
      Test_Report.Check
        (Result = 5, "context A: U faults (5) on the HI window of context B");
      Access_At ("context A (LO window)", "U writes SR of MMUART3 at HI",
                 Store, HI + Uart3 + SR, True, 16#11#);
      Test_Report.Check
        (Result = 7, "context A: U faults (7) on the HI window of context B");
      Access_At ("context A (LO window)", "U reads SR of MMUART3 at LO",
                 Load, LO + Uart3 + SR, True);

      Set (1, NAPOT or R or W, Napot_Addr (HI + Block, Block_Sz));
      if Has_Hi then
         Access_At ("context B (HI window)", "U reads SR of MMUART3 at HI",
                    Load, HI + Uart3 + SR, True);
         Test_Report.Check (Result = 0,
                            "context B: U reaches its peripheral in HI");
      end if;
      Access_At ("context B (HI window)", "U reads SR of MMUART2 at LO",
                 Load, LO + Uart2 + SR, True);
      Test_Report.Check
        (Result = 5, "context B: U faults (5) on the LO window of context A");
      Access_At ("context B (HI window)", "U writes SR of MMUART2 at LO",
                 Store, LO + Uart2 + SR, True, 16#22#);
      Test_Report.Check
        (Result = 7, "context B: U faults (7) on the LO window of context A");
      Access_At ("context B (HI window)", "U reads SR of MMUART2 at HI",
                 Load, HI + Uart2 + SR, True);
      Clear_All;
   end if;

   --  5. Back as it was.
   Apbbus_CR := Saved_Apb;
   Ahbapb_CR := Saved_Ahb;
   if Beu_Present then
      Poke (Beu + Beu_Enable, Saved_En);
      Poke (Beu + Beu_Plic, Saved_Plic);
      Poke (Beu + Beu_Local, Saved_Local);
      Poke (Beu + Beu_Cause, 0);
      Poke (Beu + Beu_Value, 0);
      Poke (Beu + Beu_Accr, 0);
   end if;
   Test_Report.Finish;
end Apb_Window_Test;
