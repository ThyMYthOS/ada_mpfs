--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The last chance handler of unhandled_test and unhandled_task_test. It
--  replaces the one of the runtime (Ada.Exceptions.Last_Chance_Handler, which
--  prints the exception on the console and stops the machine): an exception
--  that nobody handles ends up here, and the handler reports what it got.
--  The test application must have made Test_Report.Start.

with Ada.Exceptions;

package Last_Chance is

   procedure Handler (Except : Ada.Exceptions.Exception_Occurrence);
   pragma Export (C, Handler, "__gnat_last_chance_handler");
   pragma No_Return (Handler);

   --  How often the handler has been called.
   Calls : Natural := 0 with Volatile;

end Last_Chance;
