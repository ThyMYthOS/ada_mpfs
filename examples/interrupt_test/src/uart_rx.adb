--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Bare_Console;
with PLIC_View;

with MPFS_Registers.MMUART;

package body UART_Rx is

   Port : MPFS_Registers.MMUART.MMUART_Peripheral
     renames MPFS_Registers.MMUART.MMUART0_LO_Periph;

   protected body Receiver is

      procedure Enable_Interrupt is
      begin
         Port.IER.ERBFI := True;
      end Enable_Interrupt;

      procedure Handler is
      begin
         Called := Called + 1;
         --  Take everything out of RBR: that is what lowers the interrupt
         --  line of the UART (level), and so the PLIC source.
         while Port.LSR.DR loop
            declare
               Value : constant Character :=
                 Character'Val (Natural (Port.RBR.RBR));
            begin
               if Taken < Capacity then
                  Taken := Taken + 1;
                  Data (Taken) := Value;
               end if;
            end;
         end loop;
      end Handler;

      function Calls return Natural is (Called);

      function Count return Natural is (Taken);

      function Item (Index : Positive) return Character is (Data (Index));

      function Threshold_Inside return Natural is
      begin
         return PLIC_View.Threshold
           (Natural (Bare_Console.Hart_Id));
      end Threshold_Inside;

   end Receiver;

end UART_Rx;
