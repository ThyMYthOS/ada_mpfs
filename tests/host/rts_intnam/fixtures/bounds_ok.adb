--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Control: the first and the last PLIC source are Interrupt_IDs, and so are the generated names and source 117
--  (reserved or spare in the TRM: no name, but inside Interrupt_Range).

with Ada.Interrupts;
with Ada.Interrupts.Names;

procedure Bounds_Ok is
   First : constant Ada.Interrupts.Interrupt_ID := 1;
   Last  : constant Ada.Interrupts.Interrupt_ID := 186;
   Spare : constant Ada.Interrupts.Interrupt_ID := 117;
   Named : constant Ada.Interrupts.Interrupt_ID :=
     Ada.Interrupts.Names.L2_METADATA_CORR;
   Local : constant Ada.Interrupts.Names.Local.Local_Interrupt :=
     Ada.Interrupts.Names.Local.MAINTENANCE;
   pragma Unreferenced (First, Last, Spare, Named, Local);
begin
   null;
end Bounds_Ok;
