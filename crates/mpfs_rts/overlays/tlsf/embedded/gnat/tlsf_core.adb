--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Derived from rowsail/ada_esp32s3 examples/common/bare/boot/tlsf_core.adb @ d75142d
--  (Apache-2.0); modified for PolarFire SoC: the free flag of a block header
--  is a 64-bit word (a one-byte store into a word that was never written is a
--  read-modify-write of the uninitialised ECC memory of the LIM), a request
--  above Tlsf_Math.Max_Alloc is refused (the unit was written for a 32-bit
--  target), the state has no initial values (.bss, not 6.5 KiB of zeros in
--  .data), and No_Elaboration_Code.

pragma Restrictions (No_Elaboration_Code);

--  The helpers of the body have no specification of their own (the style
--  check of the runtime wants one).
pragma Style_Checks ("-s");

with Ada.Unchecked_Conversion;
with Interfaces; use Interfaces;

--  The pure size-class + bit math (geometry constants, FLS/FFS, Round_Up,
--  Mapping/Mapping_Search) lives in Tlsf_Math, SPARK-proved (tlsf_math_prove.gpr:
--  the bucket indices are proved always in range).  This body supplies only the
--  raw-address / free-list plumbing that is outside SPARK's memory model.
with Tlsf_Math; use Tlsf_Math;

