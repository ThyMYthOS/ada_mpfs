--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The last chance handler of the interrupt stack tests of the light-tasking
--  profile (the unit Istack_Handler of this variant): the profile has no
--  exception occurrences, the handler gets the message as a C string and a
--  line number (0 for a message of the program) and hands the message to
--  Istack_Check.

with System;

package Istack_Handler is

   procedure Handler (Msg : System.Address; Line : Integer);
   pragma Export (C, Handler, "__gnat_last_chance_handler");
   pragma No_Return (Handler);

end Istack_Handler;
