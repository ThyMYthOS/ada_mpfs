--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1

with System.BB.CPU_Specific;

package body System.BB.Hart is

   function Mhartid is new CPU_Specific.Read_CSR ("mhartid");

   --------
   -- Id --
   --------

   function Id return Natural is
   begin
      return Natural (Mhartid);
   end Id;

end System.BB.Hart;
