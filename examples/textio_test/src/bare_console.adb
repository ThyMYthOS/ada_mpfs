--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The body of Bare_Console (the spec is that of examples/bare_hello) over the
--  console of the runtime, System.Text_IO, instead of a polled MMUART0 of its
--  own. Test_Report then reports on the console the runtime was linked with
--  (__mpfs_console_base) and the runtime sets that port up (or not:
--  __mpfs_console_init), which is the point of these images. The first output
--  calls System.Text_IO.Initialize, as GNAT.IO does.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  The tests are about System.Text_IO, a unit of the runtime

with System.Machine_Code;
with System.Text_IO;

package body Bare_Console is

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
      if not System.Text_IO.Initialized then
         System.Text_IO.Initialize;
      end if;
      while not System.Text_IO.Is_Tx_Ready loop
         null;
      end loop;
      System.Text_IO.Put (C);
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
