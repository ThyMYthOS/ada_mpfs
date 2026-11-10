--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The third unit: it withs Elab_B, whose body withs Elab_A.

with Elab_B;

package Elab_C is
   pragma Elaborate_Body;

   Product : Integer := Elab_B.Sum * 2;
   --  86, if Elab_B was elaborated first

   Noted_At : Natural := 0;

end Elab_C;
