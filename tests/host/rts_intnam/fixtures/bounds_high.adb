--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  187 is one above the last PLIC source.

with Ada.Interrupts;

procedure Bounds_High is
   Id : constant Ada.Interrupts.Interrupt_ID := 187;
   pragma Unreferenced (Id);
begin
   null;
end Bounds_High;
