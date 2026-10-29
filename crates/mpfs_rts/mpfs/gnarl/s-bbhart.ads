--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  The id of the executing hart, read from the CSR mhartid at run time. The
--  port units of the board take their PLIC context and their mtimecmp from it:
--  no unit of the runtime names a hart.

package System.BB.Hart is
   pragma Preelaborate;

   function Id return Natural;
   pragma Inline (Id);
   --  E51 = 0, U54 = 1 .. 4

end System.BB.Hart;
