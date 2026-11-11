--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Where the bytes of the receive test come from: QEMU's console.in
--  (RX_SOURCE=console, the default).

package Rx_Source is

   Reset_State_Known : constant Boolean := True;
   --  QEMU resets the PLIC enables and every mtimecmp to 0; the tests may
   --  compare with that.

   procedure Feed (Text : String);
   --  Get the bytes of Text into the receiver of MMUART0 (the interrupt is
   --  enabled already).
   --  QEMU: nothing to do, console.in feeds them.

   procedure Finish;
   --  Undo Feed, once the bytes have been taken.

end Rx_Source;
