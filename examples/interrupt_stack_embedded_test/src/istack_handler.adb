--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Istack_Check;

package body Istack_Handler is

   procedure Handler (Except : Ada.Exceptions.Exception_Occurrence) is
   begin
      Istack_Check.Last_Chance (Ada.Exceptions.Exception_Message (Except));
   end Handler;

end Istack_Handler;
