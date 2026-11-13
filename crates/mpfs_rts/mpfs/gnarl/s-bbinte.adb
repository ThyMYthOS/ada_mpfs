--  SPDX-FileCopyrightText: 1999-2002 Universidad Politecnica de Madrid
--  SPDX-FileCopyrightText: 2003-2005 The European Space Agency
--  SPDX-FileCopyrightText: 2003-2025 AdaCore
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  Derived from alire-project/bb-runtimes
--  gnat_rts_sources/include/rts-sources/gnarl/common/s-bbinte.adb @ 09e7cd6
--  (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC:
--  the size of the interrupt stack is not a constant of the runtime
--  (System.BB.Parameters.Interrupt_Stack_Size) but the partition data of the
--  image, __interrupt_stack_size, which the linker script turns into the
--  space between __interrupt_stack_start and __interrupt_stack_end. The
--  runtime used to declare an array of the size of the constant, and the
--  partition data was only an upper bound (a link error if the array was
--  larger): a larger value changed nothing and a smaller one could not be
--  linked. Now ./x build --interrupt-stack-size is the size of the stack.
--
--  The guard word at the lower end of the interrupt stack (issue #91): the
--  trap handler (trap_handler.S) checks it at the exit of every trap, the last
--  chance handler of the runtime checks it, and Stack_Overflow below is what
--  the trap handler calls when it is not intact. Initialize_Interrupts arms it.
--  Nothing else of the unit changed.
--
--  @req RTS-022, RTS-023

pragma Restrictions (No_Elaboration_Code);

with System.Storage_Elements;
with System.BB.CPU_Primitives;
with System.BB.Threads;
with System.BB.Threads.Queues;
with System.BB.Board_Support;
with System.BB.Time;
with System.Multiprocessors;

package body System.BB.Interrupts is

   use System.Multiprocessors;
   use System.Storage_Elements;
   use System.BB.Board_Support.Multiprocessors;
   use System.BB.Threads;
   use System.BB.Time;

   ----------------
   -- Local data --
   ----------------

   Interrupt_Stack_Start : constant Character
     with Import, Convention => C, External_Name => "__interrupt_stack_start";
   Interrupt_Stack_End   : constant Character
     with Import, Convention => C, External_Name => "__interrupt_stack_end";
   --  The stacks of all CPUs, one after the other. The linker script
   --  (crates/mpfs_rts/ld/sections.ld) makes them __interrupt_stack_size bytes
   --  for each object of Interrupt_Stack_Marker, and none if this unit is not
   --  linked; the stack of a CPU is the part of its index. Both are
   --  multiples of 16 (ASSERT of the script).

   Interrupt_Stack_Marker : array (CPU) of Storage_Elements.Storage_Element;
   pragma Warnings (Off, Interrupt_Stack_Marker);
   pragma Linker_Section (Interrupt_Stack_Marker, ".noinit.interrupt_stacks");
   --  Not a stack: one byte per CPU, which the linker script (KEEP) turns into
   --  the space of one stack, so that an image that does not link this unit
   --  has no interrupt stack at all. Never read or written. The section is
   --  the one that the script places at __interrupt_stack_start; the
   --  ".noinit" in its name makes the compiler flag the object as not
   --  initialised.
   --
   --  Having a separate interrupt stack (from user tasks stack) helps to
   --  reduce the memory footprint, as there is no need to reserve space for
   --  interrupts in user stacks.
   --
   --  Because several interrupts can share the same priority and because there
   --  can be many priorities, we prefer not to have one stack per priority.
   --  Instead we have one interrupt stack per CPU. Such interrupts cannot be
   --  executing at the same time.
   --
   --  An interrupt handler doesn't need to save non-volatile registers,
   --  because the interrupt is always completed before the interrupted task is
   --  resumed. This is obvious for non-interrupt-priority tasks and for
   --  active tasks at interrupt priority. The idle task (the one activated in
   --  System.BB.Protection.Leave_Kernel) cannot be at interrupt priority, as
   --  there is always one task not in the interrupt priority range (the
   --  environment task), and this one must be active or idle when a higher
   --  priority task is resumed.

   procedure Arm_Guard;
   pragma Import (Asm, Arm_Guard, "__mpfs_interrupt_guard_arm");
   --  Writes the guard word at the lower end of the interrupt stack (trap_handler.S, which
   --  also arms it before main through .preinit_array: this call makes sure that an image
   --  that uses the interrupt stack has the code, and re-arms the word).

   procedure Stack_Overflow;
   pragma Export (Asm, Stack_Overflow, "__mpfs_interrupt_stack_overflow");
   pragma No_Return (Stack_Overflow);
   --  Called by the trap handler (trap_handler.S) when the guard word is not intact, on the
   --  stack of the environment task: the program ends in the last chance handler with
   --  this message, there is no way back (no restart of the partition).

   Interrupt_Stack_Table : array (CPU) of System.Address;
   pragma Export (Asm, Interrupt_Stack_Table, "interrupt_stack_table");
   --  Table that contains a pointer to the top of the stack for each processor

   type Handlers_Table is array (Interrupt_ID) of Interrupt_Handler;
   --  Type used to represent the procedures used as interrupt handlers

   Interrupt_Handlers_Table : Handlers_Table := (others => null);
   --  Table containing handlers attached to the different external interrupts

   Interrupt_Being_Handled : array (CPU) of Any_Interrupt_ID :=
                               (others => No_Interrupt);
   pragma Volatile (Interrupt_Being_Handled);
   --  Interrupt_Being_Handled contains the interrupt currently being handled
   --  by each CPU in the system, if any. It is equal to No_Interrupt when no
   --  interrupt is handled. Its value is updated by the trap handler.

   --------------------
   -- Attach_Handler --
   --------------------

   procedure Attach_Handler
     (Handler : not null Interrupt_Handler;
      Id      : Interrupt_ID;
      Prio    : Interrupt_Priority)
   is
   begin
      --  Check that we are attaching to a real interrupt

      pragma Assert (Id /= No_Interrupt);

      --  Check that no previous interrupt handler has been registered

      if Interrupt_Handlers_Table (Id) /= null then
         raise Program_Error;
      end if;

      --  Copy the user's handler to the appropriate place within the table

      Interrupt_Handlers_Table (Id) := Handler;

      --  The BSP determines the vector that will be called when the given
      --  interrupt occurs, and then installs the handler there. This may
      --  include programming the interrupt controller.

      Board_Support.Interrupts.Install_Interrupt_Handler (Id, Prio);
   end Attach_Handler;

   -----------------------
   -- Current_Interrupt --
   -----------------------

   function Current_Interrupt return Any_Interrupt_ID is
      Result : constant Any_Interrupt_ID :=
                  Interrupt_Being_Handled (Current_CPU);

   begin
      if Threads.Thread_Self.In_Interrupt then

         pragma Assert (Result /= No_Interrupt);
         return Result;

      else
         return No_Interrupt;
      end if;
   end Current_Interrupt;

   -----------------------
   -- Interrupt_Wrapper --
   -----------------------

   procedure Interrupt_Wrapper (Id : Interrupt_ID) is
      Self_Id         : constant Threads.Thread_Id := Threads.Thread_Self;
      Caller_Priority : constant Integer := Threads.Get_Priority (Self_Id);
      Int_Priority    : constant Interrupt_Priority :=
                          Board_Support.Interrupts.Priority_Of_Interrupt (Id);
      CPU_Id          : constant CPU          := Current_CPU;
      Previous_Int    : constant Any_Interrupt_ID :=
                          Interrupt_Being_Handled (CPU_Id);
      Prev_In_Interr  : constant Boolean := Self_Id.In_Interrupt;

   begin
      --  Update execution time for the interrupted task

      if Scheduling_Event_Hook /= null then
         Scheduling_Event_Hook.all;
      end if;

      --  Store the interrupt being handled

      Interrupt_Being_Handled (CPU_Id) := Id;

      --  Then, we must set the appropriate software priority corresponding
      --  to the interrupt being handled. It also deals with the appropriate
      --  interrupt masking.

      --  When this wrapper is called all interrupts are masked, and the active
      --  priority of the interrupted task must be lower than the priority of
      --  the interrupt (otherwise the interrupt would have been masked). The
      --  only exception to this is when a task is temporarily inserted in the
      --  ready queue because there is not a single task ready to execute; this
      --  temporarily inserted task may have a priority in the range of the
      --  interrupt priorities (it may be waiting in an entry for a protected
      --  handler), but interrupts would not be masked.

      pragma Assert
        (Caller_Priority <= Int_Priority or else Self_Id.State /= Runnable);

      Self_Id.In_Interrupt := True;
      Threads.Queues.Change_Priority (Self_Id, Int_Priority);

      CPU_Primitives.Enable_Interrupts (Int_Priority);

      --  Call the user handler

      if Interrupt_Handlers_Table (Id) = null then
         raise Program_Error with "No handler for interrupt";
      else
         Interrupt_Handlers_Table (Id).all (Id);
      end if;

      CPU_Primitives.Disable_Interrupts;

      --  Update execution time for the interrupt. This must be done before
      --  changing priority (Scheduling_Event use priority to determine which
      --  task/interrupt will get the elapsed time).

      if Scheduling_Event_Hook /= null then
         Scheduling_Event_Hook.all;
      end if;

      --  Restore the software priority to the state before the interrupt
      --  happened. Interrupt unmasking is not done here (it will be done
      --  later by the interrupt epilogue).

      Threads.Queues.Change_Priority (Self_Id, Caller_Priority);

      --  Restore the interrupt that was being handled previously (if any)

      Interrupt_Being_Handled (CPU_Id) := Previous_Int;

      --  Restore previous interrupt number (which is False unless interrupt
      --  is nested).

      Self_Id.In_Interrupt := Prev_In_Interr;

      --  Switch back to previous priority
      --
      --  The priority used (Caller_Priority) may not be correct if a task has
      --  been unblocked. But in that case, the task was blocked inside the
      --  kernel (so with interrupt disabled), and the correct priority will
      --  be set by Leave_Kernel.

      Board_Support.Interrupts.Set_Current_Priority (Caller_Priority);
   end Interrupt_Wrapper;

   ----------------------------
   -- Within_Interrupt_Stack --
   ----------------------------

   function Within_Interrupt_Stack
     (Stack_Address : System.Address) return Boolean
   is
      (Current_Interrupt /= No_Interrupt and then To_Integer (Stack_Address) in
          To_Integer (Interrupt_Stack_Start'Address)
             ..
          To_Integer (Interrupt_Stack_End'Address) - 1);

   --------------------
   -- Stack_Overflow --
   --------------------

   procedure Stack_Overflow is
   begin
      raise Program_Error with "interrupt stack overflow";
   end Stack_Overflow;

   ---------------------------
   -- Initialize_Interrupts --
   ---------------------------

   procedure Initialize_Interrupts is
      Size : constant Storage_Elements.Storage_Offset :=
               (Interrupt_Stack_End'Address - Interrupt_Stack_Start'Address)
               / Storage_Elements.Storage_Offset (CPU'Last - CPU'First + 1);
      --  The stack of each CPU: the space that the linker script reserved
   begin
      Arm_Guard;

      for Proc in CPU loop

         CPU_Primitives.Initialize_Stack
           (Interrupt_Stack_Start'Address
              + Storage_Elements.Storage_Offset (Proc - CPU'First) * Size,
            Size,
            Interrupt_Stack_Table (Proc));
      end loop;
   end Initialize_Interrupts;
end System.BB.Interrupts;
