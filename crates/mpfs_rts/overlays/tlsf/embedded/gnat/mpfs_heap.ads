--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  malloc, free, realloc and calloc of the embedded runtime, in Ada, over the
--  TLSF allocator (Tlsf_Core): the heap is the memory between __heap_start and
--  __heap_end of the linker script. System.Memory (new, Unchecked_Deallocation
--  of any access type) calls malloc, free and realloc; libgcc's unwinder calls
--  malloc and free by name (the first raise sorts the frame descriptions), so
--  the symbols have to be defined here: the allocator of newlib is not linked.
--
--  Every call takes the heap lock (MPFS_Heap_Lock) for the time of the
--  allocator's work, so tasks, interrupt handlers and libgcc may call in any
--  order. The heap is set up by the first call; nothing needs to elaborate.

with Interfaces.C;
with System;
with System.Storage_Elements;

package MPFS_Heap is
   pragma Preelaborate;

   function Malloc (N : Interfaces.C.size_t) return System.Address;
   pragma Export (C, Malloc, "malloc");

   procedure Free (P : System.Address);
   pragma Export (C, Free, "free");

   function Realloc
     (P : System.Address; N : Interfaces.C.size_t) return System.Address;
   pragma Export (C, Realloc, "realloc");

   function Calloc (Nmemb, Size : Interfaces.C.size_t) return System.Address;
   pragma Export (C, Calloc, "calloc");

   --  The sum of the payload of all free blocks: less than the largest
   --  request that can still be served, by the header of every block.
   function Free_Bytes return System.Storage_Elements.Storage_Count;

   --  The size of the heap, the number of bytes between __heap_start and
   --  __heap_end.
   function Heap_Size return System.Storage_Elements.Storage_Count;

   --  A check of the block chain, for the tests (it walks the whole heap with
   --  the lock held).
   function Invariants_Hold return Boolean;

end MPFS_Heap;
