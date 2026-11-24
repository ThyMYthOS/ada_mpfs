--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The image for the Icicle Kit: sets the MSS up from the table and treats a
--  poll that runs out of time as an error (the sequence stops, the last line
--  says MSS INIT FAILED). README.md says how to run it.

with Mss_Init;
with Spike;

procedure Mss_Init_Spike is
   Tick_Count : constant := 0;   --  without end
   Period_Ms  : constant := 1000;
begin
   Spike.Run ("mss_init_spike", Mss_Init.Stop, Tick_Count, Period_Ms);
   loop
      null;
   end loop;
end Mss_Init_Spike;
