--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  trap_embedded_test: an illegal instruction in the program of the embedded
--  profile ends in the last chance handler with the diagnosis of the trap
--  (Trap_Last_Chance). The instruction is the one of examples/trap_test
--  (fault.S); if control returns from it, the check below fails.
--
--  The first exception of a program makes libgcc sort its frame descriptions
--  (malloc, a heap that starts at its first use), which on the U54 needs more
--  than the 8 KiB of the interrupt stack of the runtime when it happens in a
--  trap handler: the stack is used up to its last 16 bytes and the next frame
--  overwrites the .bss behind it (libgcc's register size table, first). So the
--  program raises and handles one exception before the trap, on the stack of
--  its task; with that the trap is reported on both hart classes. The size of
--  the interrupt stack (s-bbpara.ads of the fork) is not this test's to
--  change; see the README.
--
--  Reported with Test_Report as trap_embedded_test_e51 or _u54.

with Bare_Console;
with Test_Report;
with Trap_Last_Chance;
pragma Unreferenced (Trap_Last_Chance);
--  Only for the handler it exports

procedure Trap_Embedded_Test is

   use type Bare_Console.U64;

   procedure Fault
     with Import, Convention => C, External_Name => "trap_test_fault";

   procedure Warm_Up_Unwinder;

   procedure Warm_Up_Unwinder is
   begin
      raise Constraint_Error;
   exception
      when Constraint_Error => null;
   end Warm_Up_Unwinder;

begin
   Test_Report.Start
     (if Bare_Console.Hart_Id = 0 then "trap_embedded_test_e51"
      else "trap_embedded_test_u54");
   Warm_Up_Unwinder;
   Fault;

   --  Not reached.
   Test_Report.Check (False, "the illegal instruction did not trap");
   Test_Report.Finish;
end Trap_Embedded_Test;
