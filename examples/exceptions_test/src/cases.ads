--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The code that exceptions_test raises exceptions in: a recursion, controlled
--  objects that record their finalization, and two operations the compiler
--  checks.

with Ada.Finalization;

package Cases is

   Custom : exception;
   Other  : exception;

   --  Level (N) calls itself N times and then raises Custom with the message
   --  "from the bottom"; Depth_Reached is the N of the innermost call.
   Depth_Reached : Natural := 0;

   procedure Level (N : Natural);

   --  The finalization order: every Guard appends its Id to Log when it is
   --  finalized; Note appends a character too.
   Log     : String (1 .. 16) := [others => '-'];
   Log_Len : Natural := 0;

   procedure Reset_Log;
   procedure Note (C : Character);

   type Guard (Id : Character) is new Ada.Finalization.Limited_Controlled
   with null record;

   overriding procedure Finalize (G : in out Guard);

   --  Three nested guards a, b, c; with Fail the innermost scope raises
   --  Other with the message "inside the guards", else the log is "cxbya".
   procedure Guarded (Fail : Boolean);

   --  A value the compiler cannot fold, so that the checks are real.
   Zero : Integer := 0 with Volatile;

   function Divide (A, B : Integer) return Integer;

   subtype Small is Integer range 1 .. 10;

   function Make_Small (V : Integer) return Small;

   function Contains (Text : String; Part : String) return Boolean;

end Cases;
