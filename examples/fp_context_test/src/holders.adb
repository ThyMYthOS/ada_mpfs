--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Real_Time; use Ada.Real_Time;

with Fp_Regs;

package body Holders is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   protected body Results is

      procedure Checked (Task_Id : Which; Lost : Interfaces.Unsigned_32) is
      begin
         Count (Task_Id) := Count (Task_Id) + 1;
         Mask (Task_Id) := Mask (Task_Id) or Lost;
      end Checked;

      procedure Finished is
      begin
         Ended := Ended + 1;
      end Finished;

      function Rounds (Task_Id : Which) return Natural is (Count (Task_Id));

      function Bad (Task_Id : Which) return Interfaces.Unsigned_32
      is (Mask (Task_Id));

      function All_Finished return Boolean is (Ended = Which'Pos (Spin) + 1);

      procedure Stop is
      begin
         Halt := True;
      end Stop;

      function Stopped return Boolean is (Halt);

   end Results;

   Period : constant Time_Span := Milliseconds (2);

   --  The seeds differ in every byte: a register that holds the value of
   --  another task, or of an earlier round, is not mistaken for its own.
   function Seed (Task_Id : Which; Round : Natural)
     return Interfaces.Unsigned_64
   is ((case Task_Id is
          when A    => 16#A5A5_0000_1000_0000#,
          when B    => 16#5A3C_0000_2000_0000#,
          when Spin => 16#C3E1_0000_3000_0000#)
       + Interfaces.Unsigned_64 (Round) * 16#1_0000#);

   --  A and B run the same body, half a period apart.
   procedure Hold (Task_Id : Which; Offset : Time_Span);

   procedure Hold (Task_Id : Which; Offset : Time_Span) is
      Next  : Time := Clock + Offset;
      Round : Natural := 0;
   begin
      while not Results.Stopped loop
         Fp_Regs.Load (Seed (Task_Id, Round));
         Next := Next + Period;
         delay until Next;
         Results.Checked (Task_Id, Fp_Regs.Mismatch (Seed (Task_Id, Round)));
         Round := Round + 1;
      end loop;
      Results.Finished;
   end Hold;

   task body Holder_A is
   begin
      Hold (A, Milliseconds (10));
      delay until Time_Last;
   end Holder_A;

   task body Holder_B is
   begin
      Hold (B, Milliseconds (11));
      delay until Time_Last;
   end Holder_B;

   task body Spinner is
      Round : Natural := 0;
   begin
      while not Results.Stopped loop
         Fp_Regs.Load (Seed (Spin, Round));
         for Pass in 1 .. 2_000 loop
            Results.Checked (Spin, Fp_Regs.Mismatch (Seed (Spin, Round)));
         end loop;
         Round := Round + 1;
      end loop;
      Results.Finished;
      delay until Time_Last;
   end Spinner;

end Holders;
