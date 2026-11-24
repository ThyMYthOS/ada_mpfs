--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The console of the image: MMUART2 (Uart), driven by the interrupt
--  "transmit holding register empty" (IER.ETBEI). The handler is attached
--  with System.BB.Interrupts.Attach_Handler, the interface of the runtime
--  below Ada.Interrupts and the protected objects: a plain procedure, no
--  task, no protected object.
--
--  The sink is CLOSED until Open: nothing is written to the MMUART (no data,
--  no interrupt enable, not even its clock and reset), the PLIC source is not
--  set up (Open attaches the handler), so that nothing is sent while the IO
--  banks and the clocks are being set up. Open brings the port up, attaches
--  the handler and enables the interrupt; the handler moves up to a FIFO
--  depth of bytes from the log into the transmitter per interrupt and
--  disables the interrupt when the log is empty.
--
--  The wake-up, on one hart: the producer (Console.Put) stores into the log
--  (Log.Put publishes by writing Head) and only then calls Kick, which
--  enables the interrupt. The handler runs between two instructions of the
--  producer and to its end. If it runs before Log.Put has published, it finds
--  the log empty and disables the interrupt, and the Kick that follows
--  enables it again. If it runs after the publication it sends the bytes,
--  and a Kick that comes later enables the interrupt for a log that is
--  empty: one more interrupt, in which the handler finds nothing and
--  disables it. The handler disables the interrupt only when it has just
--  seen the log empty, and nothing else can fill the log while it runs. So
--  the interrupt is enabled, or the log is empty and the producer's Kick
--  has not run yet: no byte stays in the log with the interrupt disabled.

package Sink is

   procedure Open;

   function Is_Open return Boolean;

   --  After a Log.Put: lets the sink send what is in the log (does nothing
   --  while the sink is closed).
   procedure Kick;

   --  Waits until the log is empty and the transmitter has sent the last bit
   --  (LSR.TEMT), for at most Budget_Microseconds (counted in cycles of the
   --  hart); False if the time ran out.
   function Flush (Budget_Microseconds : Natural) return Boolean;

   --  How often the handler ran.
   function Interrupts return Natural;

end Sink;
