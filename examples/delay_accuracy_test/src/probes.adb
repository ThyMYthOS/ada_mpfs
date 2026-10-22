--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Warnings (Off, "*is an internal GNAT unit");
pragma Warnings (Off, "use of this unit is non-portable*");
--  System.BB.RISCV_CLINT is a unit of the runtime

with Bare_Console;
with CSR;
with System.BB.RISCV_CLINT;
with System.Storage_Elements;

package body Probes is

   package CLINT renames System.BB.RISCV_CLINT;

   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_64;

   Wfi_Low  : constant Interfaces.Unsigned_16 := 16#0073#;
   Wfi_High : constant Interfaces.Unsigned_16 := 16#1050#;

   protected body Observed is

      procedure Arm is
      begin
         Armed := True;
      end Arm;

      entry Wait_Armed when Armed is
      begin
         Armed := False;
      end Wait_Armed;

      procedure Sampled (Mtimecmp, Mtime : Interfaces.Unsigned_64) is
      begin
         Cmp_Sample := Mtimecmp;
         Time_Sample := Mtime;
         Count := Count + 1;
      end Sampled;

      function Mtimecmp return Interfaces.Unsigned_64 is (Cmp_Sample);
      function Mtime return Interfaces.Unsigned_64 is (Time_Sample);
      function Samples return Natural is (Count);

   end Observed;

   task body Observer is
      Hart : constant CLINT.Hart_Id := CLINT.Hart_Id (Bare_Console.Hart_Id);
   begin
      loop
         Observed.Wait_Armed;
         --  Only here when the main program, of higher priority, sleeps
         Observed.Sampled
           (Interfaces.Unsigned_64 (CLINT.Mtimecmp (Hart)),
            Interfaces.Unsigned_64 (CLINT.Mtime));
      end loop;
   end Observer;

   protected body Fired is

      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event)
      is
         pragma Unreferenced (Event);
      begin
         Runs := Runs + 1;
         At_Mtime := Interfaces.Unsigned_64 (CLINT.Mtime);
      end Handle;

      function Count return Natural is (Runs);
      function Mtime return Interfaces.Unsigned_64 is (At_Mtime);

   end Fired;

   protected body Idle is

      procedure Handle
        (Event : in out Ada.Real_Time.Timing_Events.Timing_Event)
      is
         pragma Unreferenced (Event);

         Epc  : constant Interfaces.Unsigned_64 := CSR.Mepc;
         --  Interrupts are off in the alarm handler: mepc is still the pc
         --  of the interrupted instruction (the one after a wfi that was
         --  woken up)
         --  wfi is 16#1050_0073#, read as two halfwords: a 4-byte
         --  instruction can sit on a 2-byte boundary and the U54 traps a
         --  misaligned load
         Low  : Interfaces.Unsigned_16
           with Import, Volatile,
                Address => System.Storage_Elements.To_Address
                  (System.Storage_Elements.Integer_Address (Epc - 4));
         High : Interfaces.Unsigned_16
           with Import, Volatile,
                Address => System.Storage_Elements.To_Address
                  (System.Storage_Elements.Integer_Address (Epc - 2));
      begin
         Count := Count + 1;
         Pc := Epc;
         if Low = Wfi_Low and then High = Wfi_High then
            Hits := Hits + 1;
         end if;
      end Handle;

      function Runs return Natural is (Count);
      function In_Wfi return Natural is (Hits);
      function Mepc return Interfaces.Unsigned_64 is (Pc);

   end Idle;

end Probes;
