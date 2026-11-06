--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The test seam of the start code: an image with code in the ITIM whose
--  ITIM is not enabled is rejected by start.S (crates/mpfs_rts/mpfs/gnat/
--  start.S), which writes the rejection record and jumps to Hook, as the
--  trap stub does. Hook checks the record and reports with Test_Report.

with System;

package Reject is

   --  Called by start.S with the address of the record in a0.
   procedure Hook (Record_Address : System.Address)
     with Export, Convention => C, External_Name => "__mpfs_early_trap_hook",
          No_Return;

end Reject;
