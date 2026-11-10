--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The second unit: it withs Elab_A and uses its value while it is
--  elaborated, which is only right if Elab_A has been elaborated first.

with Elab_A;

package Elab_B is
   pragma Elaborate_Body;

   Sum : Integer := Elab_A.Value + 1;
   --  43, if Elab_A was elaborated first

   Noted_At : Natural := 0;

end Elab_B;
