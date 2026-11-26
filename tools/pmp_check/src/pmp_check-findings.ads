--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The findings of the checker: the code of the rule (the codes of config/README.md that the
--  generator reports for the same rule), where (the same path as the generator's), the severity and
--  a message.
--
--  Severity: a rule of the way masks themselves (GEN-E072, GEN-E073, GEN-E085) is an error in both
--  profiles (they are applied in both). A rule of the PMP, the MPU or the cache partitioning
--  (Profile_Code) is a note for a dev system (only findings for information there); for a prod system
--  it is a warning if the rule is one of Warnings, else an error. Any error refuses the system.
--
--  @req GEN-015, GEN-019

with Pmp_Check.Texts;

package Pmp_Check.Findings
  with SPARK_Mode
is
   type Rule_Code is (E072, E073, E085, E100, E101, E102, E103, E104, E105, E120, E121, E122, E123, E124,
                      E125, E126, E127, E128, E129, E135, E136, E140, E141, E142, E143, E144, E145, E146,
                      E147);

   subtype Profile_Code is Rule_Code range E100 .. E147;

   Warnings : constant array (Rule_Code) of Boolean :=
     [E104 | E123 | E127 | E128 | E135 | E136 => True, others => False];

   type Severity is (Error, Warning, Note);

   function Severity_Of (C : Rule_Code; Prod : Boolean) return Severity is
     (if C not in Profile_Code then Error elsif not Prod then Note elsif Warnings (C) then Warning else Error);

   Path_Capacity    : constant := 96;
   Message_Capacity : constant := 1024;

   type Finding is record
      C       : Rule_Code := E100;
      Sev     : Severity := Error;
      Path    : Texts.Text (Path_Capacity);
      Message : Texts.Text (Message_Capacity);
   end record;

   Max_Findings : constant := 512;
   type Finding_Array is array (1 .. Max_Findings) of Finding;

   type List is record
      Items   : Finding_Array;
      Count   : Natural range 0 .. Max_Findings := 0;
      Dropped : Natural := 0;        --  findings beyond Max_Findings (counted, not kept)
      Dropped_Errors : Natural := 0; --  the errors among them
   end record;

   procedure Add (L : in out List; C : Rule_Code; Prod : Boolean; Path : String; Message : Texts.Text);

   --  The errors, those beyond Max_Findings included.
   function Errors (L : List) return Natural;

end Pmp_Check.Findings;
