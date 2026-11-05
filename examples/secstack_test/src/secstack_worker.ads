--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A task with a secondary stack of its own (4096 bytes), for secstack_test:
--  it works with unconstrained results while the environment task does the
--  same, and it exhausts its own stack. What it found is in the variables.

package Secstack_Worker is
   pragma Elaborate_Body;

   --  The task has finished.
   Done : Boolean := False with Volatile;

   --  Every result was what it had to be, the stack of the environment task
   --  being busy with the same at the same time.
   Content_Ok : Boolean := True with Volatile;

   --  The exhaustion of the stack raised Storage_Error, and the bytes taken
   --  before it.
   Overflowed : Boolean := False with Volatile;
   Size       : Natural := 0 with Volatile;

   --  After the overflow the stack was usable again.
   Reusable : Boolean := False with Volatile;

   --  Size of the secondary stack of the task.
   Stack_Size : constant := 4096;

end Secstack_Worker;
