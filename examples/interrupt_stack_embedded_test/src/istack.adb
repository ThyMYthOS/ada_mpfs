--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);
--  The light-tasking profile has no exception propagation, so a check that
--  could fail would be a warning (an error here); the code is exact without

with System.Machine_Code;
with System.Storage_Elements;

package body Istack is

   use System.Storage_Elements;

   Stack_Start : constant Character
     with Import, Convention => C, External_Name => "__interrupt_stack_start";
   Stack_End   : constant Character
     with Import, Convention => C, External_Name => "__interrupt_stack_end";

   Pattern : constant Interfaces.Unsigned_64 := 16#A5A5_A5A5_A5A5_A5A5#;

   type Words is array (Natural range <>) of Interfaces.Unsigned_64
     with Volatile_Components;

   ----------
   -- Size --
   ----------

   function Size return Natural is
     (Natural (To_Integer (Stack_End'Address)
               - To_Integer (Stack_Start'Address)));

   Count : constant Natural :=
     (if Size > Unpainted then (Size - Unpainted) / 8 else 0);
   --  The words that are painted

   pragma Warnings (Off, "*alignment*");
   --  The address is that of the start of the stack plus a multiple of 16
   Area : Words (0 .. Count - 1)
     with Import,
          Address => Stack_Start'Address + Storage_Offset (Unpainted);
   pragma Warnings (On, "*alignment*");

   -------------
   -- Instret --
   -------------

   function Instret return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      System.Machine_Code.Asm
        ("csrr %0, minstret",
         Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Instret;

   -----------
   -- Paint --
   -----------

   procedure Paint is
   begin
      for I in Area'Range loop
         Area (I) := Pattern;
      end loop;
   end Paint;

   ----------
   -- Peak --
   ----------

   function Peak return Natural is
      use type Interfaces.Unsigned_64;
   begin
      for I in Area'Range loop
         if Area (I) /= Pattern then
            return Size - Unpainted - 8 * I;
         end if;
      end loop;
      return 0;
   end Peak;

   Reached_Below : Boolean := False with Volatile;

   -------------
   -- Overrun --
   -------------

   procedure Overrun is
      Frame : Storage_Array (1 .. Storage_Offset (Size)) with Volatile;
      --  On the stack: its size is not static

      Offset : constant Storage_Offset := Stack_Start'Address - Frame'Address;
      --  Where the lowest byte of the stack is in Frame; negative if the
      --  frame starts above it, which it cannot do: it is as large as the
      --  stack and the stack pointer is inside the stack
   begin
      Reached_Below := Offset > 0;
      if Offset in 0 .. Frame'Length - 8 then
         declare
            Word : Interfaces.Unsigned_64
              with Volatile, Import, Address => Frame'Address + Offset;
         begin
            Word := 0;
         end;
      end if;
   end Overrun;

   ------------
   -- Overran --
   ------------

   function Overran return Boolean is (Reached_Below);

   -------------------
   -- Clobber_Guard --
   -------------------

   procedure Clobber_Guard is
      Word : Interfaces.Unsigned_64
        with Volatile, Import, Convention => C,
             External_Name => "__interrupt_stack_start";
   begin
      Word := 0;
   end Clobber_Guard;

end Istack;
