--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  itim_reject_test: an image with code in the ITIM, started on a hart whose
--  ITIM is not enabled, is rejected by the start code with a clear record
--  instead of crashing later (as hello_mpfs of the earlier project did).
--  The check is done by start.S before this main program; Reject.Hook
--  reports it. If control ever reaches the main program, the image was not
--  rejected, which is a failure.
--
--  @verifies RTS-017

with Fast;
with Reject;
pragma Unreferenced (Reject);
with Test_Report;

procedure Itim_Reject_Test is
begin
   Test_Report.Start ("itim_reject_test_e51");
   --  Add (40, 2) is 42: this check fails, and it needs Add, which keeps
   --  .fast_text in the image.
   Test_Report.Check
     (Fast.Add (40, 2) /= 42, "the image was rejected before main");
   Test_Report.Finish;
end Itim_Reject_Test;
