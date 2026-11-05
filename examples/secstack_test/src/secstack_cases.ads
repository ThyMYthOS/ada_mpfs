--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What the three secondary stack tests (secstack_test, secstack_light_test
--  and secstack_tasking_test) have in common: functions whose result has a
--  size that the caller does not know, which the compiler returns on the
--  secondary stack, and the exhaustion of that stack.

package Secstack_Cases is

   --  N characters C.
   function Repeat (C : Character; N : Natural) return String;

   --  A, then B.
   function Join (A, B : String) return String;

   --  N characters that depend on Seed and on the position.
   function Pattern (Seed, N : Natural) return String;

   --  S is Pattern (Seed, S'Length).
   function Is_Pattern (S : String; Seed : Natural) return Boolean;

   --  The chunks Pattern (Depth, 8), Pattern (Depth - 1, 8), ... Pattern
   --  (1, 8), each one the result of a call of a function with a result of
   --  unknown size that has a call of such a function in it: 8 * Depth
   --  characters, and 2 * Depth results on the secondary stack at the deepest
   --  point.
   function Nested (Depth : Natural) return String;

   --  S is Nested (Depth).
   function Is_Nested (S : String; Depth : Natural) return Boolean;

   --  The size of the chunks of Exhaust.
   Chunk : constant := 256;

   --  The number of bytes that Exhaust has taken from the secondary stack.
   Taken : Natural := 0 with Volatile;

   --  Takes Chunk bytes at a time from the secondary stack until it is
   --  exhausted: the allocation that does not fit raises Storage_Error
   --  (propagated, or the last chance handler of a runtime without
   --  propagation). Taken is the size of the stack, to a chunk.
   procedure Exhaust;

end Secstack_Cases;
