--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  trap_embedded_test: an illegal instruction in the program of the embedded
--  profile ends in the last chance handler with the diagnosis of the trap
--  (Trap_Last_Chance). The instruction is the one of examples/trap_test
--  (fault.S); if control returns from it, the check below fails.
--
--  The trap is the first exception of the program: libgcc sorts its frame
--  descriptions at the first unwind, on the interrupt stack, which needs more
--  than the 8 KiB that the interrupt stack of the embedded profile used to
--  have (issue #91; the stack is now 12 912 bytes, and
--  examples/interrupt_stack_embedded_test measures the peak).
--
--  Reported with Test_Report as trap_embedded_test_e51 or _u54.
--
--  @verifies RTS-005, RTS-022

with Bare_Console;
with Test_Report;
with Trap_Last_Chance;
pragma Unreferenced (Trap_Last_Chance);
--  Only for the handler it exports

procedure Trap_Embedded_Test is

   use type Bare_Console.U64;

   procedure Fault
     with Import, Convention => C, External_Name => "trap_test_fault";

begin
   Test_Report.Start
     (if Bare_Console.Hart_Id = 0 then "trap_embedded_test_e51"
      else "trap_embedded_test_u54");
   Fault;

   --  Not reached.
   Test_Report.Check (False, "the illegal instruction did not trap");
   Test_Report.Finish;
end Trap_Embedded_Test;
