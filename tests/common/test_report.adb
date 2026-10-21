--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;

package body Test_Report is

   Max_Name : constant := 40;

   Name_Buf : String (1 .. Max_Name);
   Name_Len : Natural := 0;
   Checks   : Natural := 0;
   Failures : Natural := 0;

   procedure Start (Name : String) is
      N : constant Natural := Natural'Min (Name'Length, Max_Name);
   begin
      --  A loop, not a slice assignment: there is no memmove to link.
      for I in 1 .. N loop
         Name_Buf (I) := Name (Name'First + I - 1);
      end loop;
      Name_Len := N;
      Put ("TEST ");
      Put (Name_Buf (1 .. Name_Len));
      Put_Line (": START");
   end Start;

   procedure Check (Condition : Boolean; What : String) is
   begin
      Checks := Checks + 1;
      if Condition then
         Put ("  ok: ");
      else
         Failures := Failures + 1;
         Put ("  FAIL: ");
      end if;
      Put_Line (What);
   end Check;

   procedure Info (What : String; Value : U64) is
   begin
      Put ("  info: ");
      Put (What);
      Put (" = ");
      Put_Dec (Value);
      Put_Line ("");
   end Info;

   procedure Finish is
   begin
      if Checks = 0 then
         Put_Line ("  FAIL: the test made no checks at all");
         Failures := Failures + 1;
      end if;
      Put ("TEST ");
      Put (Name_Buf (1 .. Name_Len));
      Put (": ");
      Put_Line (if Failures = 0 then "PASS" else "FAIL");
      loop
         null;
      end loop;
   end Finish;

end Test_Report;
