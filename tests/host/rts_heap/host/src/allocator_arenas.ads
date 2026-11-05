--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The memory that Allocator_Test hands to the allocator: static, not on the stack of the main
--  program, which could not hold 32 MiB.

with System.Storage_Elements; use System.Storage_Elements;

package Allocator_Arenas is

   Small_Bytes : constant := 64 * 1024;

   Small : Storage_Array (1 .. Small_Bytes) with Alignment => 16;

   Big_Bytes : constant := 32 * 1024 * 1024;

   Big : Storage_Array (1 .. Big_Bytes) with Alignment => 16;

end Allocator_Arenas;
