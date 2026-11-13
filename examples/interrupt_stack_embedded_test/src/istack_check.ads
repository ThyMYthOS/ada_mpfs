--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What the tests of the interrupt stack check in the last chance handler
--  (Istack_Handler of the profile calls Last_Chance with the message of the
--  unhandled exception). Start paints the stack and says which test this is.

with Interfaces;

package Istack_Check is

   type Test is (Peak_Of_Trap, Overrun_In_Handler);
   --  Peak_Of_Trap: an illegal instruction in the program raises
   --  Program_Error in the trap handler, on the interrupt stack, and the
   --  peak of the use of the stack up to this point leaves a margin of 50 %.
   --  Overrun_In_Handler: an interrupt handler (a timing event) uses more
   --  stack than there is and overwrites the guard word; the trap handler
   --  finds that when the handler returns, and the program ends in the last
   --  chance handler with the message "interrupt stack overflow"

   procedure Start (Which : Test; At_Main : Interfaces.Unsigned_64 := 0);
   --  At_Main: Istack.Instret at the start of the main program; Start ends by
   --  taking the count again, the program then takes its trap


   procedure Last_Chance (Message : String);
   pragma No_Return (Last_Chance);

end Istack_Check;
