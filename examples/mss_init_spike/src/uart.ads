--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A small driver of the two MMUARTs that the image uses (typed registers of
--  the PAC, MPFS_Registers.MMUART): MMUART2 is the console (115200 baud),
--  MMUART0 a second, write-only port (230400 baud). The runtime console is
--  not used: its divisor is a link symbol and the ports here have their own
--  rates.
--
--  Initialize releases the port (the clock first, then the reset, in SYSREG),
--  sets the divisor, 8N1 and the FIFOs, in the order of the runtime's own
--  console (crates/mpfs_rts/mpfs/gnat/s-textio.adb): LCR.DLAB, the divisor
--  latches, then LCR 8N1 with DLAB off, then FCR. The divisor is an integer:
--  the fractional baud rate of the MMUART (DFR, MM0.EFBR) exists, and is not
--  used, because it has not been tried on the board.

with Interfaces;

package Uart is

   type Port is (MMUART0, MMUART2);

   --  The clock of the MMUARTs after a reset, which the image does not
   --  change (no clock switch): 40 MHz (the CPU runs at 80 MHz, AHB and APB
   --  at half; divisor 22 gives the 115200 baud of the other examples). A
   --  limit: this holds as long as the CPU stays on the boot clock; the
   --  clock is not read from the XML.
   APB_Clock_Hz : constant := 40_000_000;

   --  The baud rate of an MMUART is Clock / (16 * Divisor). The divisor is
   --  the nearest integer: 22 for 115200 (the rate is 1.36 % below) and 11
   --  for 230400 (1.36 % below too).
   Console_Baud : constant := 115_200;
   Tick_Baud    : constant := 230_400;

   function Divisor_For (Clock_Hz : Positive; Baud : Positive) return Natural;

   procedure Initialize (Item : Port; Baud : Positive);

   function Tx_Ready (Item : Port) return Boolean;   --  LSR.THRE
   function Tx_Empty (Item : Port) return Boolean;   --  LSR.TEMT

   --  One byte into the transmitter; the caller has seen Tx_Ready.
   procedure Write (Item : Port; Byte : Character);

   --  IER.ETBEI: the interrupt "transmit holding register empty".
   procedure Enable_Tx_Interrupt (Item : Port);
   procedure Disable_Tx_Interrupt (Item : Port);

   --  The registers that say how the port is set up (read with LCR.DLAB for
   --  the divisor; only with the port idle).
   type State is record
      LCR : Interfaces.Unsigned_32;
      MCR : Interfaces.Unsigned_32;
      DLR : Natural;
      DMR : Natural;
   end record;

   function Read_State (Item : Port) return State;

end Uart;
