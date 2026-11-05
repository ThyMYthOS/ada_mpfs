--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Derived from rowsail/ada_esp32s3 examples/common/bare/boot/test/allocator_test.adb and
--  heap_stress.adb @ d75142d (Apache-2.0); modified for PolarFire SoC: only the TLSF allocator
--  (the first-fit allocator of the original is not part of this repository), Host_Report instead of
--  its own output, a stress with a content for every block, and the cases that a 64-bit target adds:
--  a request above Tlsf_Math.Max_Alloc is refused (it would index the tables of the allocator out of
--  range), size classes up to 16 MiB, and the free flag of a header that has a word of its own.
--
--  The native test of Tlsf_Core, the allocator behind malloc of the embedded runtime. It is built
--  from the sources of the runtime (tests/host/rts_heap/host/tlsf_host.gpr) with assertions on.

with System;
with System.Storage_Elements; use System.Storage_Elements;
with Interfaces;              use Interfaces;

with Allocator_Arenas;
with Host_Report;
with Tlsf_Core;
with Tlsf_Math;

procedure Allocator_Test is

   use type System.Address;

   Arena_Bytes : constant := Allocator_Arenas.Small_Bytes;
   Big_Bytes   : constant := Allocator_Arenas.Big_Bytes;

   procedure Check (Condition : Boolean; What : String) renames Host_Report.Check;

   procedure Fill (A : System.Address; N : Storage_Count; V : Storage_Element);

   function Verify
     (A : System.Address; N : Storage_Count; V : Storage_Element) return Boolean;

   procedure Fill (A : System.Address; N : Storage_Count; V : Storage_Element) is
      Data : Storage_Array (1 .. N) with Import, Address => A;
   begin
      Data := [others => V];
   end Fill;

   function Verify
     (A : System.Address; N : Storage_Count; V : Storage_Element) return Boolean
   is
      Data : Storage_Array (1 .. N) with Import, Address => A;
   begin
      return (for all B of Data => B = V);
   end Verify;

   Seed : Unsigned_32 := 2_463_534_242;

   function Rnd (Modulo : Positive) return Natural;

   function Rnd (Modulo : Positive) return Natural is
   begin
      Seed := Seed * 1_103_515_245 + 12_345;
      return Natural (Shift_Right (Seed, 8) mod Unsigned_32 (Modulo));
   end Rnd;

   function Aligned (A : System.Address) return Boolean
   is (To_Integer (A) mod 16 = 0);

   Failed : Boolean;

