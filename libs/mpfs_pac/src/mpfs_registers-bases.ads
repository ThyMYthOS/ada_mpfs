--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Relation between the two instances of a peripheral: every peripheral that
--  has an _LO and an _HI base address in the generated MPFS_Registers (for
--  example MMUART0_LO_Base and MMUART0_HI_Base) has them HI_Offset apart.
--  `./x pac check` verifies this against the SVD.

with System.Storage_Elements;

package MPFS_Registers.Bases
  with Preelaborate
is

   HI_Offset : constant System.Storage_Elements.Storage_Offset :=
     16#0800_0000#;

   function To_HI (LO : System.Address) return System.Address
   is (System.Storage_Elements."+" (LO, HI_Offset));
   --  Base address of the _HI instance of the peripheral at `LO`

   function To_LO (HI : System.Address) return System.Address
   is (System.Storage_Elements."-" (HI, HI_Offset));
   --  Base address of the _LO instance of the peripheral at `HI`

end MPFS_Registers.Bases;
