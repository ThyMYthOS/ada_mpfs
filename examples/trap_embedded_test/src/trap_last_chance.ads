--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The last chance handler of trap_embedded_test. In the embedded profile the
--  runtime has installed its own trap handler (System.BB.CPU_Specific) before
--  the first unit of the application is elaborated, so an illegal instruction
--  is not seen by the trap stub of start.S (examples/trap_test) but raised as
--  Program_Error ("Unhandled trap: 2"), propagates to the end of the stack and
--  ends here. The CSRs of the trap are still those of the illegal
--  instruction: the handler reports them.

with Ada.Exceptions;

package Trap_Last_Chance is

   procedure Handler (Except : Ada.Exceptions.Exception_Occurrence);
   pragma Export (C, Handler, "__gnat_last_chance_handler");
   pragma No_Return (Handler);

   --  How often the handler has been called.
   Calls : Natural := 0 with Volatile;

end Trap_Last_Chance;
