--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The tables of heap_test: library-level objects, not locals of the main
--  procedure, whose frame would be on the 16 KiB stack of the environment
--  task. They have no initial values: .bss, which the start code clears, so
--  every block starts as null (an initial value would be 21 KiB of zeros in
--  .data).

with System;

package Heap_Slots is

   --  The blocks of the random sequences: where, how long, and what content.
   Slots : constant := 200;

   Block : array (1 .. Slots) of System.Address;
   Size  : array (1 .. Slots) of Natural;
   Tag   : array (1 .. Slots) of Natural;

   --  The blocks of the fragmentation test.
   Many : constant := 2000;

   Pool : array (1 .. Many) of System.Address;

end Heap_Slots;
