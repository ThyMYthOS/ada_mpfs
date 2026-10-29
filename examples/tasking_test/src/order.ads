--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Two library-level tasks of different priority that wait for the same
--  instant. When it comes, both are ready at once, and the Ravenscar rule is
--  that the one with the higher priority runs first: Log tells the order in
--  which they got there and when.

with Ada.Real_Time;
with System;

package Order is

   use type Ada.Real_Time.Time;

   Release : constant Ada.Real_Time.Time :=
     Ada.Real_Time.Clock + Ada.Real_Time.Milliseconds (100);
   --  The instant the tasks wait for, 100 ms after the elaboration of this
   --  package, i.e. after the start of the program and before its main
   --  procedure runs the first check

   type Who is (High, Low);

   type Positions is array (Who) of Natural;
   type Instants is array (Who) of Ada.Real_Time.Time;

   protected Log with Priority => System.Priority'Last is
      procedure Woke (Task_Id : Who);
      function Count return Natural;
      function Position (Task_Id : Who) return Natural;
      --  1 for the task that woke first, 2 for the other, 0 if it did not
      function Woke_At (Task_Id : Who) return Ada.Real_Time.Time;
   private
      Woken : Natural := 0;
      Place : Positions := [others => 0];
      Time  : Instants := [others => Ada.Real_Time.Time_First];
   end Log;

   task High_Task with Priority => 10, Storage_Size => 4096;
   task Low_Task  with Priority => 5,  Storage_Size => 4096;

end Order;
