--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

with Ada.Interrupts.Names;

with Fabric;

package body Fabric_Seam is

   procedure Before_Tick (Tick : Positive) is
   begin
      if Tick = Inject_Tick then
         Fabric.Record_Occurrence (Integer (Ada.Interrupts.Names.F2M_1));
         Fabric.Record_Occurrence (Integer (Ada.Interrupts.Names.F2M_1));
         Fabric.Record_Occurrence (Integer (Ada.Interrupts.Names.F2M_5));
      end if;
   end Before_Tick;

end Fabric_Seam;
