--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What both images do: run the table phase by phase, print a line per
--  phase and every poll that ran out of time, then read back two proofs
--  that need no knowledge of the board beyond hw/mss_init.py: that CLINT.MTIME
--  advances between two reads, and the lock bit of the MSS PLL.

with Mss_Init;

package Spike is

   --  Image is the name in the lines (the first word of each).
   procedure Run (Image : String; Policy : Mss_Init.Timeout_Policy);

end Spike;
