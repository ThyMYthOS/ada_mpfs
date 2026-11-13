--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);
--  The profile has no exception propagation: no check could be reported

with Istack_Check;

package body Istack_Handler is

   procedure Handler (Msg : System.Address; Line : Integer) is
      pragma Unreferenced (Line);

      type C_String is array (Positive range 1 .. 128) of Character;
      pragma Warnings (Off, "*alignment*");
      Text : C_String with Import, Address => Msg;
      pragma Warnings (On, "*alignment*");
      --  The message, a C string; longer ones are cut

      Length : Natural := 0;
   begin
      while Length < Text'Last and then Text (Length + 1) /= ASCII.NUL loop
         Length := Length + 1;
      end loop;
      Istack_Check.Last_Chance (String (Text (1 .. Length)));
   end Handler;

end Istack_Handler;
