--  SPDX-FileCopyrightText: 2012-2020 AdaCore
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes src/s-bbbopa__polarfiresoc.ads
--  @ 09e7cd6 (GPL-3.0-or-later WITH GCC-exception-3.1); modified for the
--  hart-indexed PLIC and CLINT of PolarFire SoC.
--
--  Board parameters. No hart appears here: the PLIC context and the mtimecmp
--  of the executing hart come from mhartid at run time (System.BB.Hart). The
--  bases of the PLIC and of the CLINT, and the layout of their registers, are
--  those of the PAC (MPFS_Registers.PLIC_Base, MPFS_Registers.CLINT_Base and
--  the packages MPFS_Registers.PLIC and MPFS_Registers.CLINT), so that the
--  SVD is their only source. The first CPU id for the debugger,
--  __gnat_gdb_cpu_first_id, is a constant of the linker script (the lowest
--  hart of __mpfs_harts_mask), not of this package.

package System.BB.Board_Parameters is
   pragma No_Elaboration_Code_All;
   pragma Pure;

   --------------------
   -- Hardware clock --
   --------------------

   Clock_Scale : constant := 1;
   --  Scaling factor for clock frequency. This is used to provide a clock
   --  frequency that results in a definition of Time_Unit less than 20
   --  microseconds (as Ada RM D.8 (30) requires).

   Decrementer_Frequency : constant Positive := 1_000_000;
   --  Frequency of mtime, the RTC clock of the CLINT (1 MHz)

   Clock_Frequency : constant Positive := Decrementer_Frequency * Clock_Scale;
   --  Scaled clock frequency

   -------------
   -- Console --
   -------------

   UART_Base_Address : constant := 16#2000_0000#;
   --  MMUART0 (LO). The console moves to link symbols with the console work
   --  package (P1.9).

end System.BB.Board_Parameters;
