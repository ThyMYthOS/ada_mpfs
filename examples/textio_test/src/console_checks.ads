--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What the console of the runtime leaves in the registers of its MMUART,
--  compared with the link symbols that describe it (__mpfs_console_base,
--  _dlr, _dfr). The checks read the registers through the PAC and report with
--  Test_Report; they leave the port as they found it.

with System;

package Console_Checks is

   Base_0 : constant := 16#2000_0000#;
   Base_1 : constant := 16#2010_0000#;
   Base_2 : constant := 16#2010_2000#;
   Base_3 : constant := 16#2010_4000#;
   Base_4 : constant := 16#2010_6000#;
   --  The LO bases of MMUART0 to MMUART4 (MPFS_Registers.MMUARTn_LO_Base)

   function Link_Base return System.Address;
   function Link_DLR return Natural;
   function Link_DFR return Natural;
   --  The values of the link symbols __mpfs_console_base, _dlr and _dfr

   procedure Start (Name : String);
   --  Test_Report.Start (Name & "_e51") on hart 0, Name & "_u54" otherwise:
   --  the name of the row of tests/qemu/tests.list

   procedure Programmed (Expected_Base : Long_Long_Integer);
   --  Initialize ran with __mpfs_console_init = 1: the base is the expected
   --  one, the line format is 8N1 with LCR.DLAB clear, the integer divisor
   --  and DFR are those of the link symbols, the fractional baud rate mode is
   --  on exactly when DFR is not 0, the FIFOs are on.

   procedure Port_Test (Name : String; Expected_Base : Long_Long_Integer);
   --  The whole test of a console on a port other than MMUART0: Start,
   --  Programmed and Test_Report.Finish

   procedure Loopback;
   --  Put and Get through the MMUART in loopback mode (MCR.LOOP): every byte
   --  put comes back through Get, and Is_Rx_Ready is false when nothing is
   --  waiting. The port is out of loopback mode when this returns.

end Console_Checks;
