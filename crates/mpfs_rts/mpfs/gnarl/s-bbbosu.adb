--  SPDX-FileCopyrightText: 1999-2002 Universidad Politecnica de Madrid
--  SPDX-FileCopyrightText: 2003-2005 The European Space Agency
--  SPDX-FileCopyrightText: 2003-2020 AdaCore
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes src/s-bbbosu__riscv.adb @ 09e7cd6
--  (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC:
--  Power_Down is wfi.
--
--  Idle (master plan #41, work package P1.6). Power_Down is called only by
--  the idle task (System.Task_Primitives.Operations.Idle) with
--  mstatus.MIE set and the PLIC threshold at 0, in a loop that has no state
--  of its own: wfi returns when an interrupt that is enabled in mie is
--  pending (the machine timer MTIE, an external interrupt MEIE; the software
--  interrupt MSIE is not enabled on a running hart), whatever mstatus.MIE
--  says, and the trap is then taken before the next instruction. A wfi that
--  returns without a trap (the architecture allows it, and it is what a
--  pending interrupt does if MIE were clear) costs one more turn of the loop,
--  never a lost wake-up: no condition is tested between the decision to idle
--  and the wfi.

with System.Machine_Code;
with System.BB.CPU_Specific;
with System.BB.RISCV_PLIC;

package body System.BB.Board_Support is

   package PLIC renames RISCV_PLIC;

   procedure External_Interrupt_Trap_Handler
     (Unused : BB.Interrupts.Interrupt_ID);
   --  Procedure called in case of external interrupt trap

   -----------------------------
   -- External_Interrupt_Trap --
   -----------------------------

   procedure External_Interrupt_Trap_Handler
     (Unused : BB.Interrupts.Interrupt_ID)
   is
      Int_Id : BB.Interrupts.Any_Interrupt_ID;
   begin

      --  While there is at least one pending interrupt above threshold for the
      --  current hart...
      while PLIC.Pending loop

         --  Claim the interrupt
         Int_Id := PLIC.Claim;

         if Int_Id /= BB.Interrupts.No_Interrupt then

            --  Note: There is a situation where we might service an interrupt
            --  below the threshold. If an interrupt above threshold is
            --  triggered, causes the external interrupt trap, but is then
            --  clear before we can claim it. In that situation, we will claim
            --  whatever interrupt is pending at the time, potentially an
            --  interrupt below the threshold. This risk is limited by the fact
            --  that we check if an interrupt if pending for the current hart
            --  before doing a claim. So the faulty situation can only occur if
            --  the interrupt is cleared from the source between the call to
            --  Pending and the call to Claim.
            pragma Assert
              (PLIC.Priority_Of_Interrupt (Int_Id) > PLIC.Threshold);

            --  Call the wrapper that will execute the interrupt handler
            BB.Interrupts.Interrupt_Wrapper (Int_Id);

            --  It is not possible to claim a new interrupt until the current
            --  one is signaled as completed. So we signal completion right
            --  away to allow nested interrupt handling.
            PLIC.Complete (Int_Id);
         else
            exit;
         end if;
      end loop;

   end External_Interrupt_Trap_Handler;

   ----------------------
   -- Initialize_Board --
   ----------------------

   procedure Initialize_Board is
   begin
      PLIC.Initialize;

      CPU_Specific.Install_Trap_Handler
        (External_Interrupt_Trap_Handler'Access,
         CPU_Specific.External_Interrupt_Trap);
   end Initialize_Board;

   package body Interrupts is

      -------------------------------
      -- Install_Interrupt_Handler --
      -------------------------------

      procedure Install_Interrupt_Handler
        (Interrupt : System.BB.Interrupts.Interrupt_ID;
         Prio      : Interrupt_Priority)
      is
      begin

         --  For the PLIC there is nothing more to do than setting the priority
         --  and enable the interrupt. All interrupts go to the same trap
         --  handler before being dispatched.
         PLIC.Set_Priority (Interrupt, Prio);
         PLIC.Enable (Interrupt);

      end Install_Interrupt_Handler;

      ---------------------------
      -- Priority_Of_Interrupt --
      ---------------------------

      function Priority_Of_Interrupt
        (Interrupt : System.BB.Interrupts.Interrupt_ID)
        return System.Any_Priority
      is (PLIC.Priority_Of_Interrupt (Interrupt));

      ----------------
      -- Power_Down --
      ----------------

      procedure Power_Down is
      begin
         System.Machine_Code.Asm ("wfi", Volatile => True, Clobber => "memory");
      end Power_Down;

      --------------------------
      -- Set_Current_Priority --
      --------------------------

      procedure Set_Current_Priority (Priority : Integer) is
      begin
         PLIC.Set_Priority_Threshold (Priority);
      end Set_Current_Priority;
   end Interrupts;

   package body Time is separate;

   package body Multiprocessors is separate;
end System.BB.Board_Support;
