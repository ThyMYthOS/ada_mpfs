--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with System;
with System.Secondary_Stack;

package body Secstack_Cases is

   --  Character I of Pattern (Seed, N).
   function Expected (Seed, I : Natural) return Character;

   function Expected (Seed, I : Natural) return Character is
   begin
      return Character'Val (33 + (Seed * 7 + I * 13) mod 90);
   end Expected;

   ------------
   -- Repeat --
   ------------

   function Repeat (C : Character; N : Natural) return String is
   begin
      return [1 .. N => C];
   end Repeat;

   ----------
   -- Join --
   ----------

   function Join (A, B : String) return String is
      Result : String (1 .. A'Length + B'Length);
   begin
      Result (1 .. A'Length) := A;
      Result (A'Length + 1 .. Result'Last) := B;
      return Result;
   end Join;

   -------------
   -- Pattern --
   -------------

   function Pattern (Seed, N : Natural) return String is
      Result : String (1 .. N);
   begin
      for I in Result'Range loop
         Result (I) := Expected (Seed, I);
      end loop;
      return Result;
   end Pattern;

   ----------------
   -- Is_Pattern --
   ----------------

   function Is_Pattern (S : String; Seed : Natural) return Boolean is
   begin
      for I in 1 .. S'Length loop
         if S (S'First + I - 1) /= Expected (Seed, I) then
            return False;
         end if;
      end loop;
      return True;
   end Is_Pattern;

   ------------
   -- Nested --
   ------------

   function Nested (Depth : Natural) return String is
   begin
      if Depth = 0 then
         return Repeat (' ', 0);
      end if;
      return Join (Pattern (Depth, 8), Nested (Depth - 1));
   end Nested;

   ---------------
   -- Is_Nested --
   ---------------

   function Is_Nested (S : String; Depth : Natural) return Boolean is
      First : Natural := S'First;
   begin
      if S'Length /= 8 * Depth then
         return False;
      end if;
      for Level in reverse 1 .. Depth loop
         if not Is_Pattern (S (First .. First + 7), Level) then
            return False;
         end if;
         First := First + 8;
      end loop;
      return True;
   end Is_Nested;

   -------------
   -- Exhaust --
   -------------

   procedure Exhaust is
      Address : System.Address;
   begin
      Taken := 0;
      loop
         System.Secondary_Stack.SS_Allocate (Address, Chunk);
         Taken := Taken + Chunk;
      end loop;
   end Exhaust;

end Secstack_Cases;
