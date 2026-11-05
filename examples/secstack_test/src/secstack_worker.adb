--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Real_Time; use Ada.Real_Time;

with System.Secondary_Stack;

with Secstack_Cases;

package body Secstack_Worker is

   --  The default stack of a task of the embedded profile is 2 MiB, too much
   --  for the LIM.
   task Worker with Storage_Size => 8192, Secondary_Stack_Size => Stack_Size;

   task body Worker is
      Mark : System.Secondary_Stack.Mark_Id;
   begin
      for Round in 1 .. 5 loop
         declare
            Text : constant String := Secstack_Cases.Nested (Round * 2);
         begin
            --  The environment task runs now and allocates on its stack.
            delay until Clock + Milliseconds (2);
            if not Secstack_Cases.Is_Nested (Text, Round * 2) then
               Content_Ok := False;
            end if;
         end;
      end loop;

      Mark := System.Secondary_Stack.SS_Mark;
      begin
         Secstack_Cases.Exhaust;
      exception
         when Storage_Error =>
            Overflowed := True;
            Size := Secstack_Cases.Taken;
      end;
      System.Secondary_Stack.SS_Release (Mark);

      Reusable := Secstack_Cases.Is_Nested (Secstack_Cases.Nested (10), 10);
      Done := True;
   end Worker;

end Secstack_Worker;
