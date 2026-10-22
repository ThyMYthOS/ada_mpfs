--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  MMUART0 is a 16550-style UART: bit 5 of the line status register (LSR) says
--  that the transmit holding register (THR) can take a byte. QEMU ignores the
--  baud divisor and the line control, so there is nothing to initialise; on
--  hardware something else has to set the port up (clock, reset, divisor). In
--  boot mode 0 nothing does: run the image with `./x hw run --uart-standin`.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with System.Machine_Code;

package body Bare_Console is

   type Byte is mod 2 ** 8;

   Base : constant := 16#2000_0000#;

   THR : Byte
     with Volatile, Address => System'To_Address (Base + 16#00#);
   LSR : Byte
     with Volatile, Address => System'To_Address (Base + 16#14#);

   THRE : constant Byte := 2#0010_0000#;

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
      while (LSR and THRE) = 0 loop
         null;
      end loop;
      THR := Byte (Character'Pos (C));
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
