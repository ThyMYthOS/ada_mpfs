--  SPDX-FileCopyrightText: 2020-2021 AdaCore
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes riscv/mpfs/s-bbripl.adb @ 09e7cd6
--  (GPL-3.0-or-later WITH GCC-exception-3.1); rewritten: the context comes
--  from mhartid, the registers from the PAC, every access is 32 bits wide.
--
--  The PAC has one set of registers per context under its own name
--  (ENABLE_H3_M, THRESHOLD_H3_M, ...). The context of the executing hart is
--  not known at compile time, so the registers of a context are the PAC types
--  at "address of the registers of context 0 plus context times the distance
--  of the registers of context 1": base and stride are the addresses of the
--  PAC components, so the SVD stays the only source of the layout.
--  No aggregate is assigned to a register or to an array of registers: such an
--  assignment may be compiled into 64-bit stores, which the PLIC does not
--  accept (a disassembly check, tools/check_plic_stores.py, keeps it so).

with Interfaces; use Interfaces;

with System.Storage_Elements; use System.Storage_Elements;

with System.BB.CPU_Specific;
with System.BB.Hart;

with MPFS_Registers;
with MPFS_Registers.PLIC;

package body System.BB.RISCV_PLIC is

   use type CPU_Specific.Register_Word;

   package Regs renames MPFS_Registers.PLIC;

   subtype Word is MPFS_Registers.UInt32;
   use type Word;
   --  The registers of the PLIC are 32 bits wide

   subtype Priority_Type is MPFS_Registers.UInt3;
   --  Width of a source priority and of a threshold: three bits

   pragma Compile_Time_Error
     (Regs.ENABLE_H0_M_Registers'Size /= 32 * 6
      or else Regs.ENABLE_H0_M_Registers'Length /= 6,
      "PLIC enable block is not six 32-bit words");

   pragma Compile_Time_Error
     (Regs.THRESHOLD_H0_M_Register'Size /= 32
      or else Word'Size /= 32,
      "PLIC registers are not 32 bits wide");

   ------------------------
   -- Addresses (of PAC) --
   ------------------------

   function Context_Address
     (Hart   : Natural;
      First  : System.Address;
      Second : System.Address) return System.Address;
   pragma Inline (Context_Address);
   --  The register of the M mode context of a hart, given the same register
   --  of context 0 and of context 1 (First and Second)

   function Context_Address
     (Hart   : Natural;
      First  : System.Address;
      Second : System.Address) return System.Address
   is
   begin
      return To_Address
        (To_Integer (First)
         + Integer_Address (Context_Of (Hart))
           * (To_Integer (Second) - To_Integer (First)));
   end Context_Address;

   function Enable_Address (Hart : Natural) return System.Address
   is (Context_Address
         (Hart,
          Regs.PLIC_Periph.ENABLE_H0_M'Address,
          Regs.PLIC_Periph.ENABLE_H1_M'Address));

   function Threshold_Address (Hart : Natural) return System.Address
   is (Context_Address
         (Hart,
          Regs.PLIC_Periph.THRESHOLD_H0_M'Address,
          Regs.PLIC_Periph.THRESHOLD_H1_M'Address));

   function Claim_Address (Hart : Natural) return System.Address
   is (Context_Address
         (Hart,
          Regs.PLIC_Periph.CLAIM_COMPLETE_H0_M'Address,
          Regs.PLIC_Periph.CLAIM_COMPLETE_H1_M'Address));

   Claimed_Table : array (BBI.Any_Interrupt_ID) of Boolean := (others => False)
     with Ghost;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
      Hart : constant Natural := System.BB.Hart.Id;

      Enables : Regs.ENABLE_H0_M_Registers
        with Volatile, Import, Address => Enable_Address (Hart);

      Control : Regs.THRESHOLD_H0_M_Register
        with Import, Address => Threshold_Address (Hart);

      Claim_Complete : Word
        with Volatile, Import, Address => Claim_Address (Hart);

      Number : Word;
   begin
      --  Mask everything for this context first: no source can interrupt the
      --  hart while its enables are rewritten.
      Control.THRESHOLD := Priority_Type'Last;

      --  Disable all interrupts for this hart: one 32-bit store per word
      for Index in Enables'Range loop
         Enables (Index) := 0;
      end loop;

      --  Complete a claim that is still open (a restart does not reset the
      --  PLIC). The enables are clear, so this claims nothing new: it can
      --  only return the id left from before, or 0.
      for Attempt in 0 .. Natural (BBI.Interrupt_ID'Last) loop
         pragma Unreferenced (Attempt);
         Number := Claim_Complete;
         exit when Number = 0;
         Claim_Complete := Number;
      end loop;

      Control.THRESHOLD := 0;
   end Initialize;

   -------------
   -- Pending --
   -------------

   function Pending return Boolean is
   begin
      return (CPU_Specific.Mip and CPU_Specific.Mip_MEIP) /= 0;
   end Pending;

   ------------
   -- Enable --
   ------------

   procedure Enable (Interrupt : BBI.Interrupt_ID) is
      Enables : Regs.ENABLE_H0_M_Registers
        with Volatile, Import,
             Address => Enable_Address (System.BB.Hart.Id);

      Reg_Id : constant Natural := Natural (Interrupt) / 32;
      Int_Id : constant Natural := Natural (Interrupt) mod 32;
   begin
      Enables (Reg_Id) :=
        Enables (Reg_Id) or Word (Shift_Left (Unsigned_32'(1), Int_Id));
   end Enable;

   -------------
   -- Claimed --
   -------------

   function Claimed (Interrupt : BBI.Interrupt_ID) return Boolean
   is (Claimed_Table (Interrupt));

   ------------
   --  Claim --
   ------------

   function Claim return BBI.Any_Interrupt_ID is

      Claim_Complete : Word
        with Volatile, Import,
             Address => Claim_Address (System.BB.Hart.Id);

      Number : constant Unsigned_32 := Unsigned_32 (Claim_Complete);

      Id : BBI.Any_Interrupt_ID;
   begin

      if Number
           not in
         Unsigned_32 (BBI.Interrupt_ID'First) ..
        Unsigned_32 (BBI.Interrupt_ID'Last)
      then
         Id := BBI.No_Interrupt;
      else
         Id := BBI.Interrupt_ID (Number);
      end if;

      Claimed_Table (Id) := True;
      return Id;
   end Claim;

   --------------
   -- Complete --
   --------------

   procedure Complete (Interrupt : BBI.Interrupt_ID) is
      Claim_Complete : Word
        with Volatile, Import,
             Address => Claim_Address (System.BB.Hart.Id);
   begin

      --  Writing to the CLAIM register to signal completion
      Claim_Complete := Word (Interrupt);

      Claimed_Table (Interrupt) := False;
   end Complete;

   ----------------------------
   -- Set_Priority_Threshold --
   ----------------------------

   procedure Set_Priority_Threshold (Priority : Integer) is
      Control : Regs.THRESHOLD_H0_M_Register
        with Import, Address => Threshold_Address (System.BB.Hart.Id);

      Int_Priority : constant Integer :=
        Priority - Interrupt_Priority'First + 1;

   begin
      if Int_Priority > Integer (Priority_Type'Last) then
         Control.THRESHOLD := Priority_Type'Last;
      elsif Int_Priority < Integer (Priority_Type'First) then
         Control.THRESHOLD := Priority_Type'First;
      else
         Control.THRESHOLD := Priority_Type (Int_Priority);
      end if;
   end Set_Priority_Threshold;

   ---------------
   -- Threshold --
   ---------------

   function Threshold return Integer is
      Control : Regs.THRESHOLD_H0_M_Register
        with Import, Address => Threshold_Address (System.BB.Hart.Id);
   begin
      return Integer (Control.THRESHOLD);
   end Threshold;

   ------------------
   -- Set_Priority --
   ------------------

   procedure Set_Priority
     (Interrupt : System.BB.Interrupts.Interrupt_ID;
      Prio      : Interrupt_Priority)
   is
      Int_Prio : constant Natural :=
        Natural (Prio) - Natural (Interrupt_Priority'First) + 1;
      --  On the PLIC, priority zero is reserved to mean "never interrupt"
   begin
      --  PRIORITY (I) is the register of source I + 1: the array of the PAC
      --  starts at offset 4, the register of source 0 does not exist
      Regs.PLIC_Periph.PRIORITY (Natural (Interrupt) - 1).PRIORITY :=
        Priority_Type (Int_Prio);
   end Set_Priority;

   ---------------------------
   -- Priority_Of_Interrupt --
   ---------------------------

   function Priority_Of_Interrupt
     (Interrupt : System.BB.Interrupts.Interrupt_ID)
     return System.Any_Priority
   is
   begin
      return Natural (Regs.PLIC_Periph.PRIORITY (Natural (Interrupt) - 1)
                      .PRIORITY) + Interrupt_Priority'First - 1;
   end Priority_Of_Interrupt;

end System.BB.RISCV_PLIC;
