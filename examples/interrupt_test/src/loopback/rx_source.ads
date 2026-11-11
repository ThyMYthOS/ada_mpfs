--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Where the bytes of the receive test come from: the MMUART in loopback
--  (RX_SOURCE=loopback, the Icicle Kit, P1.14, #55).

package Rx_Source is

   Reset_State_Known : constant Boolean := False;
   --  On the silicon the PLIC enables and the mtimecmp registers have no reset
   --  value that a test can rely on (measured: the mtimecmp of a hart read 32,
   --  the enable words of S mode contexts were random, and ./x hw reset
   --  clears neither).

   procedure Feed (Text : String);
   --  Get the bytes of Text into the receiver of MMUART0 (the interrupt is
   --  enabled already).
   --  Board: MCR.LOOP, then the bytes are written to THR.

   procedure Finish;
   --  Undo Feed, once the bytes have been taken.

end Rx_Source;
