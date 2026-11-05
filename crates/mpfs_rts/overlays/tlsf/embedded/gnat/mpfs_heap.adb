--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Derived from rowsail/ada_esp32s3 examples/common/bare/boot/bare_heap.adb
--  @ d75142d (Apache-2.0); modified for PolarFire SoC: the lock is the
--  interface MPFS_Heap_Lock (no spin lock of the Xtensa), the arena is
--  __heap_start .. __heap_end, the task stack hook is not part of it.

pragma Restrictions (No_Elaboration_Code);

with Heap_Guard;
with MPFS_Heap_Lock;
with Tlsf_Core;

package body MPFS_Heap is

   use System;
   use System.Storage_Elements;

   package T renames Tlsf_Core;

   --  The bounds of the arena are the addresses of the symbols of the linker
   --  script, as the newlib glue of the upstream runtime uses them.
   Heap_Base : Storage_Element
     with Import, Convention => C, External_Name => "__heap_start";
   Heap_End  : Storage_Element
     with Import, Convention => C, External_Name => "__heap_end";

   --  .bss, which the start code clears: False at the first call.
   Started : Boolean;

   ---------------
   -- Heap_Size --
   ---------------

   function Heap_Size return Storage_Count is
   begin
      return Storage_Count
        (To_Integer (Heap_End'Address) - To_Integer (Heap_Base'Address));
   end Heap_Size;

   --  Called with the lock held.
   procedure Ensure_Init;

   procedure Ensure_Init is
   begin
      if not Started then
         T.Init (Heap_Base'Address, Heap_Size);
         Started := True;
      end if;
   end Ensure_Init;

   ------------
   -- Malloc --
   ------------

   function Malloc (N : Interfaces.C.size_t) return System.Address is
      State : MPFS_Heap_Lock.Saved_State;
      R     : System.Address;
   begin
      if not Heap_Guard.Request_Fits (N) then
         return System.Null_Address;
      end if;
      State := MPFS_Heap_Lock.Acquire;
      Ensure_Init;
      R := T.Allocate (Storage_Count (N));
      MPFS_Heap_Lock.Release (State);
      return R;
   end Malloc;

   ----------
   -- Free --
   ----------

   procedure Free (P : System.Address) is
      State : MPFS_Heap_Lock.Saved_State;
   begin
      if P = System.Null_Address then
         return;
      end if;
      State := MPFS_Heap_Lock.Acquire;
      T.Deallocate (P);
      MPFS_Heap_Lock.Release (State);
   end Free;

   -------------
   -- Realloc --
   -------------

   function Realloc
     (P : System.Address; N : Interfaces.C.size_t) return System.Address
   is
      State : MPFS_Heap_Lock.Saved_State;
      R     : System.Address;
   begin
      if not Heap_Guard.Request_Fits (N) then
         return System.Null_Address;
      end if;
      State := MPFS_Heap_Lock.Acquire;
      Ensure_Init;
      R := T.Reallocate (P, Storage_Count (N));
      MPFS_Heap_Lock.Release (State);
      return R;
   end Realloc;

   ------------
   -- Calloc --
   ------------

   function Calloc (Nmemb, Size : Interfaces.C.size_t) return System.Address is
      Total : Storage_Count;
      Ok    : Boolean;
      State : MPFS_Heap_Lock.Saved_State;
      R     : System.Address;
   begin
      --  Nmemb * Size must neither wrap nor exceed what the allocator serves:
      --  Heap_Guard (proved) returns the byte count or refuses.
      Heap_Guard.Array_Bytes (Nmemb, Size, Total, Ok);
      if not Ok then
         return System.Null_Address;
      end if;
      State := MPFS_Heap_Lock.Acquire;
      Ensure_Init;
      R := T.Allocate (Total);
      MPFS_Heap_Lock.Release (State);
      if R /= System.Null_Address then
         --  The zeroing is outside the lock: the block belongs to the caller.
         declare
            Block : Storage_Array (1 .. Total)
              with Import, Address => R;
         begin
            Block := (others => 0);
         end;
      end if;
      return R;
   end Calloc;

   ----------------
   -- Free_Bytes --
   ----------------

   function Free_Bytes return Storage_Count is
      State : MPFS_Heap_Lock.Saved_State;
      R     : Storage_Count;
   begin
      State := MPFS_Heap_Lock.Acquire;
      Ensure_Init;
      R := T.Free_Bytes;
      MPFS_Heap_Lock.Release (State);
      return R;
   end Free_Bytes;

   ---------------------
   -- Invariants_Hold --
   ---------------------

   function Invariants_Hold return Boolean is
      State : MPFS_Heap_Lock.Saved_State;
      R     : Boolean;
   begin
      State := MPFS_Heap_Lock.Acquire;
      Ensure_Init;
      R := T.Invariants_Hold;
      MPFS_Heap_Lock.Release (State);
      return R;
   end Invariants_Hold;

end MPFS_Heap;
