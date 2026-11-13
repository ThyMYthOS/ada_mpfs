--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  heap_test: the heap of the embedded runtime of crates/mpfs_rts, the TLSF
--  allocator behind malloc, free, realloc and calloc (MPFS_Heap), over the
--  memory between __heap_start and __heap_end.
--
--    - the symbols: libgcc's unwinder allocates (once, at start-up: the
--      warm-up of the runtime), and the heap lock leaves mstatus.MIE as it
--      found it;
--    - the interface: alignment, the refusal of a request that cannot be
--      served, calloc, realloc, Ada's new and Unchecked_Deallocation;
--    - random sequences of allocation, release and reallocation of blocks
--      with a content that is checked, with the chain of blocks checked
--      between (Invariants_Hold): the heap is as large after them as before;
--    - fragmentation: every second block of 2000 freed leaves holes that the
--      next requests of the same size fill, and releasing the rest coalesces
--      them to one block again;
--    - the limit: allocation until nothing is left (a null pointer, and
--      Storage_Error for new), then everything back;
--    - a task of a higher priority that allocates and frees at the same time
--      (Heap_Hammer): no block is disturbed and the chain is intact.
--
--  Reported with Test_Report as heap_test_e51 or heap_test_u54.
--
--  @verifies RTS-012

with Ada.Real_Time; use Ada.Real_Time;
with Ada.Unchecked_Deallocation;

with Interfaces;
with Interfaces.C;
with System;
with System.Machine_Code;
with System.Storage_Elements; use System.Storage_Elements;

with Bare_Console;
with Heap_Hammer;
with Heap_Slots; use Heap_Slots;
with MPFS_Heap;
with MPFS_Heap_Lock;
with Test_Report;

