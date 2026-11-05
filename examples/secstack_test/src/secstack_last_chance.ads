--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The last chance handler of secstack_light_test and secstack_tasking_test.
--  The light and light-tasking runtimes do not propagate exceptions: the
--  Storage_Error of an exhausted secondary stack ends here, and the handler
--  checks what it was and reports. It replaces the one of the runtime
--  (Ada.Exceptions.Last_Chance_Handler). The test application must have made
--  Test_Report.Start.

with System;

package Secstack_Last_Chance is

   --  The size of the secondary stack that Secstack_Cases.Exhaust is about to
   --  exhaust, in bytes.
   Expected_Size : Natural := 0 with Volatile;

   procedure Handler (Msg : System.Address; Line : Integer);
   pragma Export (C, Handler, "__gnat_last_chance_handler");
   pragma No_Return (Handler);

   --  How often the handler has been called.
   Calls : Natural := 0 with Volatile;

end Secstack_Last_Chance;
