--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Three library-level tasks that each hold a different value in every one
--  of fs0 .. fs11 and check that they still have it:
--
--    A, B   (priority 10) load the registers, wait 2 ms (delay until), and
--           check them; the other one runs, and loads its own values, in
--           between. Every check follows a switch through Context_Switch.
--    Spin   (priority 5) loads the registers and checks them in a loop
--           that never waits. The timer interrupt that wakes A or B takes it
--           away through the trap handler (trap frame, then context switch
--           from the trap) and gives it back the same way.
--
--  With the restore of context_switch.S from the context of the outgoing
--  task (the upstream defect, master plan appendix A no. 1) every task that
--  is switched in finds the registers of the one that was switched out, and
--  A, B and Spin report a mismatch.

with Interfaces;
with System;

package Holders is

   type Which is (A, B, Spin);

   type Counts is array (Which) of Natural;
   type Masks is array (Which) of Interfaces.Unsigned_32;

   protected Results with Priority => System.Priority'Last is
      procedure Checked (Task_Id : Which; Lost : Interfaces.Unsigned_32);
      --  one check of one task: Lost is Fp_Regs.Mismatch
      procedure Finished;
      function Rounds (Task_Id : Which) return Natural;
      function Bad (Task_Id : Which) return Interfaces.Unsigned_32;
      --  the OR of all masks of the task: 0 if it never lost a value
      function All_Finished return Boolean;
      procedure Stop;
      function Stopped return Boolean;
   private
      Count : Counts := [others => 0];
      Mask  : Masks := [others => 0];
      Ended : Natural := 0;
      Halt  : Boolean := False;
   end Results;

   task Holder_A with Priority => 10, Storage_Size => 4096;
   task Holder_B with Priority => 10, Storage_Size => 4096;
   task Spinner  with Priority => 5,  Storage_Size => 4096;

end Holders;
