--  SPDX-FileCopyrightText: 1992-2020 Free Software Foundation, Inc.
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes src/s-textio__ns16550.adb
--  @ 09e7cd6 (GPL-3.0-or-later WITH GCC-exception-3.1); rewritten for the
--  MMUART of PolarFire SoC.
--
--  The console of the runtime: polled output and input on one MMUART. Which
--  one, and whether this package sets it up, is link-time data of the
--  partition (the absolute symbols below, written with --defsym); nothing of
--  it is in the library, so one runtime serves every console.
--
--    __mpfs_console_base   base address of the MMUART (MMUART0_LO_Base ..
--                          MMUART4_LO_Base of the PAC), or 0: no console.
--                          Put does nothing, Is_Tx_Ready is always true,
--                          Is_Rx_Ready never.
--    __mpfs_console_init   1: Initialize programs the port (divisor,
--                          fractional divisor, line format, FIFOs); 0: the
--                          boot stage has done it, Initialize only records
--                          that the service is ready and no register is
--                          written but those of Put, Get and the status
--                          reads.
--    __mpfs_console_dlr    the integer baud rate divisor (16 bits)
--    __mpfs_console_dfr    the fractional divisor in 1/64 (0 .. 63); the
--                          fractional baud rate mode is on for a value other
--                          than 0
--
--  The clock and the reset of the MMUART are not touched here: releasing
--  them is the work of the boot stage, whatever __mpfs_console_init says.
--
--  The registers are the types of the PAC (MPFS_Registers.MMUART). Where the
--  16550 layout and the alias addresses of the MMUART differ (the data port,
--  the divisor latches and the FIFO control register are at +0, +0 and +4
--  with LCR.DLAB, and +8; the PAC also lists them at +0x100, +0x80 / +0x84
--  and +0x108), the 16550 offsets are used: they exist on the board and in
--  QEMU, whose model has plain memory from +0x20 on.

with System.Machine_Code;
with System.Storage_Elements;

with MPFS_Registers.MMUART;

