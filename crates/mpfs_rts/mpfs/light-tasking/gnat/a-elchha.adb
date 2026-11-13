--  SPDX-FileCopyrightText: 2003-2025 Free Software Foundation, Inc.
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes
--  gnat_rts_sources/include/rts-sources/light/a-elchha.adb @ 09e7cd6
--  (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC: the
--  handler first checks the guard word of the interrupt stack and, if a trap or
--  an interrupt overran the stack, ends with the message "interrupt stack
--  overflow" and nothing else (issue #91, crates/mpfs_rts/README.md). The rest
--  is the upstream handler.

with Ada.Unchecked_Conversion;
with System.Machine_Reset;

with GNAT.IO; use GNAT.IO;
--  We rely on GNAT packages for the output. Usually, Ada predefined units
--  cannot depends on GNAT units, as the user could use the GNAT hierarchy.
--  However, this implementation of Last_Chance_Handler is a default one, that
--  could be redefined by the user.

procedure Ada.Exceptions.Last_Chance_Handler
  (Msg : System.Address; Line : Integer)
is
   procedure Put (Str : System.Address);
   --  Put for a nul-terminated string (a C string)

   ---------
   -- Put --
   ---------

   procedure Put (Str : System.Address) is
      type C_String_Ptr is access String (1 .. Positive'Last);
      function To_C_String_Ptr is new Ada.Unchecked_Conversion
        (System.Address, C_String_Ptr);

      Msg_Str : constant C_String_Ptr := To_C_String_Ptr (Str);

   begin
      for J in Msg_Str'Range loop
         exit when Msg_Str (J) = Character'Val (0);
         Put (Msg_Str (J));
      end loop;
   end Put;

   use type System.Address;

   --  The guard word of the interrupt stack (issue #91, trap_handler.S): the
   --  lowest 8 bytes of the stack hold their own address, and a program that
   --  overran the stack has overwritten them. An image without an interrupt
   --  stack has none (start = end). Read with no other call: the stack is what
   --  is in doubt.

   Guard_Word : System.Address
     with Import, Volatile, Convention => C,
          External_Name => "__interrupt_stack_start";
   Stack_End  : constant Character
     with Import, Convention => C, External_Name => "__interrupt_stack_end";

   Overflowed : constant Boolean :=
     Stack_End'Address /= Guard_Word'Address
     and then Guard_Word /= Guard_Word'Address;

begin
   if Overflowed then
      --  The exception that brought us here, if any, is not to be trusted:
      --  report the cause that matters and stop (no restart of the partition)

      Put_Line ("In last chance handler");
      Put_Line ("interrupt stack overflow");
      System.Machine_Reset.Stop;
   end if;

   Put_Line ("In last chance handler");

   if Line /= 0 then
      Put ("Predefined exception raised at ");
      Put (Msg);
      Put (':');
      Put (Line);
   else
      Put ("User defined exception, message: ");
      Put (Msg);
   end if;

   New_Line;
   Put_Line ("now suspending");

   --  Stop the program

   System.Machine_Reset.Stop;
end Ada.Exceptions.Last_Chance_Handler;
