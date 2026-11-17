--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  MMUART0 is a 16550-style UART: bit 5 of the line status register (LSR) says
--  that the transmit holding register (THR) can take a byte. The registers are
--  accessed as 32-bit words, as the MMUART needs (the console of the runtime
--  does the same).
--
--  A primary image sets the MSS up itself, so the first output brings the port
--  up as System.Text_IO does for its console: it sets the clock bit and clears
--  the reset bit of MMUART0 in SYSREG, programs the divisor (22: 115200 baud
--  at the ~40 MHz APB clock of an MSS that nobody configured), the 8N1 format
--  and the FIFOs. Nothing else is needed on the board in boot mode 0, and the
--  steps are idempotent (an image loaded by JTAG after `./x hw initialize`
--  finds the port clocked). A secondary image (__mpfs_boot_role = 0) expects
--  an MSS that is set up (by mpfs_boot, or in the lab by `./x hw run
--  --uart-standin`) and writes no register but THR and LSR. QEMU ignores the
--  baud divisor and does not clock anything; it takes the writes.
--
--  @req RTS-026

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with System.Machine_Code;

package body Bare_Console is

   type Word is mod 2 ** 32;

   Base   : constant := 16#2000_0000#;
   SYSREG : constant := 16#2000_2000#;

   THR : Word with Volatile, Address => System'To_Address (Base + 16#00#);
   DMR : Word with Volatile, Address => System'To_Address (Base + 16#04#);
   FCR : Word with Volatile, Address => System'To_Address (Base + 16#08#);
   LCR : Word with Volatile, Address => System'To_Address (Base + 16#0C#);
   LSR : Word with Volatile, Address => System'To_Address (Base + 16#14#);
   DFR : Word with Volatile, Address => System'To_Address (Base + 16#3C#);

   Clock_CR : Word
     with Volatile, Address => System'To_Address (SYSREG + 16#84#);
   Reset_CR : Word
     with Volatile, Address => System'To_Address (SYSREG + 16#88#);

   MMUART0 : constant Word := 2 ** 5;  --  bit 5 of both SYSREG registers
   DR      : constant Word := 2#0000_0001#;  --  LSR: a byte was received
   THRE    : constant Word := 2#0010_0000#;

   --  The value of the link symbol __mpfs_boot_role, read by assembly (lui
   --  and addi, as start.S does): the compiler would fold the test on the
   --  address of an imported object.

   function Is_Primary return Boolean;

   function Is_Primary return Boolean is
      Role : U64;
   begin
      System.Machine_Code.Asm
        ("lui  %0, %%hi(__mpfs_boot_role)" & ASCII.LF & ASCII.HT &
         "addi %0, %0, %%lo(__mpfs_boot_role)",
         Outputs  => U64'Asm_Output ("=r", Role),
         Volatile => True);
      return Role = 1;
   end Is_Primary;

   Ready : Boolean := False;

   procedure Bring_Up;

   procedure Bring_Up is
   begin
      Ready := True;
      if Is_Primary then
         Clock_CR := Clock_CR or MMUART0;
         Reset_CR := Reset_CR and not MMUART0;

         LCR := 16#83#;       --  8N1, DLAB on
         THR := 22;           --  divisor latch, low byte (DLAB on)
         DMR := 0;
         DFR := 0;            --  no fractional divisor
         LCR := 16#03#;       --  DLAB off

         --  FIFOs on and emptied, unless a byte has been received already:
         --  enabling the FIFOs throws it away (a 16550 flushes both FIFOs
         --  when FCR.FIFOE changes), and a test whose input is there before
         --  its first output (QEMU's console.in) needs it.

         if (LSR and DR) = 0 then
            FCR := 16#07#;
         end if;
      end if;
   end Bring_Up;

   function Hart_Id return U64 is
      Id : U64;
   begin
      System.Machine_Code.Asm
        ("csrr %0, mhartid",
         Outputs  => U64'Asm_Output ("=r", Id),
         Volatile => True);
      return Id;
   end Hart_Id;

   procedure Put_Char (C : Character);

   procedure Put_Char (C : Character) is
   begin
      if not Ready then
         Bring_Up;
      end if;
      while (LSR and THRE) = 0 loop
         null;
      end loop;
      THR := Word (Character'Pos (C));
   end Put_Char;

   procedure Put (Text : String) is
   begin
      for C of Text loop
         Put_Char (C);
      end loop;
   end Put;

   procedure Put_Line (Text : String) is
   begin
      Put (Text);
      Put_Char (Character'Val (13));
      Put_Char (Character'Val (10));
   end Put_Line;

   Digit : constant String := "0123456789abcdef";

   procedure Put_Hex (Value : U64; Width : Positive) is
      Rest : U64 := Value;
      Text : String (1 .. 16);
   begin
      for I in reverse Text'Range loop
         Text (I) := Digit (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
      end loop;
      Put ("0x");
      Put (Text (17 - Width .. 16));
   end Put_Hex;

   procedure Put_Dec (Value : U64) is
      Rest : U64 := Value;
      Pow  : U64 := 1;
   begin
      while Rest / Pow >= 10 loop
         Pow := Pow * 10;
      end loop;
      while Pow > 0 loop
         Put_Char (Digit (Natural (Rest / Pow) + 1));
         Rest := Rest mod Pow;
         Pow := Pow / 10;
      end loop;
   end Put_Dec;

end Bare_Console;
