--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A TEST SEAM of the QEMU image, not part of the board image: QEMU has no
--  input for the fabric lines of this machine, so the QEMU main calls the
--  code that the handler runs (Fabric.Record_Occurrence: count, remember
--  mtime, mask in the PLIC) for chosen sources, in a chosen tick. The real
--  interrupt entry (the PLIC, the trap, Attach_Handler's wrapper) is not
--  exercised by it.

package Fabric_Seam is

   --  The tick in which the sources below fire: F2M_1 twice (the second
   --  time as if the runtime had delivered it before the mask took effect)
   --  and F2M_5 once.
   Inject_Tick : constant := 2;

   procedure Before_Tick (Tick : Positive);

end Fabric_Seam;
