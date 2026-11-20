--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The body of Spike: see the spec.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Interfaces;

with Console;
with MPFS_Init_Table;

package body Spike is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Mss_Init.Timeout_Policy;
   use MPFS_Init_Table;

   subtype U64 is Interfaces.Unsigned_64;

   procedure Hex (Value : Word);
   procedure Dec (Value : Natural);
   procedure Prefix (Image : String);

   procedure Hex (Value : Word) is
   begin
      Console.Put_Hex (U64 (Value), 8);
   end Hex;

   procedure Dec (Value : Natural) is
   begin
      Console.Put_Dec (U64 (Value));
   end Dec;

   procedure Prefix (Image : String) is
   begin
      Console.Put (Image);
      Console.Put (": ");
   end Prefix;

   procedure Run (Image : String; Policy : Mss_Init.Timeout_Policy) is
      Result  : Mss_Init.Run_Result;
      Printed : Natural := 0;
      T0, T1  : U64;
   begin
      Prefix (Image);
      Console.Put ("MSS init from ");
      Console.Put_Line (XML_Source);
      Prefix (Image);
      Console.Put_Line (Design);
      Prefix (Image);
      Console.Put ("xml sha256 ");
      Console.Put_Line (XML_SHA256);
      Prefix (Image);
      Dec (Step_Count);
      Console.Put (" table entries in ");
      Dec (Phase_Count);
      Console.Put (" phases, a poll that times out ");
      if Policy = Mss_Init.Stop then
         Console.Put_Line ("stops the sequence");
      else
         Console.Put_Line ("is reported and the sequence goes on");
      end if;

      for Index in Phases'Range loop
         declare
            P : Phase renames Phases (Index);
            Before : constant Natural := Result.Executed;
            Timeouts_Before : constant Natural := Result.Timeouts;
         begin
            Mss_Init.Run_Phase (Index, Policy, Result);
            Prefix (Image);
            Console.Put ("phase ");
            Dec (Index);
            Console.Put (" ");
            Console.Put (Texts (P.Name_First .. P.Name_Last));
            Console.Put (": entries ");
            Dec (P.First);
            Console.Put ("-");
            Dec (P.Last);
            Console.Put (", ");
            Dec (Result.Executed - Before);
            Console.Put (" run, ");
            Dec (Result.Timeouts - Timeouts_Before);
            Console.Put (" poll timeout(s), mtime ");
            Console.Put_Hex (Mss_Init.Read_64 (MTIME_Address), 8);
            Console.Put_Line ("");
            while Printed < Result.Timeouts
              and then Printed < Mss_Init.Max_Timeouts
            loop
               Printed := Printed + 1;
               declare
                  T : Mss_Init.Timeout renames Result.Seen (Printed);
                  S : Step renames Steps (T.Step);
               begin
                  Prefix (Image);
                  Console.Put ("TIMEOUT entry ");
                  Dec (T.Step);
                  Console.Put (": ");
                  Console.Put (Texts (S.Text_First .. S.Text_Last));
                  Console.Put (", ");
                  Hex (S.Address);
                  Console.Put (" and ");
                  Hex (S.Mask);
                  Console.Put (" is ");
                  Hex (T.Value and S.Mask);
                  Console.Put (", wanted ");
                  Hex (S.Value);
                  Console.Put_Line ("");
               end;
            end loop;
         end;
         exit when Result.Stopped;
      end loop;

      --  The proofs: they read what the sequence is meant to have made.
      T0 := Mss_Init.Read_64 (MTIME_Address);
      Mss_Init.Wait (100);
      T1 := Mss_Init.Read_64 (MTIME_Address);
      Prefix (Image);
      Console.Put ("mtime ");
      Console.Put_Hex (T0, 8);
      Console.Put (" then ");
      Console.Put_Hex (T1, 8);
      Console.Put (" after 100 us by mcycle: ");
      if T1 > T0 then
         Console.Put_Line ("advancing");
      else
         Console.Put_Line ("NOT advancing");
      end if;

      declare
         Control : constant Word := Mss_Init.Read (PLL_Control_Address);
      begin
         Prefix (Image);
         Console.Put ("MSS PLL: PLL_CTRL ");
         Hex (Control);
         Console.Put (", LOCK ");
         if (Control and PLL_Control_Lock) /= 0 then
            Console.Put_Line ("1");
         else
            Console.Put_Line ("0");
         end if;
      end;

      Prefix (Image);
      Dec (Result.Executed);
      Console.Put (" of ");
      Dec (Step_Count);
      Console.Put (" entries run, ");
      Dec (Result.Timeouts);
      Console.Put_Line (" poll timeout(s)");
      Prefix (Image);
      if Result.Stopped then
         Console.Put_Line ("MSS INIT FAILED");
      elsif Result.Timeouts > 0 then
         Console.Put_Line ("MSS INIT DONE WITH TIMEOUTS");
      else
         Console.Put_Line ("MSS INIT OK");
      end if;
   end Run;

end Spike;
