--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Stack painting of the interrupt stack of the runtime (the space between
--  the link symbols __interrupt_stack_start and __interrupt_stack_end, whose
--  size is the partition data __interrupt_stack_size).
--
--  Paint fills the stack with a pattern; Peak is the distance from the top
--  of the stack to the lowest word that no longer holds the pattern, the
--  high-water mark since Paint. Paint must run while nothing uses the stack
--  (the main program of the environment task does not run on it).

package Istack is

   Unpainted : constant := 16;
   --  The bytes at the lower end that Paint leaves alone: the guard word of
   --  the overflow check of the runtime lives there, and a peak is never
   --  reported below them

   function Size return Natural;
   --  Bytes of the interrupt stack of the image (0 if it has none)

   procedure Paint;

   function Peak return Natural;
   --  Bytes used since Paint; Size - Unpainted if the stack is used up

end Istack;