package body System.Text_IO is

   package SSE renames System.Storage_Elements;
   use SSE;
   package MMUART renames MPFS_Registers.MMUART;

   type Word is mod 2 ** 64;

   --  The values of the link symbols. They are read by assembly (lui and
   --  addi, as start.S does) and not through the address of an imported
   --  object: the compiler knows that the address of an object is not null
   --  and would fold the test for "no console".

   function Link_Base return Word with Inline_Always;
   function Link_Init return Word with Inline_Always;
   function Link_DLR  return Word with Inline_Always;
   function Link_DFR  return Word with Inline_Always;

   function Link_Base return Word is
      Value : Word;
   begin
      System.Machine_Code.Asm
        ("lui  %0, %%hi(__mpfs_console_base)" & ASCII.LF & ASCII.HT &
         "addi %0, %0, %%lo(__mpfs_console_base)",
         Outputs  => Word'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Link_Base;

   function Link_Init return Word is
      Value : Word;
   begin
      System.Machine_Code.Asm
        ("lui  %0, %%hi(__mpfs_console_init)" & ASCII.LF & ASCII.HT &
         "addi %0, %0, %%lo(__mpfs_console_init)",
         Outputs  => Word'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Link_Init;

   function Link_DLR return Word is
      Value : Word;
   begin
      System.Machine_Code.Asm
        ("lui  %0, %%hi(__mpfs_console_dlr)" & ASCII.LF & ASCII.HT &
         "addi %0, %0, %%lo(__mpfs_console_dlr)",
         Outputs  => Word'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Link_DLR;

   function Link_DFR return Word is
      Value : Word;
   begin
      System.Machine_Code.Asm
        ("lui  %0, %%hi(__mpfs_console_dfr)" & ASCII.LF & ASCII.HT &
         "addi %0, %0, %%lo(__mpfs_console_dfr)",
         Outputs  => Word'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Link_DFR;

   function Base_Address return System.Address is
     (SSE.To_Address (SSE.Integer_Address (Link_Base)))
   with Inline_Always;

   function Present return Boolean is (Link_Base /= 0)
   with Inline_Always;

   ---------
   -- Get --
   ---------

   function Get return Character is
   begin
      if not Present then
         return ASCII.NUL;
      end if;

      declare
         Port : MMUART.MMUART_Peripheral
           with Import, Address => Base_Address;
      begin
         return Character'Val (Port.RBR.RBR);
      end;
   end Get;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      if Present and then Link_Init = 1 then
         declare
            Base : constant System.Address := Base_Address;
            Port : MMUART.MMUART_Peripheral with Import, Address => Base;

            --  16550 offsets, valid with LCR.DLAB set

            Latch_LSB : MMUART.DLR_Register with Import, Address => Base;
            Latch_MSB : MMUART.DMR_Register
              with Import, Address => Base + Storage_Offset'(16#04#);

            --  Write-only at +8 (the read at +8 is IIR)

            FIFO : MMUART.FCR_Register
              with Import, Address => Base + Storage_Offset'(16#08#);

            DLR : constant Word := Link_DLR;
            DFR : constant Word := Link_DFR;
         begin
            --  Divisor latches: LCR.DLAB, the integer divisor, then the
            --  fractional divisor and its enable (MM0.EFBR; the other
            --  multi-mode bits stay as they are)

            Port.LCR := (WLS => 2#11#, DLAB => True, others => <>);
            Latch_LSB := (DLR => MPFS_Registers.UInt8 (DLR mod 256),
                          others => <>);
            Latch_MSB := (DMR => MPFS_Registers.UInt8 ((DLR / 256) mod 256),
                          others => <>);
            Port.DFR := (DFR => MPFS_Registers.UInt6 (DFR mod 64),
                         others => <>);
            Port.MM0.EFBR := DFR mod 64 /= 0;

            --  Format 8N1, DLAB off

            Port.LCR := (WLS => 2#11#, DLAB => False, others => <>);

            --  FIFOs on and emptied, the receive trigger at one byte

            FIFO := (ENABLE_TX_RX_FIFO  => True,
                     CLEAR_RX_FIFO      => True,
                     CLEAR_TX_FIFO      => True,
                     ENABLE_TXRDY_RXRDY => False,
                     RX_TRIG            => 0,
                     others             => <>);
         end;
      end if;

      Initialized := True;
   end Initialize;

   -----------------
   -- Is_Rx_Ready --
   -----------------

   function Is_Rx_Ready return Boolean is
   begin
      if not Present then
         return False;
      end if;

      declare
         Port : MMUART.MMUART_Peripheral
           with Import, Address => Base_Address;
      begin
         return Port.LSR.DR;
      end;
   end Is_Rx_Ready;

   -----------------
   -- Is_Tx_Ready --
   -----------------

   function Is_Tx_Ready return Boolean is
   begin
      if not Present then
         return True;
      end if;

      declare
         Port : MMUART.MMUART_Peripheral
           with Import, Address => Base_Address;
      begin
         return Port.LSR.THRE;
      end;
   end Is_Tx_Ready;

   ---------
   -- Put --
   ---------

   procedure Put (C : Character) is
   begin
      if Present then
         declare
            --  The data port, +0: one 32-bit store of the whole register,
            --  never a read-modify-write (a read at +0 takes a byte out of
            --  the receive FIFO)

            THR : MMUART.THR_Register with Import, Address => Base_Address;
         begin
            THR := (THR => MPFS_Registers.UInt8 (Character'Pos (C)),
                    others => <>);
         end;
      end if;
   end Put;

   ----------------------------
   -- Use_Cr_Lf_For_New_Line --
   ----------------------------

   function Use_Cr_Lf_For_New_Line return Boolean is
   begin
      return True;
   end Use_Cr_Lf_For_New_Line;

end System.Text_IO;
