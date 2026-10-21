--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What the check is for: an aggregate assigned to an array of PLIC registers.
--  The compiler writes it with 64-bit stores (sd) at -O2, which the PLIC does
--  not accept. check_plic_stores.py must FAIL on the object of this file.

with MPFS_Registers.PLIC;

procedure Aggregate is
begin
   MPFS_Registers.PLIC.PLIC_Periph.ENABLE_H1_M := (others => 0);
end Aggregate;
