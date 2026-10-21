--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  trap_test: an early trap is reported correctly (defect no. 5 of the
--  master plan: mtvec was not set before the first trap). The work is done
--  while Early_Trap is elaborated, before this main program starts; if
--  control ever reaches it, the trap did not happen or came back, which is
--  a failure: there is no verdict line.

with Early_Trap;
pragma Unreferenced (Early_Trap);

procedure Trap_Test is
begin
   null;
end Trap_Test;
