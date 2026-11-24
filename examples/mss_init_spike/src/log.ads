--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The log of the image: a ring buffer in RAM that everything the image
--  reports goes into. Put never blocks and touches no hardware; when the ring
--  is full the rest of the message is dropped and counted.
--
--  One producer (the main program) and one consumer (the interrupt handler of
--  the sink, Sink), on one hart, without protected objects and without
--  masking interrupts:
--
--  - Head is written only by the producer, Tail only by the consumer; both
--    count bytes (modulo 2**32, the ring size is a power of two) and are
--    atomic. The producer stores the byte, then publishes it by writing Head;
--    the consumer reads Head, then the byte, then writes Tail. The data is
--    volatile, so the compiler keeps these accesses in order, and one hart
--    sees its own accesses in program order, also in a handler that
--    interrupts it: the handler never sees a Head whose byte is not stored,
--    and the producer never reuses a place before Tail has passed it (it
--    reads Tail first, and a stale Tail only makes the ring look fuller than
--    it is).
--  - The handler runs to its end between two instructions of the producer;
--    the producer never runs while the handler does. So every decision of
--    the handler is a decision on a consistent state, and the producer's
--    state (Head, the counters) is not touched by the handler. The wake-up
--    of the sink is in Sink.
--  - This is for one hart: two harts would need the fences of a real
--    single-producer single-consumer queue.

package Log is

   --  Put as much of Text as fits; Taken is the number of bytes that were
   --  taken in (the first ones), the rest is counted as dropped.
   procedure Put (Text : String; Taken : out Natural);

   --  The consumer: the oldest byte of the ring; Got is False if empty.
   procedure Get (Item : out Character; Got : out Boolean);

   function Capacity return Positive;
   function Pending return Natural;    --  bytes in the ring
   function Accepted return Natural;   --  bytes that Put took in, ever
   function Dropped return Natural;    --  bytes that did not fit, ever

end Log;
