--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Failing;

package body Failing_Task is

   task Doomed with Storage_Size => 8192, Secondary_Stack_Size => 2048;

   task body Doomed is
   begin
      Failing.Run (3);
   end Doomed;

end Failing_Task;
