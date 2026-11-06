--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Source 0 means "no interrupt" on the PLIC: it is below Interrupt_Range.

with Ada.Interrupts;

procedure Bounds_Zero is
   Id : constant Ada.Interrupts.Interrupt_ID := 0;
   pragma Unreferenced (Id);
begin
   null;
end Bounds_Zero;
