--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The received-data interrupt of MMUART0 as a protected handler
--  (Attach_Handler). Under QEMU the bytes come from console.in, on the board
--  from the MMUART in loopback (a later work package).

with Ada.Interrupts;
with System;

package UART_Rx is

   IRQ : constant Ada.Interrupts.Interrupt_ID := 90;
   --  PLIC source of MMUART0 (svd/additions/interrupts.yaml)

   Ceiling : constant System.Interrupt_Priority :=
     System.Interrupt_Priority'First + 2;
   --  PLIC priority 3 (a priority is Ceiling - Interrupt_Priority'First + 1)

   Capacity : constant := 16;
   type Bytes is array (1 .. Capacity) of Character;

   protected Receiver with Interrupt_Priority => Ceiling is

      procedure Enable_Interrupt;
      --  Set IER.ERBFI of MMUART0

      function Calls return Natural;
      --  How often the handler ran

      function Count return Natural;
      --  How many bytes it took out of RBR

      function Item (Index : Positive) return Character;

      function Threshold_Inside return Natural;
      --  The PLIC threshold of the hart that calls, read while it is inside
      --  the protected object: the ceiling, as a PLIC priority

   private
      procedure Handler with Attach_Handler => IRQ;

      Called : Natural := 0;
      Taken  : Natural := 0;
      Data   : Bytes := [others => ' '];
   end Receiver;

end UART_Rx;
