--  SPDX-FileCopyrightText: 2019 AdaCore
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes riscv/src/s-bbripl.ads @ 09e7cd6
--  (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC.
--
--  The PLIC of PolarFire SoC, used by the harts of the partition. Every
--  subprogram that has "the current hart" in its description works on the M
--  mode context of the hart that executes it (Context_Of (System.BB.Hart.Id),
--  from mhartid at run time). Nothing is hard-wired to a hart, and nothing but
--  the own context is changed, except the priority of a source.
--
--  All registers are reached through the PAC (MPFS_Registers.PLIC) with 32-bit
--  accesses, one per register: the PLIC of the SoC (and QEMU's) accepts no
--  other width.

pragma Restrictions (No_Elaboration_Code);

with System.BB.Interrupts;

package System.BB.RISCV_PLIC is
   pragma Preelaborate;

   package BBI renames System.BB.Interrupts;

   Max_Hart : constant := 4;
   --  The harts of the SoC: the E51 is hart 0, the U54 cores are 1 .. 4

   function Context_Of (Hart : Natural) return Natural is
     (if Hart = 0 then 0 else 2 * Hart - 1)
     with Pre => Hart <= Max_Hart;
   --  The PLIC context of the M mode of a hart. The E51 (hart 0) has one
   --  context, the U54 cores have two each (M mode, then S mode), so that
   --  hart 1 is context 1 (M) and 2 (S), hart 2 is 3 and 4, and so on.

   function Enable_Address (Hart : Natural) return System.Address
     with Pre => Hart <= Max_Hart;
   function Threshold_Address (Hart : Natural) return System.Address
     with Pre => Hart <= Max_Hart;
   function Claim_Address (Hart : Natural) return System.Address
     with Pre => Hart <= Max_Hart;
   --  The first word of the enable block, the threshold register and the
   --  claim/complete register of the M mode context of a hart. They are the
   --  registers of the PAC (ENABLE_H<n>_M, THRESHOLD_H<n>_M and
   --  CLAIM_COMPLETE_H<n>_M for the hart n); the test interrupt_test compares
   --  them for all five harts.

   procedure Initialize;
   --  Called during board initialization on every hart that runs the
   --  runtime. Resets the context of the executing hart only: the threshold
   --  is 0, all its enables are cleared and a claim left over from before is
   --  completed. The priorities of the sources are NOT cleared, and the
   --  contexts and enables of other harts are not touched: in an AMP system
   --  the sources of the other harts belong to them. On return no interrupt
   --  is enabled for the current hart.

   function Pending return Boolean;
   --  Return True if an interrupt above the threshold is pending for the
   --  current hart.

   procedure Enable (Interrupt : BBI.Interrupt_ID);
   --  Enable an interrupt for the current hart

   function Claimed (Interrupt : BBI.Interrupt_ID) return Boolean
     with Ghost;
   --  Return True if the interrupt is claimed.
   --
   --  Note: This function is declared as ghost because it is only used for
   --  specification and doesn't correspond to a hardware feature of the PLIC.

   function Claim return BBI.Any_Interrupt_ID
     with Post => Claim'Result = BBI.No_Interrupt
                    or else
                  Claimed (Claim'Result);
   --  Claim an interrupt on the PLIC for the current hart and return its ID.
   --  Return No_Interrupt if there was no pending interrupts for the hart when
   --  the claim was serviced.
   --
   --  Note: According to the RISC-V Privileged Architecture Specification
   --  (version 1.10), it is possible to claim interrupts even if their
   --  priority is below the threshold. Doing this in a Ravenscar context will
   --  lead to priority inversion.

   procedure Complete (Interrupt : BBI.Interrupt_ID)
     with Pre  => Claimed (Interrupt),
          Post => not Claimed (Interrupt);
   --  Signal an interrupt completion for the current hart.

   procedure Set_Priority_Threshold (Priority : Integer);
   --  Set the interrupt priority threshold for the current hart.
   --
   --  Only interrupts with a priority strictly greater than the threshold will
   --  be able to trigger a trap.

   function Threshold return Integer;
   --  Return the priority threshold for the current hart

   procedure Set_Priority
     (Interrupt : System.BB.Interrupts.Interrupt_ID;
      Prio      : Interrupt_Priority);
   --  Set the priority of an interrupt (a source has one priority for all
   --  harts)

   function Priority_Of_Interrupt
     (Interrupt : System.BB.Interrupts.Interrupt_ID)
     return System.Any_Priority;
   --  Return the priority of an interrupt

end System.BB.RISCV_PLIC;
