--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The input of the checker as it is read from the check input of the generator: the target (the
--  partitions with their harts, windows and peripherals, the memories of the harts, the critical
--  blocks, the page of mtime, the bus windows of the AMP contexts) and the PMP of each hart (the
--  entries of the MSS Configurator XML and the generated unlocked ones), and the way masks of the L2.
--
--  @req GEN-015

package Pmp_Check.Model
  with SPARK_Mode
is
   Name_Capacity : constant := 64;

   type Name is record
      Data : String (1 .. Name_Capacity) := [others => ' '];
      Len  : Natural range 0 .. Name_Capacity := 0;
   end record;

   function Image (N : Name) return String is (N.Data (1 .. N.Len));

   function Named (N : Name; S : String) return Boolean is (Image (N) = S);

   function Same (A, B : Name) return Boolean is (Image (A) = Image (B));

   type Hart_Id is range 0 .. 4;
   type Hart_Set is array (Hart_Id) of Boolean;

   type Entry_Index is range 0 .. 15;
   Hart_Entries : constant := 16;              --  the PMP CSRs of a hart (pmpcfg0, pmpcfg2)

   --  The bits of pmpaddr that a hart implements (WARL); 54 is all of RV64.
   subtype Pmpaddr_Bits is Positive range 1 .. 54;

   type Cfg_Array is array (Entry_Index) of U8;
   type Addr_Array is array (Entry_Index) of U64;

   --  A generated entry may have an index beyond the CSRs of the hart: the allow list that does not
   --  fit (the checker reports it and leaves it out of the evaluation, as the hart would).
   Max_Generated : constant := 64;
   type Generated_Entry is record
      Index : Natural range 0 .. 255 := 0;
      Cfg   : U8 := 0;
      Addr  : U64 := 0;
   end record;
   type Generated_Array is array (1 .. Max_Generated) of Generated_Entry;

   type Hart_Pmp is record
      Bits      : Pmpaddr_Bits := 54;
      Cfg       : Cfg_Array := [others => 0];   --  the table of the XML
      Addr      : Addr_Array := [others => 0];
      Gen       : Generated_Array;               --  the generated entries, in index order
      Gen_Count : Natural range 0 .. Max_Generated := 0;
   end record;
   type Hart_Array is array (Hart_Id) of Hart_Pmp;

   --  The bytes [First, Last], Last below Max_Address.
   type Span is record
      First : Address := 0;
      Last  : Address := 0;
   end record;

   function Valid (S : Span) return Boolean is (S.First <= S.Last and then S.Last < Max_Address);

   function Holds (S : Span; A : Address) return Boolean is (S.First <= A and then A <= S.Last);

   --  A block of registers: <Label> is the peripheral of system.yaml or the name of the critical
   --  block, <Svd> the block of the SVD; <Hart> the hart of a bus error unit.
   type Block is record
      Label    : Name;
      Svd      : Name;
      Where    : Span;
      Has_Hart : Boolean := False;
      Hart     : Hart_Id := 0;
   end record;
   Max_Blocks : constant := 64;
   subtype Block_Count is Natural range 0 .. Max_Blocks;
   type Block_Array is array (1 .. Max_Blocks) of Block;

   Max_Partitions : constant := 5;
   subtype Partition_Count is Natural range 0 .. Max_Partitions;
   subtype Partition_Index is Positive range 1 .. Max_Partitions;

   type Partition is record
      Label       : Name;
      Harts       : Hart_Set := [others => False];
      User        : Boolean := False;          --  priv u
      Monitor     : Boolean := False;
      Blocks      : Block_Array;               --  its peripherals and console at their address
      Block_Count : Pmp_Check.Model.Block_Count := 0;
   end record;
   type Partition_Array is array (Partition_Index) of Partition;

   type Window_Kind is (Code_Data, Code, Data, Fast_Text, Ipc);
   type Owner_Array is array (1 .. 2) of Partition_Index;

   type Window is record
      Kind        : Window_Kind := Data;
      Memory      : Name;
      Where       : Span;
      Owners      : Owner_Array := [others => 1];
      Owner_Count : Positive range 1 .. 2 := 1;
      Channel     : Name;                      --  empty for a window of a partition
   end record;
   Max_Windows : constant := 64;
   subtype Window_Count is Natural range 0 .. Max_Windows;
   type Window_Array is array (1 .. Max_Windows) of Window;

   type Memory is record
      Label    : Name;
      Where    : Span;
      Has_Hart : Boolean := False;             --  the ITIM or DTIM of a hart
      Hart     : Hart_Id := 0;
      Itim     : Boolean := False;
   end record;
   Max_Memories : constant := 32;
   subtype Memory_Count is Natural range 0 .. Max_Memories;
   type Memory_Array is array (1 .. Max_Memories) of Memory;

   type Way_Mask is record
      Master : Name;
      Mask   : U64 := 0;
   end record;
   Max_Masters : constant := 32;
   subtype Master_Count is Natural range 0 .. Max_Masters;
   type Way_Mask_Array is array (1 .. Max_Masters) of Way_Mask;

   type System is record
      Prod             : Boolean := True;      --  security_profile prod
      Pmp_Enabled      : Boolean := False;     --  MEM_CONFIGS_ENABLED.PMP
      Target_Entries   : Positive range 1 .. Hart_Entries := Hart_Entries;
      Harts            : Hart_Array;
      A_Harts, B_Harts : Hart_Set := [others => False];
      Partitions       : Partition_Array;
      Partition_Count  : Pmp_Check.Model.Partition_Count := 0;
      Windows          : Window_Array;
      Window_Count     : Pmp_Check.Model.Window_Count := 0;
      Memories         : Memory_Array;
      Memory_Count     : Pmp_Check.Model.Memory_Count := 0;
      Critical         : Block_Array;
      Critical_Count   : Block_Count := 0;
      Mtime            : Span;
      Lo_Bus, Hi_Bus   : Block_Array;
      Lo_Count         : Block_Count := 0;
      Hi_Count         : Block_Count := 0;
      Way_Enable       : U64 := 0;
      Scratchpad_Ways  : U64 := 0;
      Masks            : Way_Mask_Array;
      Mask_Count       : Master_Count := 0;
   end record;

   type Context is (None, A, B);

   --  The context of a hart: A if CONTEXT_A_HART_EN has it, else B if CONTEXT_B_HART_EN has it.
   function Context_Of (S : System; H : Hart_Id) return Context is
     (if S.A_Harts (H) then A elsif S.B_Harts (H) then B else None);

   --  The lowest hart of a partition (hart 0 for a partition without harts, which the reader refuses).
   function Lowest_Hart (P : Partition) return Hart_Id is
     (if P.Harts (0) then 0 elsif P.Harts (1) then 1 elsif P.Harts (2) then 2
      elsif P.Harts (3) then 3 elsif P.Harts (4) then 4 else 0);

   --  The context of a partition: that of its lowest hart.
   function Context_Of (S : System; P : Partition) return Context is (Context_Of (S, Lowest_Hart (P)));

end Pmp_Check.Model;
