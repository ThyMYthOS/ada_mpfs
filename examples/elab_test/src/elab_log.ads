--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The order in which the units of elab_test were elaborated: each unit
--  notes itself when its body is elaborated. Preelaborable, so that it is
--  there before any of the units that use it.

package Elab_Log is
   pragma Preelaborate;

   type Unit_Id is (Unit_A, Unit_B, Unit_C, Unit_Task);

   procedure Note (Id : Unit_Id);

   --  How many units have noted themselves so far
   function Count return Natural;

   --  1 for the unit that noted itself first, 0 for one that has not
   function Position (Id : Unit_Id) return Natural;

end Elab_Log;