procedure Heap_Test is

   pragma Priority (System.Priority'First);

   use type Interfaces.Unsigned_64;
   use type Interfaces.C.size_t;
   use type System.Address;

   function C_Malloc (N : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Malloc, "malloc");

   procedure C_Free (P : System.Address);
   pragma Import (C, C_Free, "free");

   function C_Realloc
     (P : System.Address; N : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Realloc, "realloc");

   function C_Calloc (N, Size : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Calloc, "calloc");

   Heap_Start : Storage_Element
     with Import, Convention => C, External_Name => "__heap_start";
   Heap_End   : Storage_Element
     with Import, Convention => C, External_Name => "__heap_end";

   function Image (N : Natural) return Bare_Console.U64;

   function Image (N : Natural) return Bare_Console.U64 is
   begin
      return Bare_Console.U64 (N);
   end Image;

   --  mstatus.MIE, the interrupt enable bit of the hart.
   function Interrupts_On return Boolean;

   function Interrupts_On return Boolean is
      Status : Interfaces.Unsigned_64;
   begin
      System.Machine_Code.Asm
        ("csrr %0, mstatus",
         Outputs  => Interfaces.Unsigned_64'Asm_Output ("=r", Status),
         Volatile => True);
      return (Status and 8) /= 0;
   end Interrupts_On;

   --  The block B of N bytes is filled with a content that depends on Tag.
   procedure Fill (B : System.Address; N : Natural; Tag : Natural);
   function Holds (B : System.Address; N : Natural; Tag : Natural)
                   return Boolean;

   procedure Fill (B : System.Address; N : Natural; Tag : Natural) is
      Data : Storage_Array (1 .. Storage_Count (N))
        with Import, Address => B;
   begin
      for I in Data'Range loop
         Data (I) := Storage_Element ((Tag * 17 + Natural (I) * 3) mod 253);
      end loop;
   end Fill;

   function Holds (B : System.Address; N : Natural; Tag : Natural)
                   return Boolean
   is
      Data : Storage_Array (1 .. Storage_Count (N))
        with Import, Address => B;
   begin
      for I in Data'Range loop
         if Data (I) /= Storage_Element ((Tag * 17 + Natural (I) * 3) mod 253)
         then
            return False;
         end if;
      end loop;
      return True;
   end Holds;

   --  A pseudo-random number, 0 .. Modulo - 1.
   Seed : Interfaces.Unsigned_32 := 2_463_534_242;

   function Random (Modulo : Positive) return Natural;

   function Random (Modulo : Positive) return Natural is
      use type Interfaces.Unsigned_32;
   begin
      Seed := Seed * 1_103_515_245 + 12_345;
      return Natural
        (Interfaces.Shift_Right (Seed, 8) mod Interfaces.Unsigned_32 (Modulo));
   end Random;

   Free_At_Start      : Storage_Count;
   Free_Before_Raise  : Storage_Count;
   Raised             : Boolean := False;
   Aligned            : Boolean := True;
   Start_Interrupts   : Boolean;

   procedure Raise_And_Handle;

   procedure Raise_And_Handle is
   begin
      raise Program_Error with "the first raise";
   exception
      when Program_Error =>
         Raised := True;
   end Raise_And_Handle;

   --  Whether a block lies inside the heap.
   function Inside_Heap (B : System.Address; N : Natural) return Boolean;

   function Inside_Heap (B : System.Address; N : Natural) return Boolean is
   begin
      return B >= Heap_Start'Address
        and then B + Storage_Count (N) <= Heap_End'Address;
   end Inside_Heap;

   ----------------------------------------------------------------------
   --  Blocks that are allocated, filled, checked, reallocated and freed
   --  at random.
   ----------------------------------------------------------------------

   Operations  : Natural := 0;
   Mismatches  : Natural := 0;
   Chain_Bad   : Natural := 0;
   Refusals    : Natural := 0;
   Next_Tag    : Natural := 1;

   procedure Random_Operation;

   procedure Random_Operation is
      S   : constant Positive := Random (Slots) + 1;
      Len : Natural;
   begin
      Operations := Operations + 1;
      if Block (S) = System.Null_Address then
         --  Mostly small blocks, some of a few KiB.
         Len := (if Random (10) = 0 then 1000 + Random (3000)
                 else 1 + Random (400));
         Block (S) := C_Malloc (Interfaces.C.size_t (Len));
         if Block (S) = System.Null_Address then
            Refusals := Refusals + 1;
         else
            Size (S) := Len;
            Tag (S) := Next_Tag;
            Next_Tag := Next_Tag + 1;
            Fill (Block (S), Len, Tag (S));
            if not Inside_Heap (Block (S), Len)
              or else Interfaces.Unsigned_64 (To_Integer (Block (S))) mod 16
                      /= 0
            then
               Aligned := False;
            end if;
         end if;
      else
         if not Holds (Block (S), Size (S), Tag (S)) then
            Mismatches := Mismatches + 1;
         end if;
         case Random (3) is
            when 0 | 1 =>
               C_Free (Block (S));
               Block (S) := System.Null_Address;
            when others =>
               Len := 1 + Random (800);
               declare
                  New_Block : constant System.Address :=
                    C_Realloc (Block (S), Interfaces.C.size_t (Len));
                  Kept      : constant Natural := Natural'Min (Len, Size (S));
               begin
                  if New_Block = System.Null_Address then
                     Refusals := Refusals + 1;   --  the old block stays
                  else
                     --  The part that is kept is what it was.
                     if not Holds (New_Block, Kept, Tag (S)) then
                        Mismatches := Mismatches + 1;
                     end if;
                     Block (S) := New_Block;
                     Size (S) := Len;
                     Tag (S) := Next_Tag;
                     Next_Tag := Next_Tag + 1;
                     Fill (Block (S), Len, Tag (S));
                  end if;
               end;
         end case;
      end if;
      if Operations mod 500 = 0 and then not MPFS_Heap.Invariants_Hold then
         Chain_Bad := Chain_Bad + 1;
      end if;
   end Random_Operation;

   procedure Free_All;

   procedure Free_All is
   begin
      for S in Block'Range loop
         if Block (S) /= System.Null_Address then
            if not Holds (Block (S), Size (S), Tag (S)) then
               Mismatches := Mismatches + 1;
            end if;
            C_Free (Block (S));
            Block (S) := System.Null_Address;
         end if;
      end loop;
   end Free_All;

   ----------------------------------------------------------------------
   --  Fragmentation: 2000 blocks of 256 bytes.
   ----------------------------------------------------------------------

   --  Ada's access types: new, and Unchecked_Deallocation.
   type Text_Access is access String;
   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   type Big_Access is access Storage_Array;
   procedure Free is new
     Ada.Unchecked_Deallocation (Storage_Array, Big_Access);

   Text  : Text_Access;
   Big   : Big_Access;
   Probe : System.Address;
   Held  : Storage_Count;
   Taken : Natural;
   Count : Natural;
   First : System.Address;

   Deadline : Time;

begin
   case Bare_Console.Hart_Id is
      when 0      => Test_Report.Start ("heap_test_e51");
      when others => Test_Report.Start ("heap_test_u54");
   end case;

   --  ------------------------------------------------------------------
   --  The symbols.
   --  ------------------------------------------------------------------
   Test_Report.Info ("heap size", Bare_Console.U64 (MPFS_Heap.Heap_Size));
   Test_Report.Check
     (MPFS_Heap.Heap_Size >= 512 * 1024,
      "the heap is at least 512 KiB (the range __heap_start .. __heap_end)");
   Test_Report.Check
     (To_Integer (Heap_End'Address) - To_Integer (Heap_Start'Address)
      = Integer_Address (MPFS_Heap.Heap_Size),
      "the heap size is the distance of the two symbols");

   Free_Before_Raise := MPFS_Heap.Free_Bytes;
   Test_Report.Check
     (MPFS_Heap.Heap_Size - Free_Before_Raise >= 1024,
      "libgcc's unwinder took memory from this heap before main (the sorted "
      & "frame descriptions of the warm-up)");
   Raise_And_Handle;
   Test_Report.Check (Raised, "an exception is raised and handled");
   Test_Report.Check
     (MPFS_Heap.Free_Bytes = Free_Before_Raise,
      "the first raise takes no memory from this heap: libgcc sorted its "
      & "frame descriptions (a malloc) before main");
   Test_Report.Check
     (MPFS_Heap.Invariants_Hold, "the chain of blocks is intact after it");

   Free_At_Start := MPFS_Heap.Free_Bytes;
   Test_Report.Info ("free bytes", Bare_Console.U64 (Free_At_Start));

   --  The lock leaves the interrupts as it found them.
   Start_Interrupts := Interrupts_On;
   Test_Report.Check (Start_Interrupts, "interrupts are enabled in the task");
   declare
      Outer : constant MPFS_Heap_Lock.Saved_State := MPFS_Heap_Lock.Acquire;
      Off   : constant Boolean := not Interrupts_On;
      Inner : constant MPFS_Heap_Lock.Saved_State := MPFS_Heap_Lock.Acquire;
      Still : constant Boolean := not Interrupts_On;
   begin
      MPFS_Heap_Lock.Release (Inner);
      Test_Report.Check
        (Off and then Still and then not Interrupts_On,
         "Acquire masks the interrupts, also nested");
      MPFS_Heap_Lock.Release (Outer);
   end;
   Test_Report.Check
     (Interrupts_On, "Release enables them again, the outer one last");
   Probe := C_Malloc (100);
   Test_Report.Check
     (Interrupts_On, "malloc leaves the interrupts enabled");
   C_Free (Probe);

   --  ------------------------------------------------------------------
   --  The interface.
   --  ------------------------------------------------------------------
   for N in 1 .. 100 loop
      Probe := C_Malloc (Interfaces.C.size_t (N));
      if Probe = System.Null_Address
        or else To_Integer (Probe) mod 16 /= 0
        or else not Inside_Heap (Probe, N)
      then
         Aligned := False;
      end if;
      C_Free (Probe);
   end loop;
   Test_Report.Check
     (Aligned, "blocks of 1 to 100 bytes are 16-byte aligned, in the heap");
   Test_Report.Check
     (MPFS_Heap.Free_Bytes = Free_At_Start,
      "freeing them gives the heap back");

   Test_Report.Check
     (C_Malloc (0) = System.Null_Address, "malloc (0) returns no block");
   Test_Report.Check
     (C_Malloc (Interfaces.C.size_t'Last) = System.Null_Address
      and then C_Malloc (2 ** 40) = System.Null_Address
      and then C_Malloc (2 ** 32) = System.Null_Address,
      "malloc refuses a request that no heap can serve");
   Test_Report.Check
     (C_Calloc (2 ** 33, 2 ** 33) = System.Null_Address
      and then C_Calloc (Interfaces.C.size_t'Last, 2) = System.Null_Address
      and then C_Calloc (2 ** 60, 16) = System.Null_Address,
      "calloc refuses a product that wraps");
   C_Free (System.Null_Address);
   Test_Report.Check
     (MPFS_Heap.Free_Bytes = Free_At_Start and then MPFS_Heap.Invariants_Hold,
      "the refused requests and free (null) changed nothing");

   --  calloc returns zeros, also in a block that has been used.
   Probe := C_Malloc (500);
   Fill (Probe, 500, 9);
   C_Free (Probe);
   Probe := C_Calloc (50, 10);
   declare
      Data : Storage_Array (1 .. 500) with Import, Address => Probe;
   begin
      Test_Report.Check
        (Probe /= System.Null_Address
         and then (for all B of Data => B = 0),
         "calloc returns zeros, though the block was used before");
   end;
   C_Free (Probe);

   --  realloc
   Probe := C_Realloc (System.Null_Address, 64);
   Test_Report.Check
     (Probe /= System.Null_Address, "realloc (null, n) is malloc (n)");
   Fill (Probe, 64, 3);
   First := C_Realloc (Probe, 10);
   Test_Report.Check
     (First = Probe and then Holds (First, 10, 3),
      "realloc to less keeps the block");
   Probe := C_Realloc (First, 5000);
   Test_Report.Check
     (Probe /= System.Null_Address and then Holds (Probe, 10, 3),
      "realloc to more keeps the content");
   Test_Report.Check
     (C_Realloc (Probe, 0) = System.Null_Address
      and then MPFS_Heap.Free_Bytes = Free_At_Start,
      "realloc (p, 0) frees the block");

   --  new and Unchecked_Deallocation
   Text := new String'("a string on the heap");
   Test_Report.Check
     (Text.all = "a string on the heap"
      and then MPFS_Heap.Free_Bytes < Free_At_Start,
      "new takes the memory from this heap");
   Free (Text);
   Test_Report.Check
     (Text = null and then MPFS_Heap.Free_Bytes = Free_At_Start,
      "Unchecked_Deallocation gives it back");

   --  ------------------------------------------------------------------
   --  Random sequences.
   --  ------------------------------------------------------------------
   for I in 1 .. 20_000 loop
      Random_Operation;
   end loop;
   Test_Report.Info ("operations", Image (Operations));
   Test_Report.Info ("refused requests", Image (Refusals));
   Test_Report.Check (Mismatches = 0, "no block changed its content");
   Test_Report.Check
     (Aligned, "every block was 16-byte aligned and in the heap");
   Test_Report.Check
     (Chain_Bad = 0 and then MPFS_Heap.Invariants_Hold,
      "the chain of blocks was intact all along");
   Free_All;
   Test_Report.Check
     (Mismatches = 0 and then MPFS_Heap.Free_Bytes = Free_At_Start
      and then MPFS_Heap.Invariants_Hold,
      "after freeing everything the heap is as large as before");

   --  Everything is back in one piece: a block of nine tenths of the heap
   --  can be had, which it could not be if the blocks had not coalesced.
   Held := Free_At_Start / 10 * 9;
   Probe := C_Malloc (Interfaces.C.size_t (Held));
   Test_Report.Check
     (Probe /= System.Null_Address,
      "after the random sequences a block of 90 % of the heap is available");
   C_Free (Probe);

   --  ------------------------------------------------------------------
   --  Fragmentation.
   --  ------------------------------------------------------------------
   for I in Pool'Range loop
      Pool (I) := C_Malloc (256);
      Fill (Pool (I), 256, I);
   end loop;
   Test_Report.Check
     (Pool (Many) /= System.Null_Address and then MPFS_Heap.Invariants_Hold,
      "2000 blocks of 256 bytes");
   for I in Pool'Range loop
      if I mod 2 = 0 then
         C_Free (Pool (I));
         Pool (I) := System.Null_Address;
      end if;
   end loop;
   Taken := 0;
   for I in Pool'Range loop
      if Pool (I) = System.Null_Address then
         Pool (I) := C_Malloc (256);
         if Pool (I) /= System.Null_Address then
            Taken := Taken + 1;
            Fill (Pool (I), 256, I);
         end if;
      end if;
   end loop;
   Test_Report.Check
     (Taken = Many / 2 and then MPFS_Heap.Invariants_Hold,
      "the holes of the freed blocks take the next 1000 of the same size");
   Count := 0;
   for I in Pool'Range loop
      if not Holds (Pool (I), 256, I) then
         Count := Count + 1;
      end if;
      C_Free (Pool (I));
      Pool (I) := System.Null_Address;
   end loop;
   Test_Report.Check (Count = 0, "none of the 2000 blocks was disturbed");
   Test_Report.Check
     (MPFS_Heap.Free_Bytes = Free_At_Start and then MPFS_Heap.Invariants_Hold,
      "freeing them coalesces everything: the heap is as large as before");

   --  ------------------------------------------------------------------
   --  The limit.
   --  ------------------------------------------------------------------
   --  Blocks of 4 KiB until nothing is left; the first word of a block is
   --  the next one.
   First := System.Null_Address;
   Count := 0;
   loop
      Probe := C_Malloc (4096);
      exit when Probe = System.Null_Address;
      declare
         Link : System.Address with Import, Address => Probe;
      begin
         Link := First;
      end;
      First := Probe;
      Count := Count + 1;
   end loop;
   Test_Report.Info ("blocks of 4 KiB", Image (Count));
   Test_Report.Check
     (Storage_Count (Count) * 4096 >= Free_At_Start / 10 * 8,
      "4 KiB blocks take at least 80 % of the heap before malloc fails");
   Test_Report.Check
     (MPFS_Heap.Invariants_Hold
      and then MPFS_Heap.Free_Bytes < 8192,
      "malloc failed because nothing was left");

   begin
      Big := new Storage_Array (1 .. 1024 * 1024);
      Test_Report.Check (False, "new raises Storage_Error on an empty heap");
      Free (Big);
   exception
      when Storage_Error =>
         Test_Report.Check (True, "new raises Storage_Error on an empty heap");
   end;

   --  Everything back.
   while First /= System.Null_Address loop
      declare
         Link : System.Address with Import, Address => First;
         Next : constant System.Address := Link;
      begin
         C_Free (First);
         First := Next;
      end;
   end loop;
   Test_Report.Check
     (MPFS_Heap.Free_Bytes = Free_At_Start and then MPFS_Heap.Invariants_Hold,
      "freeing the 4 KiB blocks gives the whole heap back");
   Big := new Storage_Array (1 .. 1024 * 1024);
   Test_Report.Check
     (Big'Length = 1024 * 1024, "new can take 1 MiB again");
   Free (Big);

   --  ------------------------------------------------------------------
   --  A task of a higher priority that allocates and frees at the same time.
   --  ------------------------------------------------------------------
   Heap_Hammer.Go := True;
   Deadline := Clock + Seconds (10);
   while not Heap_Hammer.Done and then Clock < Deadline loop
      for I in 1 .. 300 loop
         Random_Operation;
      end loop;
   end loop;
   Free_All;
   Test_Report.Check
     (Heap_Hammer.Done, "the task of higher priority finished");
   Test_Report.Info ("blocks of the task", Image (Heap_Hammer.Allocated));
   Test_Report.Check
     (Heap_Hammer.Disturbed = 0 and then Mismatches = 0,
      "no block was disturbed while two tasks allocated and freed");
   Test_Report.Check
     (Heap_Hammer.Refused = 0 and then Heap_Hammer.Allocated = 40 * 16,
      "all the blocks of the task were served");
   Test_Report.Check
     (MPFS_Heap.Free_Bytes = Free_At_Start and then MPFS_Heap.Invariants_Hold,
      "the heap is as large as before");

   Test_Report.Finish;
end Heap_Test;
