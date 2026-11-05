--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Ada.Real_Time; use Ada.Real_Time;

with Interfaces.C;
with System;
with System.Storage_Elements; use System.Storage_Elements;

package body Heap_Hammer is

   use type System.Address;

   function C_Malloc (N : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Malloc, "malloc");

   procedure C_Free (P : System.Address);
   pragma Import (C, C_Free, "free");

   Rounds : constant := 40;
   Blocks : constant := 16;

   --  The byte I of block Number.
   function Byte (Number, I : Natural) return Storage_Element;

   function Byte (Number, I : Natural) return Storage_Element is
   begin
      return Storage_Element ((Number * 31 + I * 7 + 5) mod 251);
   end Byte;

   --  The environment task of heap_test has the lowest priority.
   task Hammer
     with Priority => System.Priority'Last,
          Storage_Size => 8192, Secondary_Stack_Size => 1024;

   task body Hammer is
      Block : array (1 .. Blocks) of System.Address :=
        [others => System.Null_Address];
      Size  : array (1 .. Blocks) of Natural := [others => 0];
      Next  : Time := Clock;
   begin
      while not Go loop
         delay until Clock + Milliseconds (1);
      end loop;
      Next := Clock;

      for Round in 1 .. Rounds loop
         --  Wait for the next period; the timer interrupt that ends the wait
         --  can have interrupted the environment task anywhere.
         Next := Next + Milliseconds (1);
         delay until Next;

         for B in 1 .. Blocks loop
            Size (B) := 8 + (Round * 37 + B * 53) mod 300;
            Block (B) := C_Malloc (Interfaces.C.size_t (Size (B)));
            if Block (B) = System.Null_Address then
               Refused := Refused + 1;
               Size (B) := 0;
            else
               Allocated := Allocated + 1;
               declare
                  Data : Storage_Array (1 .. Storage_Count (Size (B)))
                    with Import, Address => Block (B);
               begin
                  for I in Data'Range loop
                     Data (I) := Byte (B, Natural (I));
                  end loop;
               end;
            end if;
         end loop;

         --  Another timer interrupt, in the middle of the work.
         delay until Next + Microseconds (300);

         for B in 1 .. Blocks loop
            if Block (B) /= System.Null_Address then
               declare
                  Data : Storage_Array (1 .. Storage_Count (Size (B)))
                    with Import, Address => Block (B);
               begin
                  for I in Data'Range loop
                     if Data (I) /= Byte (B, Natural (I)) then
                        Disturbed := Disturbed + 1;
                        exit;
                     end if;
                  end loop;
               end;
               C_Free (Block (B));
               Block (B) := System.Null_Address;
            end if;
         end loop;
      end loop;
      Done := True;
   end Hammer;

end Heap_Hammer;
