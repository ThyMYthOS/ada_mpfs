--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The body of Secstack_Worker for the light-tasking runtime, which does not
--  propagate exceptions: the task works with unconstrained results beside the
--  environment task, and does not exhaust its stack (that would end in the
--  last chance handler, and the test is over then).

with Ada.Real_Time; use Ada.Real_Time;

with Secstack_Cases;

package body Secstack_Worker is

   --  The default stack of a task of the light-tasking profile is 2 MiB, too
   --  much for the LIM.
   task Worker with Storage_Size => 8192, Secondary_Stack_Size => Stack_Size;

   task body Worker is
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

      Reusable := Secstack_Cases.Is_Nested (Secstack_Cases.Nested (10), 10);
      Done := True;
   end Worker;

end Secstack_Worker;
