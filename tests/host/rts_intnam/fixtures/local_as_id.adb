--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A local interrupt number is not an Interrupt_ID.

with Ada.Interrupts;
with Ada.Interrupts.Names;

procedure Local_As_Id is
   Id : constant Ada.Interrupts.Interrupt_ID :=
     Ada.Interrupts.Names.Local.MAINTENANCE;
   pragma Unreferenced (Id);
begin
   null;
end Local_As_Id;
