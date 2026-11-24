--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The image for QEMU: the same table and interpreter, but a poll that runs
--  out of time is reported and the sequence goes on, because under QEMU the
--  registers of the PLLs and the PHY are plain memory that reads 0 and no
--  poll can succeed. tests/host/mss_init_spike compares its register writes
--  with the sequence of ./x hw initialize.

with Mss_Init;
with Fabric_Seam;
with Spike;

procedure Mss_Init_Spike_QEMU is
   Tick_Count : constant := 3;     --  the test needs an end
   Period_Ms  : constant := 50;
begin
   Spike.Run
     ("mss_init_spike_qemu", Mss_Init.Continue, Tick_Count, Period_Ms,
      Fabric_Seam.Before_Tick'Access);
   loop
      null;
   end loop;
end Mss_Init_Spike_QEMU;
