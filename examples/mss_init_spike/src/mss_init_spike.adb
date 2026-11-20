--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The image for the Icicle Kit: sets the MSS up from the table and treats a
--  poll that runs out of time as an error (the sequence stops, the last line
--  says MSS INIT FAILED). README.md says how to run it.

pragma Restrictions (No_Elaboration_Code);

with Mss_Init;
with Spike;

procedure Mss_Init_Spike is
begin
   Spike.Run ("mss_init_spike", Mss_Init.Stop);
   loop
      null;
   end loop;
end Mss_Init_Spike;
