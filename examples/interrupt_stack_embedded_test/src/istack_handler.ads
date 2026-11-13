--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The last chance handler of the interrupt stack tests of the embedded
--  profile: it takes the message of the exception and hands it to
--  Istack_Check. The tasking profile has its own unit of this name (its
--  handler gets the message as a C string).

with Ada.Exceptions;

package Istack_Handler is

   procedure Handler (Except : Ada.Exceptions.Exception_Occurrence);
   pragma Export (C, Handler, "__gnat_last_chance_handler");
   pragma No_Return (Handler);

end Istack_Handler;
