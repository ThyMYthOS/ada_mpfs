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
--    __mpfs_console_init   1: Initialize brings the port up: on a primary
--                          image it clocks and releases the MMUART first
--                          (SYSREG), then it programs the divisor, the
--                          fractional divisor, the line format and the
--                          FIFOs; 0: whoever set the MSS up has done all of
--                          it, Initialize only records that the service is
--                          ready and no register is written but those of Put,
--                          Get and the status reads (SYSREG never).
--    __mpfs_console_dlr    the integer baud rate divisor (16 bits)
--    __mpfs_console_dfr    the fractional divisor in 1/64 (0 .. 63); the
--                          fractional baud rate mode is on for a value other
--                          than 0
--
--  __mpfs_boot_role (start.S reads it too) decides who owns SYSREG: a
--  primary image (1) sets the MSS up itself, so with __mpfs_console_init = 1
--  Initialize sets the clock bit and clears the reset bit of the MMUART of
--  the console (SUBBLK_CLOCK_CR and SOFT_RESET_CR, one 32-bit read-modify-write
--  each, before any other register of the port is written). The image runs on
--  one hart and the others are parked, so the read-modify-write is not shared.
--  It does not matter whether the MMUART is clocked already (a primary image
--  loaded by JTAG after ./x hw initialize), and Initialize may run twice. A
--  secondary image (0) expects an MSS that is set up (by mpfs_boot or, in the
--  lab, by the stand-ins of ./x hw) and never touches SYSREG; neither does an
--  image without a console or with __mpfs_console_init = 0.
--
--  @req RTS-026
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
with MPFS_Registers.SYSREG;

package body System.Text_IO is

   package SSE renames System.Storage_Elements;
   use SSE;
   package MMUART renames MPFS_Registers.MMUART;
   package SYSREG renames MPFS_Registers.SYSREG;

   type Word is mod 2 ** 64;

   --  The values of the link symbols. They are read by assembly (lui and
   --  addi, as start.S does) and not through the address of an imported
   --  object: the compiler knows that the address of an object is not null
   --  and would fold the test for "no console".

   function Link_Base return Word with Inline_Always;
   function Link_Init return Word with Inline_Always;
   function Link_DLR  return Word with Inline_Always;
   function Link_DFR  return Word with Inline_Always;
   function Link_Role return Word with Inline_Always;

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

   function Link_Role return Word is
      Value : Word;
   begin
      System.Machine_Code.Asm
        ("lui  %0, %%hi(__mpfs_boot_role)" & ASCII.LF & ASCII.HT &
         "addi %0, %0, %%lo(__mpfs_boot_role)",
         Outputs  => Word'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Link_Role;

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

   ------------------
   -- Release_Port --
   ------------------

   procedure Release_Port (Base : Word);

   --  Clock and reset of the MMUART at Base (MMUART0 at 0x2000_0000, then
   --  MMUART1 .. MMUART4 at 0x2010_0000 + 0x2000 * (n - 1); bit n of the
   --  MMUART field of both registers). A base that is none of them is left
   --  alone. The clock goes first: a peripheral without clock must not be
   --  released from its reset.

   procedure Release_Port (Base : Word) is
      First : constant Word :=
        Word (SSE.To_Integer (MPFS_Registers.MMUART1_LO_Base));
      Step  : constant Word :=
        Word (SSE.To_Integer (MPFS_Registers.MMUART2_LO_Base)) - First;
      Index : Natural;
   begin
      if Base = Word (SSE.To_Integer (MPFS_Registers.MMUART0_LO_Base)) then
         Index := 0;
      elsif Base >= First and then (Base - First) mod Step = 0
        and then (Base - First) / Step <= 3
      then
         Index := Natural ((Base - First) / Step) + 1;
      else
         return;
      end if;

      declare
         Clock : SYSREG.SUBBLK_CLOCK_CR_Register :=
           SYSREG.SYSREG_Periph.SUBBLK_CLOCK_CR;
      begin
         Clock.MMUART.Arr (Index) := True;
         SYSREG.SYSREG_Periph.SUBBLK_CLOCK_CR := Clock;
      end;

      declare
         Reset : SYSREG.SOFT_RESET_CR_Register :=
           SYSREG.SYSREG_Periph.SOFT_RESET_CR;
      begin
         Reset.MMUART.Arr (Index) := False;
         SYSREG.SYSREG_Periph.SOFT_RESET_CR := Reset;
      end;
   end Release_Port;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      if Present and then Link_Init = 1 then
         if Link_Role = 1 then
            Release_Port (Link_Base);
         end if;

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
