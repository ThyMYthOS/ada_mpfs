--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The PLIC registers of the M mode context of a hart, by the names of the PAC
--  (ENABLE_H3_M, THRESHOLD_H3_M, ...): a case over the five harts. The runtime
--  (System.BB.RISCV_PLIC) takes the context from mhartid and computes the
--  address; this is the independent way to the same registers, for the checks.

with System;

with MPFS_Registers;

package PLIC_View is

   subtype Hart_Id is Natural range 0 .. 4;

   function Enable_Address (Hart : Hart_Id) return System.Address;
   function Threshold_Address (Hart : Hart_Id) return System.Address;
   function Claim_Address (Hart : Hart_Id) return System.Address;

   function Enable_Word
     (Hart : Hart_Id; Index : Natural) return MPFS_Registers.UInt32;
   --  Word Index (0 .. 5) of the enable block of the M mode context

   function Threshold (Hart : Hart_Id) return Natural;

end PLIC_View;
