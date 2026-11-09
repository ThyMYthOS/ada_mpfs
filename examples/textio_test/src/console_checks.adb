--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  The tests are about System.Text_IO, a unit of the runtime

with System.Storage_Elements; use System.Storage_Elements;
with System.Text_IO;

with MPFS_Registers;
with MPFS_Registers.MMUART;

with Bare_Console;
with Test_Report;

package body Console_Checks is

   use type System.Address;
   use type Bare_Console.U64;
   use type MPFS_Registers.UInt2;

   package MMUART renames MPFS_Registers.MMUART;

   --  The absolute symbols of the partition data: their address is their
   --  value.

   Sym_Base : Character
     with Import, Convention => C, External_Name => "__mpfs_console_base";
   Sym_DLR  : Character
     with Import, Convention => C, External_Name => "__mpfs_console_dlr";
   Sym_DFR  : Character
     with Import, Convention => C, External_Name => "__mpfs_console_dfr";

   function Link_Base return System.Address is (Sym_Base'Address);

   function Link_DLR return Natural is
     (Natural (To_Integer (Sym_DLR'Address)));

   function Link_DFR return Natural is
     (Natural (To_Integer (Sym_DFR'Address)));

   ---------------
   -- Hart_Base --
   ---------------

   function Hart_Base return Long_Long_Integer is
   begin
      case Bare_Console.Hart_Id is
         when 1      => return Base_1;
         when 2      => return Base_2;
         when 3      => return Base_3;
         when 4      => return Base_4;
         when others => return Base_0;
      end case;
   end Hart_Base;

   -----------
   -- Start --
   -----------

   procedure Start (Name : String) is
   begin
      if Bare_Console.Hart_Id = 0 then
         Test_Report.Start (Name & "_e51");
      else
         Test_Report.Start (Name & "_u54");
      end if;
   end Start;

   ----------------
   -- Programmed --
   ----------------

   procedure Programmed (Expected_Base : Long_Long_Integer) is
      Base : constant System.Address := Link_Base;

      Port : MMUART.MMUART_Peripheral with Import, Address => Base;

      --  The latches of the divisor at the 16550 offsets, valid with
      --  LCR.DLAB set

      Latch_LSB : MMUART.DLR_Register with Import, Address => Base;
      Latch_MSB : MMUART.DMR_Register
        with Import, Address => Base + Storage_Offset'(4);

      Line      : constant MMUART.LCR_Register := Port.LCR;
      Fraction  : constant MPFS_Registers.UInt6 := Port.DFR.DFR;
      Fractional : constant Boolean := Port.MM0.EFBR;
      FIFOs     : constant MPFS_Registers.UInt2 := Port.IIR.MODE;

      LSB, MSB : MPFS_Registers.UInt8;
   begin
      Port.LCR := (Line with delta DLAB => True);
      LSB := Latch_LSB.DLR;
      MSB := Latch_MSB.DMR;
      Port.LCR := Line;

      Test_Report.Check
        (To_Integer (Base) = Integer_Address (Expected_Base),
         "the console base is the MMUART the test expects");
      Test_Report.Check
        (Line.WLS = 2#11# and then not Line.STB and then not Line.PEN
         and then not Line.SB and then not Line.DLAB,
         "the line format is 8N1 and DLAB is clear");
      Test_Report.Check
        (Natural (MSB) * 256 + Natural (LSB) = Link_DLR,
         "the integer divisor is __mpfs_console_dlr");
      Test_Report.Check
        (Natural (Fraction) = Link_DFR,
         "DFR is __mpfs_console_dfr");
      Test_Report.Check
        (Fractional = (Link_DFR /= 0),
         "the fractional baud rate mode is on exactly for a fraction");
      Test_Report.Check
        (FIFOs = 2#11#,
         "the FIFOs are enabled");
   end Programmed;

   --------------
   -- Loopback --
   --------------

   procedure Port_Test (Name : String; Expected_Base : Long_Long_Integer) is
   begin
      Start (Name);
      Programmed (Expected_Base);
      Test_Report.Finish;
   end Port_Test;

   procedure Loopback is
      Port : MMUART.MMUART_Peripheral with Import, Address => Link_Base;

      Sent     : constant String :=
        "Ada" & Character'Val (0) & Character'Val (255);
      Got      : String (Sent'Range) := [others => '?'];
      Count    : Natural := 0;
      Stale    : Boolean := False;
      Idle     : Boolean;
      Empty    : Boolean;

      Spin_Limit : constant := 2_000_000;

      function Wait_Rx return Boolean;
      function Wait_Tx return Boolean;

      function Wait_Rx return Boolean is
      begin
         for Spin in 1 .. Spin_Limit loop
            if System.Text_IO.Is_Rx_Ready then
               return True;
            end if;
         end loop;
         return False;
      end Wait_Rx;

      function Wait_Tx return Boolean is
      begin
         for Spin in 1 .. Spin_Limit loop
            if System.Text_IO.Is_Tx_Ready then
               return True;
            end if;
         end loop;
         return False;
      end Wait_Tx;

      Tx_Ok : Boolean := True;
   begin
      --  Nothing of the output so far may still be waiting in the receiver
      --  (a real MMUART echoes nothing, but be sure), then loop back.

      while System.Text_IO.Is_Rx_Ready loop
         Stale := True;
         Got (Got'First) := System.Text_IO.Get;
      end loop;

      Port.MCR := (LOOP_k => True, others => <>);

      Idle := not System.Text_IO.Is_Rx_Ready;

      for I in Sent'Range loop
         if Wait_Tx then
            System.Text_IO.Put (Sent (I));
            if Wait_Rx then
               Got (I) := System.Text_IO.Get;
               Count := Count + 1;
            end if;
         else
            Tx_Ok := False;
         end if;
      end loop;

      Empty := not System.Text_IO.Is_Rx_Ready;

      Port.MCR := (others => <>);

      Test_Report.Check
        (Idle and then not Stale,
         "Is_Rx_Ready is false when nothing was received");
      Test_Report.Check
        (Tx_Ok, "Is_Tx_Ready becomes true again after every Put");
      Test_Report.Check
        (Count = Sent'Length and then Got = Sent,
         "every byte put in loopback mode comes back through Get");
      Test_Report.Check
        (Empty, "Is_Rx_Ready is false again after the last Get");
   end Loopback;

end Console_Checks;
