--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

with System;

with MPFS_Registers;
with MPFS_Registers.MMUART;
with MPFS_Registers.SYSREG;

package body Uart is

   package MMUART renames MPFS_Registers.MMUART;
   package SYSREG renames MPFS_Registers.SYSREG;

   --  The MMUART field of SYSREG.SUBBLK_CLOCK_CR and SOFT_RESET_CR: bit n of
   --  the field is MMUART n.
   function Index (Item : Port) return Natural is
     (case Item is when MMUART0 => 0, when MMUART2 => 2);

   function Base (Item : Port) return System.Address is
     (case Item is
         when MMUART0 => MMUART.MMUART0_LO_Periph'Address,
         when MMUART2 => MMUART.MMUART2_LO_Periph'Address);

   function Raw (Register : System.Address) return Interfaces.Unsigned_32;

   function Raw (Register : System.Address) return Interfaces.Unsigned_32 is
      Word_At : Interfaces.Unsigned_32
        with Volatile, Import, Address => Register;
   begin
      return Word_At;
   end Raw;

   function Divisor_For (Clock_Hz : Positive; Baud : Positive) return Natural
   is
     ((Clock_Hz + 8 * Baud) / (16 * Baud));

   procedure Initialize (Item : Port; Baud : Positive) is
      Port_At : MMUART.MMUART_Peripheral
        with Import, Address => Base (Item);

      --  The divisor latches and the FIFO control register share the
      --  addresses of the data port, of IER and of IIR (LCR.DLAB, and the
      --  write of +8)
      Latch_LSB : MMUART.DLR_Register
        with Import, Address => Port_At.RBR'Address;
      Latch_MSB : MMUART.DMR_Register
        with Import, Address => Port_At.IER'Address;
      FIFO      : MMUART.FCR_Register
        with Import, Address => Port_At.IIR'Address;

      Div : constant Natural := Divisor_For (APB_Clock_Hz, Baud);
   begin
      declare
         Clock : SYSREG.SUBBLK_CLOCK_CR_Register :=
           SYSREG.SYSREG_Periph.SUBBLK_CLOCK_CR;
      begin
         Clock.MMUART.Arr (Index (Item)) := True;
         SYSREG.SYSREG_Periph.SUBBLK_CLOCK_CR := Clock;
      end;
      declare
         Reset : SYSREG.SOFT_RESET_CR_Register :=
           SYSREG.SYSREG_Periph.SOFT_RESET_CR;
      begin
         Reset.MMUART.Arr (Index (Item)) := False;
         SYSREG.SYSREG_Periph.SOFT_RESET_CR := Reset;
      end;

      Port_At.LCR := (WLS => 2#11#, DLAB => True, others => <>);
      Latch_LSB := (DLR => MPFS_Registers.UInt8 (Div mod 256), others => <>);
      Latch_MSB := (DMR => MPFS_Registers.UInt8 (Div / 256), others => <>);
      Port_At.LCR := (WLS => 2#11#, DLAB => False, others => <>);
      FIFO := (ENABLE_TX_RX_FIFO  => True,
               CLEAR_RX_FIFO      => True,
               CLEAR_TX_FIFO      => True,
               ENABLE_TXRDY_RXRDY => False,
               RX_TRIG            => 0,
               others             => <>);
   end Initialize;

   function Tx_Ready (Item : Port) return Boolean is
      Port_At : MMUART.MMUART_Peripheral
        with Import, Address => Base (Item);
   begin
      return Port_At.LSR.THRE;
   end Tx_Ready;

   function Tx_Empty (Item : Port) return Boolean is
      Port_At : MMUART.MMUART_Peripheral
        with Import, Address => Base (Item);
   begin
      return Port_At.LSR.TEMT;
   end Tx_Empty;

   procedure Write (Item : Port; Byte : Character) is
      Port_At : MMUART.MMUART_Peripheral
        with Import, Address => Base (Item);
      Data    : MMUART.THR_Register
        with Import, Address => Port_At.RBR'Address;
   begin
      Data := (THR => MPFS_Registers.UInt8 (Character'Pos (Byte)),
               others => <>);
   end Write;

   procedure Enable_Tx_Interrupt (Item : Port) is
      Port_At : MMUART.MMUART_Peripheral
        with Import, Address => Base (Item);
   begin
      Port_At.IER := (ETBEI => True, others => <>);
   end Enable_Tx_Interrupt;

   procedure Disable_Tx_Interrupt (Item : Port) is
      Port_At : MMUART.MMUART_Peripheral
        with Import, Address => Base (Item);
   begin
      Port_At.IER := (ETBEI => False, others => <>);
   end Disable_Tx_Interrupt;

   function Read_State (Item : Port) return State is
      Port_At : MMUART.MMUART_Peripheral
        with Import, Address => Base (Item);
      Low     : MMUART.DLR_Register
        with Import, Address => Port_At.RBR'Address;
      High    : MMUART.DMR_Register
        with Import, Address => Port_At.IER'Address;
      Saved   : constant MMUART.LCR_Register := Port_At.LCR;
      Latch   : MMUART.LCR_Register := Saved;
      Result  : State;
   begin
      Latch.DLAB := True;
      Port_At.LCR := Latch;
      Result.DLR := Natural (Low.DLR);
      Result.DMR := Natural (High.DMR);
      Port_At.LCR := Saved;
      Result.LCR := Raw (Port_At.LCR'Address);
      Result.MCR := Raw (Port_At.MCR'Address);
      return Result;
   end Read_State;

end Uart;
