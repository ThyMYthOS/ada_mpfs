--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  System.BB.Interrupts is the interface of the runtime to the PLIC

with MPFS_Registers;
with MPFS_Registers.PLIC;

with Mss_Init;
with MPFS_Registers.CLINT;

package body Fabric is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type MPFS_Registers.UInt32;

   Names_Are_Contiguous : constant Boolean := Source_Count = 64;
   pragma Compile_Time_Error
     (not Names_Are_Contiguous,
      "F2M_0 .. F2M_63 of Ada.Interrupts.Names are not 64 consecutive IDs");

   Counts : array (Index) of Interfaces.Unsigned_32 := [others => 0];
   pragma Atomic_Components (Counts);

   Times  : array (Index) of Interfaces.Unsigned_64 := [others => 0];
   pragma Atomic_Components (Times);

   Is_Masked : array (Index) of Boolean := [others => False];
   pragma Atomic_Components (Is_Masked);

   procedure Fabric_Interrupt (Id : System.BB.Interrupts.Interrupt_ID);
   procedure Mask (Id : Source);

   --  Clears the enable bit of the source for hart 0, machine mode: the PLIC
   --  then takes no claim for it, whatever the line does.
   procedure Mask (Id : Source) is
      Word : constant Natural := Id / 32;
      Bit  : constant MPFS_Registers.UInt32 := 2 ** (Id mod 32);
   begin
      MPFS_Registers.PLIC.PLIC_Periph.ENABLE_H0_M (Word) :=
        MPFS_Registers.PLIC.PLIC_Periph.ENABLE_H0_M (Word) and not Bit;
   end Mask;

   procedure Record_Occurrence (Id : Source) is
      Item : constant Index := Index_Of (Id);
   begin
      Counts (Item) := Counts (Item) + 1;
      if Counts (Item) = 1 then
         Times (Item) := Mss_Init.Read_64
           (MPFS_Registers.CLINT.CLINT_Periph.MTIME'Address);
      end if;
      Mask (Id);
      Is_Masked (Item) := True;
   end Record_Occurrence;

   procedure Fabric_Interrupt (Id : System.BB.Interrupts.Interrupt_ID) is
   begin
      if Id in Source then
         Record_Occurrence (Id);
      end if;
   end Fabric_Interrupt;

   procedure Attach is
   begin
      for Id in Source loop
         System.BB.Interrupts.Attach_Handler
           (Fabric_Interrupt'Access, Id, System.Interrupt_Priority'First);
      end loop;
   end Attach;

   function Occurred (Item : Index) return Boolean is (Counts (Item) > 0);
   function Count_Of (Item : Index) return Natural is
     (Natural (Counts (Item)));
   function First_Mtime (Item : Index) return Interfaces.Unsigned_64 is
     (Times (Item));
   function Masked (Item : Index) return Boolean is (Is_Masked (Item));

   procedure Describe
     (Item : Index; Buffer : out Description; Last : out Natural)
   is
      Digit : constant String := "0123456789abcdef";

      procedure Put (Text : String);
      procedure Put_Dec (Value : Natural);

      procedure Put (Text : String) is
      begin
         Buffer (Last + 1 .. Last + Text'Length) := Text;
         Last := Last + Text'Length;
      end Put;

      procedure Put_Dec (Value : Natural) is
         Pow : Natural := 1;
      begin
         while Value / Pow >= 10 loop
            Pow := Pow * 10;
         end loop;
         while Pow > 0 loop
            Put (Digit (Value / Pow mod 10 + 1 .. Value / Pow mod 10 + 1));
            Pow := Pow / 10;
         end loop;
      end Put_Dec;
   begin
      Buffer := [others => ' '];
      Last := 0;
      Put ("F2M_");
      Put_Dec (Item);
      Put ("(");
      Put_Dec (Id_Of (Item));
      Put (") x");
      Put_Dec (Count_Of (Item));
      Put (" @0x");
      for Nibble in reverse 0 .. 7 loop
         declare
            Value : constant Natural :=
              Natural (Interfaces.Shift_Right (First_Mtime (Item), 4 * Nibble)
                       mod 16);
         begin
            Put (Digit (Value + 1 .. Value + 1));
         end;
      end loop;
      if Masked (Item) then
         Put (" masked");
      end if;
   end Describe;

end Fabric;
