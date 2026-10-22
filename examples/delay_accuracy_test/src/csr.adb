--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with System.Machine_Code; use System.Machine_Code;

package body CSR is

   function Mcycle return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      Asm ("csrr %0, mcycle",
           Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
           Volatile => True);
      return Value;
   end Mcycle;

   function Minstret return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      Asm ("csrr %0, minstret",
           Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
           Volatile => True);
      return Value;
   end Minstret;

   function Mip return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      Asm ("csrr %0, mip",
           Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
           Volatile => True);
      return Value;
   end Mip;

   function Mepc return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      Asm ("csrr %0, mepc",
           Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
           Volatile => True);
      return Value;
   end Mepc;

end CSR;
