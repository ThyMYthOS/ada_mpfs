--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  pmp_check FILE: the independent check of the PMP, the MPU and the way masks of a system, from the
--  check input FILE that `python3 config/gen/mpfs_gen derive --check-json FILE system.yaml` writes.
--
--  It prints one line per finding, `error: GEN-Exxx PATH: message` (or warning:, note:), then
--  `verdict: accepted` or `verdict: refused (N errors)`. Exit status: 0 accepted, 1 refused (an error:
--  for a prod system any rule of the PMP, the MPU or the cache partitioning that is not a warning, in
--  both profiles a rule of the way masks), 2 the arguments or the input are wrong.
--
--  This unit reads the file and writes the lines; it is not SPARK (file and console I/O). Everything
--  it calls is (tools/prove.list).
--
--  @req GEN-015, GEN-019

with Ada.Command_Line;
with Ada.Directories;
with Ada.Direct_IO;
with Ada.Text_IO;

with Pmp_Check.Findings;
with Pmp_Check.Json;
with Pmp_Check.Load;
with Pmp_Check.Model;
with Pmp_Check.Rules;
with Pmp_Check.Texts;

procedure Pmp_Check_Main
  with SPARK_Mode => Off
is
   use Ada.Text_IO;
   use Pmp_Check;
   use type Ada.Directories.File_Kind;
   use type Ada.Directories.File_Size;

   Usage_Status   : constant Ada.Command_Line.Exit_Status := 2;
   Refused_Status : constant Ada.Command_Line.Exit_Status := 1;

   --  Library-level objects would do as well; these live in the heap so that the stack stays small.
   type Document_Access is access Json.Document;
   type System_Access is access Model.System;
   type List_Access is access Findings.List;

   Doc  : constant Document_Access := new Json.Document;
   Sys  : constant System_Access := new Model.System;
   List : constant List_Access := new Findings.List;

   function Read_File (Name : String) return String is
      Size : constant Natural := Natural (Ada.Directories.Size (Name));
      subtype Content is String (1 .. Size);
      package Content_IO is new Ada.Direct_IO (Content);
      File : Content_IO.File_Type;
      Data : Content;
   begin
      if Size = 0 then
         return "";
      end if;
      Content_IO.Open (File, Content_IO.In_File, Name);
      Content_IO.Read (File, Data);
      Content_IO.Close (File);
      return Data;
   end Read_File;

   procedure Fail (Message : String) is
   begin
      Put_Line (Standard_Error, "pmp_check: " & Message);
      Ada.Command_Line.Set_Exit_Status (Usage_Status);
   end Fail;

begin
   if Ada.Command_Line.Argument_Count /= 1 or else Ada.Command_Line.Argument (1) in "-h" | "--help" then
      Put_Line (Standard_Error, "usage: pmp_check FILE    (FILE: the output of mpfs_gen derive --check-json)");
      Ada.Command_Line.Set_Exit_Status (Usage_Status);
      return;
   end if;
   declare
      Name : constant String := Ada.Command_Line.Argument (1);
   begin
      if not Ada.Directories.Exists (Name) or else Ada.Directories.Kind (Name) /= Ada.Directories.Ordinary_File
      then
         Fail (Name & ": no such file");
         return;
      end if;
      if Ada.Directories.Size (Name) > Ada.Directories.File_Size (Json.Max_Source) then
         Fail (Name & ": larger than" & Json.Max_Source'Image & " bytes");
         return;
      end if;
      declare
         Src     : constant String := Read_File (Name);
         Root    : Json.Node_Id;
         Ok      : Boolean;
         Err_Pos : Natural;
         Err     : Texts.Text (256);
      begin
         Json.Parse (Src, Doc.all, Root, Ok, Err_Pos);
         if not Ok then
            Fail (Name & ": not JSON of the check input at byte" & Err_Pos'Image);
            return;
         end if;
         Load.Read (Doc.all, Src, Root, Sys.all, Ok, Err);
         if not Ok then
            Fail (Name & ": " & Texts.Image (Err));
            return;
         end if;
      end;
   end;

   Rules.Check (Sys.all, List.all);
   for I in 1 .. List.Count loop
      declare
         F : Findings.Finding renames List.Items (I);
      begin
         Put_Line ((case F.Sev is
                       when Findings.Error   => "error: ",
                       when Findings.Warning => "warning: ",
                       when Findings.Note    => "note: ")
                   & "GEN-" & F.C'Image & " " & Texts.Image (F.Path) & ": " & Texts.Image (F.Message));
      end;
   end loop;
   if List.Dropped > 0 then
      Put_Line ("note: " & List.Dropped'Image & " more findings not shown");
   end if;
   declare
      Errors : constant Natural := Findings.Errors (List.all);
   begin
      if Errors = 0 then
         Put_Line ("verdict: accepted");
      else
         Put_Line ("verdict: refused (" & Errors'Image & " errors)");
         Ada.Command_Line.Set_Exit_Status (Refused_Status);
      end if;
   end;
end Pmp_Check_Main;
