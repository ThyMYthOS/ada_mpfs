--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Bare_Console;
with Interfaces;
with System.Machine_Code; use System.Machine_Code;
with System.Storage_Elements;
with Test_Report;

package body Trap_Last_Chance is

   use type Ada.Exceptions.Exception_Id;
   use type Interfaces.Unsigned_64;

   Illegal_Instr  : constant := 2;
   --  mcause of an illegal instruction

   Fault_Encoding : constant := 16#C000_1073#;
   --  mtval: the instruction (QEMU, and most cores) or 0 (allowed)

   --  fault.S of examples/trap_test: the address of the illegal instruction
   Fault_Insn : constant Character
     with Import, Convention => C, External_Name => "trap_test_fault_insn";

   function Mcause return Interfaces.Unsigned_64;
   function Mepc return Interfaces.Unsigned_64;
   function Mtval return Interfaces.Unsigned_64;

   function Mcause return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      Asm ("csrr %0, mcause",
           Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
           Volatile => True);
      return Value;
   end Mcause;

   function Mepc return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      Asm ("csrr %0, mepc",
           Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
           Volatile => True);
      return Value;
   end Mepc;

   function Mtval return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      Asm ("csrr %0, mtval",
           Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
           Volatile => True);
      return Value;
   end Mtval;

   -------------
   -- Handler --
   -------------

   procedure Handler (Except : Ada.Exceptions.Exception_Occurrence) is
      Cause : constant Interfaces.Unsigned_64 := Mcause;
      Pc    : constant Interfaces.Unsigned_64 := Mepc;
      Tval  : constant Interfaces.Unsigned_64 := Mtval;
   begin
      Calls := Calls + 1;
      Test_Report.Check (Calls = 1, "the last chance handler is called once");
      Test_Report.Check
        (Ada.Exceptions.Exception_Identity (Except) = Program_Error'Identity,
         "the trap ends as Program_Error");
      Test_Report.Check
        (Ada.Exceptions.Exception_Message (Except) = "Unhandled trap: 2",
         "the message names the cause");
      Test_Report.Check
        (Cause = Illegal_Instr, "mcause is 2 (illegal instruction)");
      Test_Report.Check
        (Pc = Interfaces.Unsigned_64
           (System.Storage_Elements.To_Integer (Fault_Insn'Address)),
         "mepc is the address of the illegal instruction");
      Test_Report.Check
        (Tval = Fault_Encoding or else Tval = 0,
         "mtval is the illegal instruction or 0");
      Test_Report.Info ("mcause", Bare_Console.U64 (Cause));
      Test_Report.Info ("mepc", Bare_Console.U64 (Pc));
      Test_Report.Info ("mtval", Bare_Console.U64 (Tval));
      Test_Report.Finish;
   end Handler;

end Trap_Last_Chance;
