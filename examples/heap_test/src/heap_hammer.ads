--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A task of a higher priority than the environment task that allocates and
--  frees, every millisecond, while the environment task does the same: the
--  timer interrupt that wakes it up can come at any instruction of the
--  environment task, and the heap lock (no interrupt during an operation of
--  the allocator) is what keeps the two out of each other's way. Every block
--  has a content that depends on the task and the number of the block; one
--  that was disturbed is counted.

package Heap_Hammer is
   pragma Elaborate_Body;

   --  The task does nothing, and so does not touch the heap, until the test
   --  sets this.
   Go : Boolean := False with Volatile;

   --  The task has finished its 40 rounds of 16 blocks.
   Done : Boolean := False with Volatile;

   --  How many blocks had another content when they were freed.
   Disturbed : Natural := 0 with Volatile;

   --  How many allocations returned no memory.
   Refused : Natural := 0 with Volatile;

   --  How many blocks were allocated.
   Allocated : Natural := 0 with Volatile;

end Heap_Hammer;
