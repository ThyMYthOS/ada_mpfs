--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The body of Mss_Init: see the spec.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with System.Machine_Code;

package body Mss_Init is

   use MPFS_Init_Table;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   procedure Write (Register : System.Address; Value : Word);
   procedure Poll (Item : Step; Done : out Boolean; Last : out Word);

   function Read (Register : System.Address) return Word is
      Word_At : Word with Volatile, Import, Address => Register;
   begin
      return Word_At;
   end Read;

   function Read_64 (Register : System.Address)
     return Interfaces.Unsigned_64
   is
      Word_At : Interfaces.Unsigned_64
        with Volatile, Import, Address => Register;
   begin
      return Word_At;
   end Read_64;

   procedure Write (Register : System.Address; Value : Word) is
      Word_At : Word with Volatile, Import, Address => Register;
   begin
      Word_At := Value;
   end Write;

   function Cycles return Interfaces.Unsigned_64 is
      Value : Interfaces.Unsigned_64;
   begin
      System.Machine_Code.Asm
        ("csrr %0, mcycle",
         Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Value),
         Volatile => True);
      return Value;
   end Cycles;

   procedure Wait (Microseconds : Word) is
      Start : constant Interfaces.Unsigned_64 := Cycles;
      Span  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Microseconds) * Cycles_Per_Microsecond;
   begin
      while Cycles - Start < Span loop
         null;
      end loop;
   end Wait;

   --  Reads until the masked word is the wanted one; Done is False after
   --  Item.Count microseconds, with the last word read in Last.
   procedure Poll (Item : Step; Done : out Boolean; Last : out Word) is
      Start : constant Interfaces.Unsigned_64 := Cycles;
      Span  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Item.Count) * Cycles_Per_Microsecond;
   begin
      loop
         Last := Read (Item.Register);
         if (Last and Item.Mask) = Item.Value then
            Done := True;
            return;
         end if;
         exit when Cycles - Start >= Span;
      end loop;
      Done := False;
   end Poll;

   procedure Run_Phase
     (Index  : Positive;
      Policy : Timeout_Policy;
      Result : in out Run_Result)
   is
      Item : Positive := Phases (Index).First;
      Done : Boolean;
      Last : Word;
   begin
      while Item <= Phases (Index).Last and then not Result.Stopped loop
         declare
            S : Step renames Steps (Item);
         begin
            Result.Executed := Result.Executed + 1;
            case S.Kind is
               when Write =>
                  Write (S.Register, S.Value);
               when Modify =>
                  Write
                    (S.Register,
                     (Read (S.Register) or S.Value) and not S.Mask);
               when Poll =>
                  Poll (S, Done, Last);
                  if not Done then
                     Result.Timeouts := Result.Timeouts + 1;
                     if Result.Timeouts <= Max_Timeouts then
                        Result.Seen (Result.Timeouts) := (Item, Last);
                     end if;
                     Result.Stopped := Policy = Stop;
                  end if;
               when Wait =>
                  Wait (S.Count);
               when Skip_If_Clear =>
                  if (Read (S.Register) and S.Mask) = 0 then
                     Item := Item + Natural (S.Count);
                  end if;
            end case;
         end;
         Item := Item + 1;
      end loop;
   end Run_Phase;

end Mss_Init;
