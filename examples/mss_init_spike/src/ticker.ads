--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The second port: MMUART0 at 230400 baud, write-only, with blocking writes
--  (wait for LSR.THRE before each byte, within a budget; no receive, no
--  interrupt). Closed until Open: nothing is written to the port, not even
--  its clock and reset, before. It carries one status line per period from
--  the main program, after the log has gone out on the console, which shows
--  on the board that mtime counts and that the MSS PLL stays locked.
--
--  A byte that does not get through within its budget marks the port dead:
--  nothing more is written, so a port that does not answer cannot hang the
--  image.

with Interfaces;

package Ticker is

   procedure Open;

   --  One status line (or several, see below), each ended by CR LF:
   --
   --    tick N: mtime 0x........ PLL_CTRL 0x........ LOCK b fabric: none
   --    tick N: ... fabric: F2M_1(119) x2 @0x........ masked, F2M_5(123) ...
   --
   --  Every fabric source that has fired appears in every line, in
   --  ascending order, with its count and the mtime of its first occurrence
   --  (Fabric); two sources to a line, the rest on continuation lines that
   --  start with the same "tick N: fabric:".
   procedure Put_Tick
     (Count   : Natural;
      MTIME   : Interfaces.Unsigned_64;
      Control : Interfaces.Unsigned_32;
      Locked  : Boolean);

   function Written return Natural;   --  bytes written
   function Dead return Boolean;

end Ticker;
