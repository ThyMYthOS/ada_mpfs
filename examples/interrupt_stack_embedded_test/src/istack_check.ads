--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What the tests of the interrupt stack check in the last chance handler
--  (Istack_Handler of the profile calls Last_Chance with the message of the
--  unhandled exception). Start paints the stack and says which test this is.

package Istack_Check is

   type Test is (Peak_Of_Trap);
   --  Peak_Of_Trap: an illegal instruction in the program raises
   --  Program_Error in the trap handler, on the interrupt stack, and the
   --  peak of the use of the stack up to this point leaves a margin of 50 %

   procedure Start (Which : Test);

   procedure Last_Chance (Message : String);
   pragma No_Return (Last_Chance);

end Istack_Check;
