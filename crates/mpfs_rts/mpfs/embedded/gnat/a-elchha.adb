--  SPDX-FileCopyrightText: 2003-2025 Free Software Foundation, Inc.
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes
--  gnat_rts_sources/include/rts-sources/full/a-elchha.adb @ 09e7cd6
--  (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC: the
--  handler first checks the guard word of the interrupt stack and, if a trap or
--  an interrupt overran the stack, ends with the message "interrupt stack
--  overflow" and nothing else (issue #91, crates/mpfs_rts/README.md). The rest
--  is the upstream handler.
--
--  @req RTS-023

with System;
with System.Machine_Reset;

with System.IO;                use System.IO;
with GNAT.Debug_Utilities;     use GNAT.Debug_Utilities;

--  Default last chance handler for use with full run-time library on bare
--  board targets.

--  It dumps the exception identity and the non-symbolic traceback from the
--  point where the exception was triggered.

procedure Ada.Exceptions.Last_Chance_Handler (Except : Exception_Occurrence) is

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
   Put_Line ("Unhandled Ada Exception: " & Exception_Name (Except));
   Put_Line ("Message: " & Exception_Message (Except));
   Put_Line ("Call stack traceback locations:");

   --  Dump backtrace PC values

   for J in 1 .. Except.Num_Tracebacks loop
      Put (Image_C (Except.Tracebacks (J)));
      Put (" ");
   end loop;

   New_Line;

   --  Stop the machine

   System.Machine_Reset.Stop;

end Ada.Exceptions.Last_Chance_Handler;
