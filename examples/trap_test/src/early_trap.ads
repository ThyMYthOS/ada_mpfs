--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Elaborating this package executes an illegal instruction while the image
--  is still in its start-up: the runtime's trap stub
--  (crates/mpfs_rts/mpfs/gnat/start.S) is the trap handler, and it records
--  mcause, mepc, mtval and mhartid before it jumps to Hook, the test seam of
--  the stub. Hook checks the record and reports with Test_Report.

with System;

package Early_Trap is
   pragma Elaborate_Body;

   --  Called by the trap stub with the address of the trap record in a0.
   procedure Hook (Record_Address : System.Address)
     with Export, Convention => C, External_Name => "__mpfs_early_trap_hook",
          No_Return;

end Early_Trap;
