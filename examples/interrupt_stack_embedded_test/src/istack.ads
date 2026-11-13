--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Stack painting of the interrupt stack of the runtime (the space between
--  the link symbols __interrupt_stack_start and __interrupt_stack_end, whose
--  size is the partition data __interrupt_stack_size), and the means to
--  overrun it for the tests of its guard word.
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

   procedure Overrun;
   --  Called in an interrupt handler: a frame of the size of the whole stack
   --  on the stack, which reaches below its lower end, in which the word at
   --  the lower end of the stack (the guard word of the runtime) is
   --  overwritten with zero. This is what a handler that uses more stack than
   --  there is does to the guard word, without the damage below the stack
   --  that a real overrun does to whatever lies there.

   function Overran return Boolean;
   --  True if Overrun reached below the lower end of the stack, which is
   --  what it is for: the frame did not fit

   procedure Clobber_Guard;
   --  Overwrites the guard word with zero, from any stack

end Istack;