package body Tlsf_Core is

   use type System.Address;

   ---------------------------------------------------------------------------
   --  Block layout: a header (physical-prev pointer + payload size + free flag)
   --  followed by the payload; a free block keeps its segregated-list links in
   --  the first two words of that payload.
   ---------------------------------------------------------------------------
   --  The state is a word of its own: the heap is uninitialised ECC memory
   --  (LIM) and a store narrower than 64 bits into a word that was never
   --  written is a read-modify-write of garbage.
   type Block_State is (Used, Free);
   for Block_State use (Used => 0, Free => 1);
   for Block_State'Size use 64;

   type Hdr is record
      Prev_Phys : System.Address;   --  physical previous block (Null = first)
      Size      : Storage_Count;    --  payload bytes (16-aligned)
      State     : Block_State;
   end record;
   type Hdr_Acc is access all Hdr;
   function To_Hdr is new Ada.Unchecked_Conversion (System.Address, Hdr_Acc);

   type Links is record
      Next_Free : System.Address;
      Prev_Free : System.Address;
   end record;
   type Links_Acc is access all Links;
   function To_Links is new Ada.Unchecked_Conversion (System.Address, Links_Acc);

   --  Header size -- MUST be a compile-time static (a record-Object_Size based
   --  value would be elaborated, and the allocator is used before elaboration
   --  and has none -> garbage Hdr_Sz -> wild pointers).  Static upper bound on
   --  the header (Prev_Phys + Size + the 64-bit state), rounded to Align; >=
   --  Hdr'Object_Size on both 32- and 64-bit.  Use Address_Size for the two
   --  words (Storage_Count'Size is the SUBTYPE's minimal bit count, e.g. 63 on
   --  a 64-bit host -> too small); the state is 8 bytes.
   Hdr_Bytes   : constant :=
     (2 * Standard'Address_Size + 64) / System.Storage_Unit;
   Hdr_Sz      : constant Storage_Count := ((Storage_Count (Hdr_Bytes) + 15) / 16) * 16;
   Min_Payload : constant Storage_Count := Align;   --  holds the two links

   ---------------------------------------------------------------------------
   --  State
   ---------------------------------------------------------------------------
   --  No initial values: these are .bss, which the start code clears, and so
   --  are zero at the first malloc whatever has been elaborated (the allocator
   --  is used before the units of the program are, and has no elaboration of
   --  its own).  A zero initial value would put them in .data, 6.5 KiB of
   --  zeros in the image, with this compiler.  (The header SIZE, by contrast,
   --  has to be a compile-time static above: a constant that is elaborated
   --  would not be set when the allocator is first used.)
   Heads     : array (0 .. FL_Count - 1, 0 .. SL_Count - 1) of System.Address;
   FL_Bitmap : Unsigned_32;
   SL_Bitmap : array (0 .. FL_Count - 1) of Unsigned_32;
   Pool_Lo   : System.Address;
   Sentinel  : System.Address;
   Inited    : Boolean;

   --  Running sum of the payload bytes of every block currently on the free
   --  lists; += Size_Of on Insert_Free, -= Size_Of on Remove_Free, so it is
   --  exact at every quiescent point.  Backs Free_Bytes.
   Free_Payload : Storage_Count;

   ---------------------------------------------------------------------------
   --  Block accessors
   ---------------------------------------------------------------------------
   function Size_Of (B : System.Address) return Storage_Count
   is (To_Hdr (B).Size);
   function Is_Free (B : System.Address) return Boolean
   is (To_Hdr (B).State = Free);
   procedure Set_Free (B : System.Address; F : Boolean) is
   begin
      To_Hdr (B).State := (if F then Free else Used);
   end Set_Free;
   procedure Set_Size (B : System.Address; S : Storage_Count) is
   begin
      To_Hdr (B).Size := S;
   end Set_Size;
   function Prev_Phys (B : System.Address) return System.Address
   is (To_Hdr (B).Prev_Phys);
   procedure Set_Prev_Phys (B, P : System.Address) is
   begin
      To_Hdr (B).Prev_Phys := P;
   end Set_Prev_Phys;

   function Payload (B : System.Address) return System.Address
   is (B + Hdr_Sz);
   function Block_Of (P : System.Address) return System.Address
   is (P - Hdr_Sz);
   function Next_Phys (B : System.Address) return System.Address
   is (B + (Hdr_Sz + To_Hdr (B).Size));

   function Next_Free (B : System.Address) return System.Address
   is (To_Links (Payload (B)).Next_Free);
   function Prev_Free (B : System.Address) return System.Address
   is (To_Links (Payload (B)).Prev_Free);

   --  Bit scans (FLS/FFS), size-class Mapping/Mapping_Search and Round_Up come
   --  from Tlsf_Math (SPARK-proved); see the context clause above.

   function Find_Suitable (FL0, SL0 : Integer; FL, SL : out Integer) return Boolean is
      Sl_Map : Unsigned_32 := SL_Bitmap (FL0) and Shift_Left (Unsigned_32'Last, SL0);
      F      : Integer := FL0;
   begin
      if Sl_Map = 0 then
         declare
            Fl_Map : constant Unsigned_32 :=
              (if F + 1 >= 32 then 0 else FL_Bitmap and Shift_Left (Unsigned_32'Last, F + 1));
         begin
            if Fl_Map = 0 then
               return False;                    --  out of memory

            end if;
            F := FFS (Fl_Map);
            Sl_Map := SL_Bitmap (F);
         end;
      end if;
      FL := F;
      SL := FFS (Sl_Map);
      return True;
   end Find_Suitable;

   ---------------------------------------------------------------------------
   --  free-list insert / remove (+ bitmaps)
   ---------------------------------------------------------------------------
   procedure Insert_Free (B : System.Address) is
      FL, SL : Integer;
      H      : System.Address;
   begin
      Free_Payload := Free_Payload + Size_Of (B);
      Mapping (Size_Of (B), FL, SL);
      H := Heads (FL, SL);
      To_Links (Payload (B)).Next_Free := H;
      To_Links (Payload (B)).Prev_Free := System.Null_Address;
      if H /= System.Null_Address then
         To_Links (Payload (H)).Prev_Free := B;
      end if;
      Heads (FL, SL) := B;
      FL_Bitmap := FL_Bitmap or Shift_Left (Unsigned_32 (1), FL);
      SL_Bitmap (FL) := SL_Bitmap (FL) or Shift_Left (Unsigned_32 (1), SL);
   end Insert_Free;

   procedure Remove_Free (B : System.Address) is
      FL, SL : Integer;
      Nx     : constant System.Address := Next_Free (B);
      Pv     : constant System.Address := Prev_Free (B);
   begin
      Free_Payload := Free_Payload - Size_Of (B);
      Mapping (Size_Of (B), FL, SL);
      if Pv /= System.Null_Address then
         To_Links (Payload (Pv)).Next_Free := Nx;
      else
         Heads (FL, SL) := Nx;
      end if;
      if Nx /= System.Null_Address then
         To_Links (Payload (Nx)).Prev_Free := Pv;
      end if;
      if Heads (FL, SL) = System.Null_Address then
         SL_Bitmap (FL) := SL_Bitmap (FL) and not Shift_Left (Unsigned_32 (1), SL);
         if SL_Bitmap (FL) = 0 then
            FL_Bitmap := FL_Bitmap and not Shift_Left (Unsigned_32 (1), FL);
         end if;
      end if;
   end Remove_Free;

   ---------------------------------------------------------------------------
   --  helpers
   ---------------------------------------------------------------------------
   function Align_Down (A : Integer_Address) return Integer_Address
   is (A / Integer_Address (Align) * Integer_Address (Align));
   function Align_Up (A : Integer_Address) return Integer_Address
   is (Align_Down (A + Integer_Address (Align) - 1));

   --  Split B so it keeps Want payload; the remainder becomes a free block.
   procedure Split (B : System.Address; Want : Storage_Count) is
      Old  : constant Storage_Count := Size_Of (B);
      Rest : constant System.Address := B + (Hdr_Sz + Want);
   begin
      Set_Size (B, Want);
      Set_Prev_Phys (Rest, B);
      Set_Size (Rest, Old - Want - Hdr_Sz);
      Set_Free (Rest, True);
      Set_Prev_Phys (Next_Phys (Rest), Rest);
      Insert_Free (Rest);
   end Split;

   -----------
   -- Ready --
   -----------

   function Ready return Boolean
   is (Inited);

   ---------------
   -- Free_Bytes --
   ---------------

   function Free_Bytes return Storage_Count
   is (Free_Payload);

   ----------
   -- Init --
   ----------

   procedure Init (Base : System.Address; Size : Storage_Count) is
      Lo : constant System.Address := To_Address (Align_Up (To_Integer (Base)));
      Hi : constant System.Address :=
        To_Address (Align_Down (To_Integer (Base) + Integer_Address (Size)));
      B0 : constant System.Address := Lo;
      Sn : constant System.Address := Hi - Hdr_Sz;
   begin
      Heads := (others => (others => System.Null_Address));
      FL_Bitmap := 0;
      SL_Bitmap := (others => 0);
      Free_Payload := 0;   --  re-init: Insert_Free (B0) below re-establishes it

      Set_Prev_Phys (B0, System.Null_Address);
      Set_Size (B0, Storage_Count (To_Integer (Sn) - To_Integer (B0)) - Hdr_Sz);
      Set_Free (B0, True);

      Set_Prev_Phys (Sn, B0);
      Set_Size (Sn, 0);
      Set_Free (Sn, False);

      Pool_Lo := Lo;
      Sentinel := Sn;
      Inited := True;
      Insert_Free (B0);
   end Init;

   --------------
   -- Allocate --
   --------------

   function Allocate (N : Storage_Count) return System.Address is
      Adj              : Storage_Count;
      Sz               : Storage_Count;
      FL0, SL0, FL, SL : Integer;
      B                : System.Address;
   begin
      --  Reject before any size arithmetic: N within Align of Storage_Count'Last
      --  would wrap Round_Up negative, and N above Max_Alloc is beyond the
      --  size classes (Mapping_Search's precondition).  (MPFS_Heap refuses the
      --  same requests with Heap_Guard; this is the allocator's own backstop.)
      if N = 0 or else not Inited or else N > Max_Alloc then
         return System.Null_Address;
      end if;
      Adj := (if Round_Up (N) < Min_Payload then Min_Payload else Round_Up (N));
      Sz  := Adj;
      Mapping_Search (Sz, FL0, SL0);
      if not Find_Suitable (FL0, SL0, FL, SL) then
         return System.Null_Address;            --  OOM

      end if;
      B := Heads (FL, SL);
      Remove_Free (B);
      if Size_Of (B) >= Adj + Hdr_Sz + Min_Payload then
         Split (B, Adj);
      end if;
      Set_Free (B, False);
      return Payload (B);
   end Allocate;

   ----------------
   -- Deallocate --
   ----------------

   procedure Deallocate (P : System.Address) is
      B  : System.Address;
      Nx : System.Address;
      Pv : System.Address;
   begin
      if P = System.Null_Address then
         return;
      end if;
      B := Block_Of (P);
      Set_Free (B, True);

      Nx := Next_Phys (B);                       --  coalesce forward
      if Is_Free (Nx) then
         --  sentinel is used, so safe
         Remove_Free (Nx);
         Set_Size (B, Size_Of (B) + Hdr_Sz + Size_Of (Nx));
         Set_Prev_Phys (Next_Phys (B), B);
      end if;

      Pv := Prev_Phys (B);                       --  coalesce backward
      if Pv /= System.Null_Address and then Is_Free (Pv) then
         Remove_Free (Pv);
         Set_Size (Pv, Size_Of (Pv) + Hdr_Sz + Size_Of (B));
         Set_Prev_Phys (Next_Phys (Pv), Pv);
         B := Pv;
      end if;

      Insert_Free (B);
   end Deallocate;

   ----------------
   -- Reallocate --
   ----------------

   function Reallocate (P : System.Address; N : Storage_Count) return System.Address is
      B  : System.Address;
      Np : System.Address;
   begin
      if P = System.Null_Address then
         return Allocate (N);
      end if;
      if N = 0 then
         Deallocate (P);
         return System.Null_Address;
      end if;
      if N > Max_Alloc then
         return System.Null_Address;   --  see Allocate
      end if;
      B := Block_Of (P);
      if Size_Of (B) >= Round_Up (N) then
         return P;
      end if;
      Np := Allocate (N);
      if Np /= System.Null_Address then
         declare
            Src : Storage_Array (1 .. Size_Of (B))
            with Import, Address => P;
            Dst : Storage_Array (1 .. Size_Of (B))
            with Import, Address => Np;
         begin
            Dst := Src;
         end;
         Deallocate (P);
      end if;
      return Np;
   end Reallocate;

   ---------------------
   -- Invariants_Hold --
   ---------------------

   function Invariants_Hold return Boolean is
      B    : System.Address := Pool_Lo;
      Prev : System.Address := System.Null_Address;
      Nx   : System.Address;
   begin
      if not Inited then
         return False;
      end if;
      while B /= Sentinel loop
         if To_Integer (B) mod Integer_Address (Align) /= 0
           or else Prev_Phys (B) /= Prev
           or else To_Integer (B) < To_Integer (Pool_Lo)
           or else Size_Of (B) < Min_Payload
         then
            return False;
         end if;
         Nx := Next_Phys (B);
         if To_Integer (Nx) > To_Integer (Sentinel) then
            return False;
         end if;
         if Is_Free (B) and then Nx /= Sentinel and then Is_Free (Nx) then
            return False;                         --  adjacent free => not coalesced

         end if;
         Prev := B;
         B := Nx;
      end loop;
      return
        Prev_Phys (Sentinel) = Prev
        and then Size_Of (Sentinel) = 0
        and then not Is_Free (Sentinel);
   end Invariants_Hold;

end Tlsf_Core;
