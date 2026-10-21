--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

with Ada.Unchecked_Conversion;
with Bare_Console;
with Interfaces;
with Test_Report;

package body Early_Trap is

   use type Bare_Console.U64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  The layout of the trap record (start.S).
   type Trap_Record is record
      Mcause : Interfaces.Unsigned_64;
      Mepc   : Interfaces.Unsigned_64;
      Mtval  : Interfaces.Unsigned_64;
      Magic  : Interfaces.Unsigned_32;
      Hart   : Interfaces.Unsigned_32;
   end record
     with Size => 256;
   for Trap_Record use record
      Mcause at  0 range 0 .. 63;
      Mepc   at  8 range 0 .. 63;
      Mtval  at 16 range 0 .. 63;
      Magic  at 24 range 0 .. 31;
      Hart   at 28 range 0 .. 31;
   end record;

   Trap_Magic     : constant := 16#5452_4150#;
   Illegal_Instr  : constant := 2;
   --  mtval of an illegal instruction: the instruction (QEMU, and most
   --  cores) or 0 (allowed)
   Fault_Encoding : constant := 16#C000_1073#;

   --  fault.S: a procedure whose only instruction is the illegal one, and
   --  the address of that instruction
   procedure Fault
     with Import, Convention => C, External_Name => "trap_test_fault",
          No_Return;
   Fault_Insn : constant Character
     with Import, Convention => C, External_Name => "trap_test_fault_insn";

   function To_U64 is new Ada.Unchecked_Conversion
     (System.Address, Bare_Console.U64);

   type Trap_Ptr is access constant Trap_Record;
   function To_Ptr is new Ada.Unchecked_Conversion (System.Address, Trap_Ptr);

   ----------
   -- Hook --
   ----------

   procedure Hook (Record_Address : System.Address) is
      Rec : Trap_Record renames To_Ptr (Record_Address).all;
      Id  : constant Bare_Console.U64 := Bare_Console.Hart_Id;
   begin
      Test_Report.Start (if Id = 0 then "trap_test_e51" else "trap_test_u54");
      Test_Report.Check
        (Rec.Magic = Trap_Magic, "the trap stub wrote the record (magic)");
      Test_Report.Check
        (Bare_Console.U64 (Rec.Hart) = Id, "the record names this hart");
      Test_Report.Check
        (Rec.Mcause = Illegal_Instr, "mcause is 2 (illegal instruction)");
      Test_Report.Check
        (Bare_Console.U64 (Rec.Mepc) = To_U64 (Fault_Insn'Address),
         "mepc is the address of the illegal instruction");
      Test_Report.Check
        (Rec.Mtval = Fault_Encoding or else Rec.Mtval = 0,
         "mtval is the illegal instruction or 0");
      Test_Report.Info ("mcause", Bare_Console.U64 (Rec.Mcause));
      Test_Report.Info ("mepc", Bare_Console.U64 (Rec.Mepc));
      Test_Report.Info ("mtval", Bare_Console.U64 (Rec.Mtval));
      Test_Report.Finish;
   end Hook;

begin
   --  Before the main program, with the stub as the only trap handler.
   Fault;
end Early_Trap;
