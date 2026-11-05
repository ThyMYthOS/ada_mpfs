--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1

pragma Restrictions (No_Elaboration_Code);

with System.Machine_Code;

package body MPFS_Heap_Lock is

   use type Interfaces.Unsigned_64;

   --  mstatus.MIE, the machine interrupt enable bit (bit 3).
   MIE : constant := 2#1000#;

   -------------
   -- Acquire --
   -------------

   function Acquire return Saved_State is
      Old : Interfaces.Unsigned_64;
   begin
      --  Atomic read and clear of the bit: an interrupt cannot be taken
      --  between the read and the clear. The "memory" clobber keeps the
      --  compiler from moving the accesses of the heap out of the section.
      System.Machine_Code.Asm
        ("csrrci %0, mstatus, 8",
         Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Old),
         Volatile => True,
         Clobber  => "memory");
      return Saved_State (Old and MIE);
   end Acquire;

   -------------
   -- Release --
   -------------

   procedure Release (State : Saved_State) is
   begin
      if State /= 0 then
         System.Machine_Code.Asm
           ("csrsi mstatus, 8",
            Volatile => True,
            Clobber  => "memory");
      end if;
   end Release;

end MPFS_Heap_Lock;
