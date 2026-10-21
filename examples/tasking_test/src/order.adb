--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package body Order is

   protected body Log is

      procedure Woke (Task_Id : Who) is
      begin
         Woken := Woken + 1;
         Place (Task_Id) := Woken;
         Time (Task_Id) := Ada.Real_Time.Clock;
      end Woke;

      function Count return Natural is (Woken);

      function Position (Task_Id : Who) return Natural is (Place (Task_Id));

      function Woke_At (Task_Id : Who) return Ada.Real_Time.Time
      is (Time (Task_Id));

   end Log;

   task body High_Task is
   begin
      delay until Release;
      Log.Woke (High);
      delay until Ada.Real_Time.Time_Last;
   end High_Task;

   task body Low_Task is
   begin
      delay until Release;
      Log.Woke (Low);
      delay until Ada.Real_Time.Time_Last;
   end Low_Task;

end Order;
