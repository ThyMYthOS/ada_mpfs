--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The CSRs of the hart that the test reads: the counters, the pending
--  interrupts and the pc of the interrupted instruction.

with Interfaces;

package CSR is

   function Mcycle return Interfaces.Unsigned_64;
   function Minstret return Interfaces.Unsigned_64;
   function Mip return Interfaces.Unsigned_64;
   function Mepc return Interfaces.Unsigned_64;

   MTIP : constant Interfaces.Unsigned_64 := 128;
   --  mip.MTIP: the machine timer interrupt is pending (mtime >= mtimecmp)

   pragma Inline (Mcycle, Minstret, Mip, Mepc);

end CSR;
