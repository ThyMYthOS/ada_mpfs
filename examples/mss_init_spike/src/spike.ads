--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What both images do. The table runs phase by phase and nothing is sent to
--  the UART meanwhile: the banner, a line per phase with a snapshot of
--  registers, every poll that ran out of time and two read-back proofs (that
--  CLINT.MTIME advances, the lock bit of the MSS PLL) go into the log. When
--  the sequence has ended, whether it ran to the end or stopped at a poll,
--  the two ports are opened, the log is sent (MMUART0 by polling, MMUART2 by
--  interrupt), and the summary and the verdict follow as the last lines.

with Mss_Init;

package Spike is

   --  Image is the name in the lines (the first word of each).
   --  After the verdict, if the sequence ended well and mtime counts, one
   --  status line per Period_Ms on MMUART0: Tick_Count lines, or without end
   --  if it is 0.
   --  Before_Tick, if not null, is called with the number of the tick before
   --  its line is written (a test seam of the QEMU image: Fabric_Seam).
   type Tick_Hook is access procedure (Tick : Positive);

   procedure Run
     (Image       : String;
      Policy      : Mss_Init.Timeout_Policy;
      Tick_Count  : Natural;
      Period_Ms   : Positive;
      Before_Tick : Tick_Hook := null);

end Spike;
