--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Real_Time;
with Elab_Log;

package body Elab_Tasks is

   Ran : Boolean := False with Volatile;

   function Noted return Boolean;

   function Noted return Boolean is
   begin
      Elab_Log.Note (Elab_Log.Unit_Task);
      return True;
   end Noted;

   task body Worker is
      Declared : constant Boolean := Noted;
      --  Elaborated at the activation of the task
   begin
      Ran := Declared;
      delay until Ada.Real_Time.Time_Last;
   end Worker;

   function Started return Boolean is (Ran);

end Elab_Tasks;
