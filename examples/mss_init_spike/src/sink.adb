--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  System.BB.Interrupts is the interface of the runtime to the PLIC

with Ada.Interrupts.Names;
with Interfaces;
with System.BB.Interrupts;

with Log;
with Mss_Init;
with Uart;

package body Sink is

   use type Interfaces.Unsigned_64;

   Port : constant Uart.Port := Uart.MMUART2;

   --  The PLIC source of MMUART2 and its priority (level 3: above the
   --  threshold 0 of the main program, in the middle of the seven levels)
   Source   : constant System.BB.Interrupts.Interrupt_ID :=
     System.BB.Interrupts.Interrupt_ID (Ada.Interrupts.Names.MMUART2);
   Priority : constant System.Interrupt_Priority :=
     System.Interrupt_Priority'First + 2;

   FIFO_Depth : constant := 16;

   Opened : Boolean := False;
   pragma Atomic (Opened);

   Calls : Natural := 0;           --  written by the handler only
   pragma Atomic (Calls);

   procedure Handler (Id : System.BB.Interrupts.Interrupt_ID);

   procedure Handler (Id : System.BB.Interrupts.Interrupt_ID) is
      pragma Unreferenced (Id);
      Sent : Natural := 0;
      Item : Character;
      Got  : Boolean;
   begin
      Calls := Calls + 1;
      while Sent < FIFO_Depth loop
         Log.Get (Item, Got);
         exit when not Got;
         Uart.Write (Port, Item);
         Sent := Sent + 1;
      end loop;
      if Log.Pending = 0 then
         Uart.Disable_Tx_Interrupt (Port);
      end if;
   end Handler;

   procedure Open is
   begin
      Uart.Initialize (Port, Uart.Console_Baud);
      System.BB.Interrupts.Attach_Handler (Handler'Access, Source, Priority);
      Opened := True;
      Uart.Enable_Tx_Interrupt (Port);
   end Open;

   function Is_Open return Boolean is (Opened);

   procedure Kick is
   begin
      if Opened then
         Uart.Enable_Tx_Interrupt (Port);
      end if;
   end Kick;

   function Flush (Budget_Microseconds : Natural) return Boolean is
      Start : constant Interfaces.Unsigned_64 := Mss_Init.Cycles;
      Span  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Budget_Microseconds)
        * Mss_Init.Cycles_Per_Microsecond;
   begin
      loop
         if Log.Pending = 0 and then Uart.Tx_Empty (Port) then
            return True;
         end if;
         exit when Mss_Init.Cycles - Start >= Span;
      end loop;
      return False;
   end Flush;

   function Interrupts return Natural is (Calls);

end Sink;
