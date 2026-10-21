--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  interrupt_test: the PLIC and the CLINT of the runtime are those of the hart
--  that runs the image (E51 = hart 0, U54 = hart 1 .. 4), not of hart 1.
--
--    - the PLIC context of a hart is 0 for hart 0 and 2n-1 for hart n, and
--      the addresses the runtime computes for it are the PAC registers of
--      that context, for all five harts;
--    - an Attach_Handler handler (the received-data interrupt of MMUART0,
--      source 90) gets its interrupt on THIS hart: console.in feeds bytes to
--      the UART, the PLIC context of the hart delivers them, the handler takes
--      them out of RBR. The enable bit of the source is set in the context of
--      this hart and in no other; the priority of the source is the ceiling;
--    - inside the protected object the PLIC threshold of this hart is the
--      ceiling, outside it is 0;
--    - the CLINT: msip of this hart reads set and clear (Clear_MSIP), mtime
--      runs, and the runtime has not touched the mtimecmp of another hart
--      (QEMU: 0 after reset; the same holds for the enables and the
--      thresholds of the other contexts).
--
--  Reported with Test_Report as interrupt_test_e51, interrupt_test_u54 (hart
--  1) or interrupt_test_u54h2 .. 4, the rows of tests/qemu/tests.list.

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  The test is about the units of the runtime: System.BB.RISCV_PLIC and
--  System.BB.RISCV_CLINT

with Ada.Real_Time; use Ada.Real_Time;

with Bare_Console;
with Interfaces;
with PLIC_View;
with Test_Report;
with UART_Rx;

with System.BB.RISCV_CLINT;
with System.BB.RISCV_PLIC;

with MPFS_Registers.CLINT;
with MPFS_Registers.PLIC;

procedure Interrupt_Test is

   package CLINT renames System.BB.RISCV_CLINT;
   package PLIC renames System.BB.RISCV_PLIC;

   use type Interfaces.Unsigned_32;
   use type System.Address;
   use type CLINT.Counter;

   Hart : constant Natural := Natural (Bare_Console.Hart_Id);

   Expected : constant String := "plic" & ASCII.LF;
   --  The bytes of console.in

   Word  : constant Natural := Natural (UART_Rx.IRQ) / 32;
   Bit   : constant Interfaces.Unsigned_32 :=
     2 ** (Natural (UART_Rx.IRQ) mod 32);
   --  The place of the source in the enable block

   procedure Start;

   procedure Start is
   begin
      case Hart is
         when 0      => Test_Report.Start ("interrupt_test_e51");
         when 1      => Test_Report.Start ("interrupt_test_u54");
         when 2      => Test_Report.Start ("interrupt_test_u54h2");
         when 3      => Test_Report.Start ("interrupt_test_u54h3");
         when others => Test_Report.Start ("interrupt_test_u54h4");
      end case;
   end Start;

   function Enabled (Id : PLIC_View.Hart_Id) return Boolean
   is ((Interfaces.Unsigned_32 (PLIC_View.Enable_Word (Id, Word)) and Bit)
       /= 0);

   Right_Context, Right_Addresses, Others_Quiet, Mtimecmp_Quiet : Boolean;
   Before : CLINT.Counter;
   Waited : Natural := 0;
   Same   : Boolean := True;

begin
   Start;
   Test_Report.Info ("hart", Bare_Console.Hart_Id);

   --  The PLIC context of every hart, and its registers.
   Right_Context :=
     PLIC.Context_Of (0) = 0 and PLIC.Context_Of (1) = 1
     and PLIC.Context_Of (2) = 3 and PLIC.Context_Of (3) = 5
     and PLIC.Context_Of (4) = 7;
   Test_Report.Check
     (Right_Context, "the M mode context is 0, 1, 3, 5, 7 for harts 0 to 4");
   Right_Addresses := True;
   for H in PLIC_View.Hart_Id loop
      Right_Addresses := Right_Addresses
        and PLIC.Enable_Address (H) = PLIC_View.Enable_Address (H)
        and PLIC.Threshold_Address (H) = PLIC_View.Threshold_Address (H)
        and PLIC.Claim_Address (H) = PLIC_View.Claim_Address (H);
   end loop;
   Test_Report.Check
     (Right_Addresses,
      "enable, threshold and claim addresses of every hart are the PAC's");

   --  Receive: Attach_Handler, the context of this hart, the ceiling.
   Test_Report.Check
     (Enabled (Hart) = True,
      "the source is enabled in the PLIC context of this hart");
   Others_Quiet := True;
   for H in PLIC_View.Hart_Id loop
      if H /= Hart and then Enabled (H) then
         Others_Quiet := False;
      end if;
   end loop;
   Test_Report.Check
     (Others_Quiet, "and in no other context (QEMU: clear after reset)");
   Test_Report.Check
     (Natural (MPFS_Registers.PLIC.PLIC_Periph.PRIORITY
                 (Natural (UART_Rx.IRQ) - 1).PRIORITY)
        = Natural (UART_Rx.Ceiling) - Natural (System.Interrupt_Priority'First)
          + 1,
      "the priority of the source is the ceiling of its handler");
   Test_Report.Check
     (PLIC_View.Threshold (Hart) = 0,
      "outside a protected object the threshold of this hart is 0");
   Test_Report.Check
     (UART_Rx.Receiver.Threshold_Inside
        = Natural (UART_Rx.Ceiling) - Natural (System.Interrupt_Priority'First)
          + 1,
      "inside it the threshold is the ceiling");

   UART_Rx.Receiver.Enable_Interrupt;
   while UART_Rx.Receiver.Count < Expected'Length and Waited < 1000 loop
      delay until Clock + Milliseconds (2);
      Waited := Waited + 1;
   end loop;
   Test_Report.Info
     ("handler calls", Bare_Console.U64 (UART_Rx.Receiver.Calls));
   Test_Report.Check
     (UART_Rx.Receiver.Count = Expected'Length,
      "the handler took in as many bytes as console.in has");
   for I in Expected'Range loop
      if UART_Rx.Receiver.Item (I) /= Expected (I) then
         Same := False;
      end if;
   end loop;
   Test_Report.Check (Same, "the bytes are those of console.in, in order");
   Test_Report.Check
     ((Interfaces.Unsigned_32
         (MPFS_Registers.PLIC.PLIC_Periph.PENDING (Word)) and Bit) = 0,
      "the source is not pending after the handler");

   --  The CLINT.
   MPFS_Registers.CLINT.CLINT_Periph.MSIP (Hart) :=
     (MSIP => True, Reserved_1_31 => 0);
   Test_Report.Check (CLINT.MSIP (Hart), "msip of this hart reads set");
   CLINT.Clear_MSIP (Hart);
   Test_Report.Check
     (not CLINT.MSIP (Hart), "and clear after Clear_MSIP");
   Before := CLINT.Mtime;
   delay until Clock + Milliseconds (2);
   Test_Report.Check (CLINT.Mtime > Before, "mtime runs");
   Mtimecmp_Quiet := True;
   for H in CLINT.Hart_Id loop
      if H /= Hart and then CLINT.Mtimecmp (H) /= 0 then
         Mtimecmp_Quiet := False;
      end if;
   end loop;
   Test_Report.Check
     (Mtimecmp_Quiet,
      "the mtimecmp of the other harts is untouched (QEMU: 0 after reset)");

   Test_Report.Finish;
end Interrupt_Test;