begin
   Host_Report.Start ("tlsf_host");

   --  ------------------------------------------------------------------
   --  Basics.
   --  ------------------------------------------------------------------
   Check (not Tlsf_Core.Ready, "not ready before Init");
   Tlsf_Core.Init (Allocator_Arenas.Small'Address, Arena_Bytes);
   Check (Tlsf_Core.Ready, "ready after Init");
   Check (Tlsf_Core.Invariants_Hold, "invariants after Init");

   declare
      Base : constant Storage_Count := Tlsf_Core.Free_Bytes;
      P    : constant System.Address := Tlsf_Core.Allocate (100);
   begin
      Check (Base <= Arena_Bytes, "the free bytes do not exceed the arena");
      Check (P /= System.Null_Address, "allocate 100");
      Check (Aligned (P), "the block is 16-byte aligned");
      Check (Tlsf_Core.Free_Bytes + 100 <= Base, "100 bytes fewer are free");
      Check (Tlsf_Core.Invariants_Hold, "invariants after allocate");
      Tlsf_Core.Deallocate (P);
      Check (Tlsf_Core.Invariants_Hold, "invariants after free");
      Check (Tlsf_Core.Free_Bytes = Base, "freeing gives the bytes back exactly");
   end;

   --  The header and the payload do not overlap.
   declare
      A : constant System.Address := Tlsf_Core.Allocate (16);
      B : constant System.Address := Tlsf_Core.Allocate (16);
   begin
      Check
        (A /= System.Null_Address and then B /= System.Null_Address
         and then abs (B - A) >= 16 + 24,
         "two blocks of 16 bytes are at least a header and 16 bytes apart");
      Tlsf_Core.Deallocate (A);
      Tlsf_Core.Deallocate (B);
      Check (Tlsf_Core.Invariants_Hold, "invariants after both are freed");
   end;

   --  ------------------------------------------------------------------
   --  Refusals. Every one of them, for a request above Max_Alloc, would
   --  violate a precondition of Tlsf_Math if the allocator did not turn it
   --  down first (the test is built with -gnata).
   --  ------------------------------------------------------------------
   Check (Tlsf_Core.Allocate (0) = System.Null_Address, "allocate 0 gives null");
   Check (Tlsf_Core.Allocate (Arena_Bytes * 2) = System.Null_Address,
          "a block larger than the arena gives null");
   Check (Tlsf_Core.Allocate (Tlsf_Math.Max_Alloc) = System.Null_Address,
          "Max_Alloc gives null in a small arena");
   Check (Tlsf_Core.Allocate (Tlsf_Math.Max_Alloc + 1) = System.Null_Address,
          "a request above Max_Alloc gives null");
   Check (Tlsf_Core.Allocate (2 ** 40) = System.Null_Address,
          "a request of 2**40 gives null");
   Check (Tlsf_Core.Allocate (Storage_Count'Last) = System.Null_Address,
          "Storage_Count'Last gives null");
   Check (Tlsf_Core.Allocate (Storage_Count'Last - 8) = System.Null_Address,
          "a request that would wrap Round_Up gives null");
   Check (Tlsf_Core.Reallocate (System.Null_Address, Storage_Count'Last)
          = System.Null_Address,
          "reallocate of null to Storage_Count'Last gives null");
   Check (Tlsf_Core.Invariants_Hold, "invariants after the refusals");

   --  ------------------------------------------------------------------
   --  Reallocate.
   --  ------------------------------------------------------------------
   declare
      Base : constant Storage_Count := Tlsf_Core.Free_Bytes;
      P    : constant System.Address := Tlsf_Core.Allocate (40);
      Q    : System.Address;
      R    : System.Address;
   begin
      Fill (P, 40, 16#5A#);
      Q := Tlsf_Core.Reallocate (P, 4000);
      Check (Q /= System.Null_Address, "reallocate to more");
      Check (Verify (Q, 40, 16#5A#), "reallocate keeps the content");
      Check (Tlsf_Core.Invariants_Hold, "invariants after reallocate");
      R := Tlsf_Core.Reallocate (Q, 10);
      Check (R = Q, "reallocate to less keeps the block");
      Check (Tlsf_Core.Reallocate (R, 0) = System.Null_Address,
             "reallocate to 0 frees the block");
      Check (Tlsf_Core.Free_Bytes = Base, "and gives the bytes back");
   end;

   --  ------------------------------------------------------------------
   --  A random sequence, with a content for every block, the chain checked
   --  after every operation.
   --  ------------------------------------------------------------------
   declare
      Max_Live : constant := 64;
      type Slot is record
         A   : System.Address := System.Null_Address;
         Sz  : Storage_Count := 0;
         Pat : Storage_Element := 0;
      end record;
      Live    : array (1 .. Max_Live) of Slot;
      Idx, Sz : Natural;
      Base    : constant Storage_Count := Tlsf_Core.Free_Bytes;
      Bad     : Natural := 0;
   begin
      for Step in 1 .. 300_000 loop
         Idx := Rnd (Max_Live) + 1;
         if Live (Idx).A = System.Null_Address then
            Sz := Rnd (512) + 1;
            declare
               A : constant System.Address := Tlsf_Core.Allocate (Storage_Count (Sz));
            begin
               if A /= System.Null_Address then
                  if not Aligned (A) then
                     Bad := Bad + 1;
                  end if;
                  Live (Idx) := (A, Storage_Count (Sz), Storage_Element (Rnd (256)));
                  Fill (A, Live (Idx).Sz, Live (Idx).Pat);
               end if;
            end;
         else
            if not Verify (Live (Idx).A, Live (Idx).Sz, Live (Idx).Pat) then
               Bad := Bad + 1;
            end if;
            Tlsf_Core.Deallocate (Live (Idx).A);
            Live (Idx) := (System.Null_Address, 0, 0);
         end if;
         if not Tlsf_Core.Invariants_Hold then
            Bad := Bad + 1;
         end if;
         exit when Bad > 0;
         pragma Unreferenced (Step);
      end loop;
      Check (Bad = 0, "300 000 random operations: contents, alignment and chain are right");

      for S of Live loop
         if S.A /= System.Null_Address then
            if not Verify (S.A, S.Sz, S.Pat) then
               Bad := Bad + 1;
            end if;
            Tlsf_Core.Deallocate (S.A);
         end if;
      end loop;
      Check (Bad = 0, "the blocks that are left have their content");
      Check (Tlsf_Core.Invariants_Hold, "invariants after the drain");
      Check (Tlsf_Core.Free_Bytes = Base,
             "after the drain the free bytes are what they were: no leak, no double count");

      --  After a full drain the arena is one big block again; a fragmented heap
      --  could not serve this. The margin is the header and the good-fit rounding
      --  of TLSF, which cannot hand out the last few per cent of one block.
      declare
         Large : constant System.Address := Tlsf_Core.Allocate (Arena_Bytes - 4096);
      begin
         Check (Large /= System.Null_Address, "a large block after the drain (coalesced)");
         Tlsf_Core.Deallocate (Large);
      end;
   end;

   --  ------------------------------------------------------------------
   --  Every size from 1 to 300 alive at the same time, then freed in
   --  another order.
   --  ------------------------------------------------------------------
   declare
      Base : constant Storage_Count := Tlsf_Core.Free_Bytes;
      Live : array (1 .. 300) of System.Address;
      Ok   : Boolean := True;
   begin
      for N in Live'Range loop
         Live (N) := Tlsf_Core.Allocate (Storage_Count (N));
         if Live (N) = System.Null_Address then
            Ok := False;
         else
            Fill (Live (N), Storage_Count (N), Storage_Element (N mod 251));
         end if;
      end loop;
      Check (Ok, "the sizes 1 to 300 are served");
      for N in Live'Range loop
         if Live (N) /= System.Null_Address
           and then not Verify (Live (N), Storage_Count (N), Storage_Element (N mod 251))
         then
            Ok := False;
         end if;
      end loop;
      Check (Ok, "no block of them overwrites another");
      for N in reverse Live'Range loop
         if N mod 2 = 0 and then Live (N) /= System.Null_Address then
            Tlsf_Core.Deallocate (Live (N));
            Live (N) := System.Null_Address;
         end if;
      end loop;
      for N in Live'Range loop
         if Live (N) /= System.Null_Address then
            Tlsf_Core.Deallocate (Live (N));
         end if;
      end loop;
      Check (Tlsf_Core.Invariants_Hold and then Tlsf_Core.Free_Bytes = Base,
             "freed in another order: whole again");
   end;

   --  ------------------------------------------------------------------
   --  Size classes up to 16 MiB, in a larger arena: every power of two,
   --  and its neighbours.
   --  ------------------------------------------------------------------
   Tlsf_Core.Init (Allocator_Arenas.Big'Address, Big_Bytes);
   declare
      Base : constant Storage_Count := Tlsf_Core.Free_Bytes;
      Ok   : Boolean := True;
      Size : Storage_Count;
   begin
      for K in 4 .. 23 loop
         for Delta_Size in -1 .. 1 loop
            Size := Storage_Count (2 ** K + Delta_Size);
            declare
               P : constant System.Address := Tlsf_Core.Allocate (Size);
            begin
               if P = System.Null_Address
                 or else not Aligned (P)
                 or else Tlsf_Core.Free_Bytes + Size > Base
               then
                  Ok := False;
               else
                  Fill (P, Size, Storage_Element (K));
                  if not Verify (P, Size, Storage_Element (K))
                    or else not Tlsf_Core.Invariants_Hold
                  then
                     Ok := False;
                  end if;
                  Tlsf_Core.Deallocate (P);
               end if;
            end;
         end loop;
      end loop;
      Check (Ok, "2**k - 1, 2**k and 2**k + 1 bytes for k = 4 to 23 are served");
      Check (Tlsf_Core.Free_Bytes = Base and then Tlsf_Core.Invariants_Hold,
             "and give the arena back");
      Check (Tlsf_Core.Allocate (Big_Bytes / 2 + Big_Bytes / 4) /= System.Null_Address,
             "a block of 24 MiB is served");
      Check (Tlsf_Core.Allocate (Big_Bytes) = System.Null_Address,
             "a block of the arena's size is not: there is a header");
   end;

   --  ------------------------------------------------------------------
   --  Init again with a different arena starts from scratch.
   --  ------------------------------------------------------------------
   Tlsf_Core.Init (Allocator_Arenas.Small'Address, Arena_Bytes);
   Failed := Tlsf_Core.Free_Bytes > Arena_Bytes or else not Tlsf_Core.Invariants_Hold;
   Check (not Failed, "Init again gives a whole small arena");

   Host_Report.Finish;
end Allocator_Test;
