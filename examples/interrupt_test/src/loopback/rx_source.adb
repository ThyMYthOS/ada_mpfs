--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
with MPFS_Registers.MMUART;

package body Rx_Source is

   Port : MPFS_Registers.MMUART.MMUART_Peripheral
     renames MPFS_Registers.MMUART.MMUART0_LO_Periph;

   Tx : MPFS_Registers.MMUART.THR_Register
     with Import, Volatile, Address => Port'Address;
   --  THR is at the address of RBR; the PAC record has only RBR there

   Spin_Limit : constant := 2_000_000;

   procedure Wait_Transmitter_Empty;

   procedure Wait_Transmitter_Empty is
   begin
      for Spin in 1 .. Spin_Limit loop
         exit when Port.LSR.TEMT;
      end loop;
   end Wait_Transmitter_Empty;

   procedure Feed (Text : String) is
   begin
      --  The output so far is still in the transmitter: looped back, the
      --  rest of the line would arrive as received bytes.
      Wait_Transmitter_Empty;
      Port.MCR := (LOOP_k => True, others => <>);
      for C of Text loop
         for Spin in 1 .. Spin_Limit loop
            exit when Port.LSR.THRE;
         end loop;
         Tx := (THR => Character'Pos (C), others => <>);
      end loop;
   end Feed;

   procedure Finish is
   begin
      Wait_Transmitter_Empty;
      Port.MCR := (others => <>);
   end Finish;

end Rx_Source;
