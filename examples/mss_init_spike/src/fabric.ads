--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The interrupts that come from the FPGA fabric: the PLIC sources F2M_0 to
--  F2M_63 (IDs 118 to 181, "fabric to MSS"; svd/additions/interrupts.yaml,
--  Ada.Interrupts.Names of the runtime). The MSS peripherals' own sources, the
--  bus error units and the GPIO direct lines (13 to 50, which
--  GPIO_INTERRUPT_FAB_CR switches between the pads and the fabric) are not in
--  it.
--
--  One plain procedure serves all of them, attached with
--  System.BB.Interrupts.Attach_Handler at the lowest PLIC level (the runtime
--  maps System.Interrupt_Priority'First to level 1 and the handler gets the
--  source as its parameter). It counts per source, remembers the mtime of the
--  first occurrence and then MASKS the source in the PLIC (clears its enable
--  bit for hart 0, machine mode, in the PAC's PLIC registers; the runtime has
--  no public disable): a level-sensitive line that stays asserted would
--  otherwise fire again after every claim and complete. The mask is one-shot,
--  the source stays masked, so no interrupt storm is possible and every
--  source that fired is reported once, with its count at the time of masking
--  (1 unless the runtime delivered a second one before the mask took effect).
--
--  Attach is called after the hardware is set up, not during the sequence:
--  nothing from outside may disturb it. An interrupt that is pending at that
--  moment (the PLIC powers up with random pending bits: source 119 was seen
--  pending after some power-ups) fires right after the attach and is
--  reported like any other.
--
--  The fabric lines reach the PLIC without a register of SYSREG being
--  written: FAB_INTEN_U54_n and FAB_INTEN_MISC route fabric lines (and the
--  Ethernet MACs) to the local interrupts of the U54 harts directly, and
--  GPIO_INTERRUPT_FAB_CR the GPIO lines; the F2M sources of the PLIC need
--  none. The image writes none of them.
--
--  The counters are atomic and the handler is their only writer, except
--  Record_Occurrence called by a test seam (the QEMU image, which has no
--  fabric lines: Fabric_Seam).

with Ada.Interrupts.Names;
with Interfaces;
with System.BB.Interrupts;

package Fabric is

   subtype Source is System.BB.Interrupts.Interrupt_ID
     range Integer (Ada.Interrupts.Names.F2M_0)
           .. Integer (Ada.Interrupts.Names.F2M_63);

   Source_Count : constant := Integer (Ada.Interrupts.Names.F2M_63)
     - Integer (Ada.Interrupts.Names.F2M_0) + 1;

   --  Position of a source in the table (0 .. 63: F2M_<index>)
   subtype Index is Natural range 0 .. Source_Count - 1;

   function Index_Of (Id : Source) return Index
     is (Id - Source'First);
   function Id_Of (Item : Index) return Source
     is (Source'First + Item);

   --  Attaches the handler to every source of the range.
   procedure Attach;

   --  What the handler does for Id: count, remember the mtime of the first
   --  occurrence, mask the source.
   procedure Record_Occurrence (Id : Source);

   function Occurred (Item : Index) return Boolean;
   function Count_Of (Item : Index) return Natural;
   function First_Mtime (Item : Index) return Interfaces.Unsigned_64;
   function Masked (Item : Index) return Boolean;

   --  "F2M_1(119) x2 @0x00046e1f masked" in Buffer (1 .. Last).
   subtype Description is String (1 .. 48);
   procedure Describe
     (Item : Index; Buffer : out Description; Last : out Natural);

end Fabric;
