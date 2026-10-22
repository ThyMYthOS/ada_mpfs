--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Exceptions; use Ada.Exceptions;

with Cases;

package body Worker is

   --  The default stack of a task of the embedded profile is 2 MiB, too much
   --  for the LIM.
   task Propagator with Storage_Size => 8192, Secondary_Stack_Size => 2048;

   task body Propagator is
   begin
      begin
         Cases.Level (3);
      exception
         when E : Cases.Custom =>
            Caught := Exception_Message (E) = "from the bottom";
      end;
      Done := True;
   end Propagator;

end Worker;
