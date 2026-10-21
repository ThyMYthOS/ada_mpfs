--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Command_Line;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

package body Host_Report is

   use Ada.Strings.Unbounded;

   Test_Name : Unbounded_String := To_Unbounded_String ("unnamed");
   Checks    : Natural := 0;
   Failed    : Natural := 0;

   procedure Start (Name : String) is
   begin
      Test_Name := To_Unbounded_String (Name);
      Checks := 0;
      Failed := 0;
      --  Fail closed: only Finish may turn this into Success.
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      Ada.Text_IO.Put_Line ("TEST " & Name & ": START");
   end Start;

   procedure Check (Condition : Boolean; What : String) is
   begin
      Checks := Checks + 1;
      if Condition then
         Ada.Text_IO.Put_Line ("  ok: " & What);
      else
         Failed := Failed + 1;
         Ada.Text_IO.Put_Line ("  FAIL: " & What);
      end if;
   end Check;

   procedure Finish is
   begin
      if Checks = 0 then
         Ada.Text_IO.Put_Line ("  FAIL: the test made no checks at all");
         Failed := Failed + 1;
      end if;
      Ada.Text_IO.Put_Line
        ("TEST " & To_String (Test_Name) & ": "
         & (if Failed = 0 then "PASS" else "FAIL"));
      Ada.Command_Line.Set_Exit_Status
        (if Failed = 0 then Ada.Command_Line.Success
         else Ada.Command_Line.Failure);
   end Finish;

   function Failures return Natural is (Failed);

end Host_Report;
