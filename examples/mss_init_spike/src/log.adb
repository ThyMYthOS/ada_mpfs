--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

with Interfaces;

with Ring_Size;

package body Log is

   use type Interfaces.Unsigned_32;

   Size : constant := Ring_Size.Size;

   Ring_Size_Is_A_Power_Of_Two : constant Boolean :=
     (Interfaces.Unsigned_32 (Size) and (Interfaces.Unsigned_32 (Size) - 1))
       = 0;
   pragma Compile_Time_Error
     (not Ring_Size_Is_A_Power_Of_Two,
      "Ring_Size.Size must be a power of two");

   Data : array (0 .. Size - 1) of Character;
   pragma Volatile_Components (Data);

   Head : Interfaces.Unsigned_32 := 0;   --  written by the producer only
   pragma Atomic (Head);
   Tail : Interfaces.Unsigned_32 := 0;   --  written by the consumer only
   pragma Atomic (Tail);

   Taken_Total : Natural := 0;           --  the producer's
   Lost_Total  : Natural := 0;           --  the producer's

   procedure Put (Text : String; Taken : out Natural) is
      Used : constant Interfaces.Unsigned_32 := Head - Tail;
      Room : constant Natural := Size - Natural (Used);
   begin
      Taken := Natural'Min (Text'Length, Room);
      for I in 0 .. Taken - 1 loop
         Data (Natural ((Head + Interfaces.Unsigned_32 (I)) mod Size)) :=
           Text (Text'First + I);
      end loop;
      Head := Head + Interfaces.Unsigned_32 (Taken);   --  publish
      Taken_Total := Taken_Total + Taken;
      Lost_Total := Lost_Total + (Text'Length - Taken);
   end Put;

   procedure Get (Item : out Character; Got : out Boolean) is
      Current : constant Interfaces.Unsigned_32 := Tail;
   begin
      if Head = Current then
         Item := ' ';
         Got := False;
      else
         Item := Data (Natural (Current mod Size));
         Tail := Current + 1;
         Got := True;
      end if;
   end Get;

   function Capacity return Positive is (Size);
   function Pending return Natural is (Natural (Head - Tail));
   function Accepted return Natural is (Taken_Total);
   function Dropped return Natural is (Lost_Total);

end Log;
