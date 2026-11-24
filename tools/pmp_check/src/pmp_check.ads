--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The independent checker of the PMP of a system: the types that all its units share.
--
--  @req GEN-015

with Interfaces;

package Pmp_Check
  with SPARK_Mode, Pure
is
   subtype U8 is Interfaces.Unsigned_8;
   subtype U64 is Interfaces.Unsigned_64;

   --  A byte address of RV64 as a PMP entry can name it: pmpaddr holds address bits 55:2, so the
   --  space of a hart has at most 2 ** 56 bytes. Max_Address itself is the end of that space (one
   --  past its last byte), so that a range [First, Last] always has Last + 1 as an Address.
   Max_Address : constant := 2 ** 56;
   type Address is range 0 .. Max_Address;

end Pmp_Check;
