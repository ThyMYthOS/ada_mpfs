--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with MPFS_Registers.PLIC;

package body PLIC_View is

   package Regs renames MPFS_Registers.PLIC;

   function Enable_Address (Hart : Hart_Id) return System.Address is
   begin
      case Hart is
         when 0 => return Regs.PLIC_Periph.ENABLE_H0_M'Address;
         when 1 => return Regs.PLIC_Periph.ENABLE_H1_M'Address;
         when 2 => return Regs.PLIC_Periph.ENABLE_H2_M'Address;
         when 3 => return Regs.PLIC_Periph.ENABLE_H3_M'Address;
         when 4 => return Regs.PLIC_Periph.ENABLE_H4_M'Address;
      end case;
   end Enable_Address;

   function Threshold_Address (Hart : Hart_Id) return System.Address is
   begin
      case Hart is
         when 0 => return Regs.PLIC_Periph.THRESHOLD_H0_M'Address;
         when 1 => return Regs.PLIC_Periph.THRESHOLD_H1_M'Address;
         when 2 => return Regs.PLIC_Periph.THRESHOLD_H2_M'Address;
         when 3 => return Regs.PLIC_Periph.THRESHOLD_H3_M'Address;
         when 4 => return Regs.PLIC_Periph.THRESHOLD_H4_M'Address;
      end case;
   end Threshold_Address;

   function Claim_Address (Hart : Hart_Id) return System.Address is
   begin
      case Hart is
         when 0 => return Regs.PLIC_Periph.CLAIM_COMPLETE_H0_M'Address;
         when 1 => return Regs.PLIC_Periph.CLAIM_COMPLETE_H1_M'Address;
         when 2 => return Regs.PLIC_Periph.CLAIM_COMPLETE_H2_M'Address;
         when 3 => return Regs.PLIC_Periph.CLAIM_COMPLETE_H3_M'Address;
         when 4 => return Regs.PLIC_Periph.CLAIM_COMPLETE_H4_M'Address;
      end case;
   end Claim_Address;

   function Enable_Word
     (Hart : Hart_Id; Index : Natural) return MPFS_Registers.UInt32 is
   begin
      case Hart is
         when 0 => return Regs.PLIC_Periph.ENABLE_H0_M (Index);
         when 1 => return Regs.PLIC_Periph.ENABLE_H1_M (Index);
         when 2 => return Regs.PLIC_Periph.ENABLE_H2_M (Index);
         when 3 => return Regs.PLIC_Periph.ENABLE_H3_M (Index);
         when 4 => return Regs.PLIC_Periph.ENABLE_H4_M (Index);
      end case;
   end Enable_Word;

   function Threshold (Hart : Hart_Id) return Natural is
   begin
      case Hart is
         when 0 => return Natural (Regs.PLIC_Periph.THRESHOLD_H0_M.THRESHOLD);
         when 1 => return Natural (Regs.PLIC_Periph.THRESHOLD_H1_M.THRESHOLD);
         when 2 => return Natural (Regs.PLIC_Periph.THRESHOLD_H2_M.THRESHOLD);
         when 3 => return Natural (Regs.PLIC_Periph.THRESHOLD_H3_M.THRESHOLD);
         when 4 => return Natural (Regs.PLIC_Periph.THRESHOLD_H4_M.THRESHOLD);
      end case;
   end Threshold;

end PLIC_View;
