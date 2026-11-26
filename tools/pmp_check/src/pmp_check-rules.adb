--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The rules the checker evaluates.

with Pmp_Check.Eval;
with Pmp_Check.Mpu;
with Pmp_Check.Texts;

package body Pmp_Check.Rules
  with SPARK_Mode
is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;
   use Model;
   use Eval;
   use Findings;

   subtype Path_Text is Texts.Text (Findings.Path_Capacity);
   subtype Message_Text is Texts.Text (Findings.Message_Capacity);

   function To_Name (S : String) return Name is
      N : Name;
   begin
      for C of S loop
         exit when N.Len = Name_Capacity;
         N.Len := N.Len + 1;
         N.Data (N.Len) := C;
      end loop;
      return N;
   end To_Name;

   function Digit (N : Natural) return String is
     (if N <= 9 then [1 => Character'Val (Character'Pos ('0') + N)] else "?");

   procedure Append_Name (T : in out Texts.Text; N : Name) is
   begin
      Texts.Append (T, Image (N));
   end Append_Name;

   procedure Append_Quoted (T : in out Texts.Text; N : Name) is
   begin
      Texts.Append (T, "'");
      Texts.Append (T, Image (N));
      Texts.Append (T, "'");
   end Append_Quoted;

   function Rights_Image (R : Rights) return String is
     ([1 => (if R (Read) then 'r' else '-'), 2 => (if R (Write) then 'w' else '-'),
       3 => (if R (Execute) then 'x' else '-')]);

   function Has (Granted, Needed : Rights) return Boolean is
     (for all K in Access_Kind => (if Needed (K) then Granted (K)));

   function Needs (K : Window_Kind) return Rights is
     (case K is
         when Code_Data       => All_Granted,
         when Code | Fast_Text => [Read => True, Write => False, Execute => True],
         when Data | Ipc      => [Read => True, Write => True, Execute => False]);

   function Kind_Image (K : Window_Kind) return String is
     (case K is
         when Code_Data => "code+data",
         when Code      => "code",
         when Data      => "data",
         when Fast_Text => "fast_text",
         when Ipc       => "ipc");

   procedure Partition_Path (T : in out Texts.Text; Index : Partition_Index; Suffix : String) is
   begin
      Texts.Clear (T);
      Texts.Append (T, "partitions[");
      Texts.Append_Natural (T, Index - 1);
      Texts.Append (T, "]");
      Texts.Append (T, Suffix);
   end Partition_Path;

   procedure Section_Path (T : in out Texts.Text; H : Hart_Id) is
   begin
      Texts.Clear (T);
      Texts.Append (T, "mss_memory_map/pmp_h");
      Texts.Append (T, Digit (Natural (H)));
   end Section_Path;

   function Owned (W : Window; P : Partition_Index) return Boolean is
     (W.Owners (1) = P or else (W.Owner_Count = 2 and then W.Owners (2) = P));

   --  The table of the XML of a hart with its generated entries set at their indices (those beyond the
   --  CSRs of the hart left out).
   procedure Combine (P : Hart_Pmp; Cfg : out Cfg_Array; Addr : out Addr_Array) is
   begin
      Cfg := P.Cfg;
      Addr := P.Addr;
      for G in 1 .. P.Gen_Count loop
         if P.Gen (G).Index < Hart_Entries then
            Cfg (Entry_Index (P.Gen (G).Index)) := P.Gen (G).Cfg;
            Addr (Entry_Index (P.Gen (G).Index)) := P.Gen (G).Addr;
         end if;
      end loop;
   end Combine;

   ---------------------------------------------------------------------------------------------------
   --  The PMP table of the XML of a hart

   procedure Layout (S : System; H : Hart_Id; F : in out List) is
      P     : Hart_Pmp renames S.Harts (H);
      T     : constant Table := Decode (P.Cfg, P.Addr, P.Bits);
      Path  : Path_Text;
      Msg   : Message_Text;
      First_Unlocked : Integer := -1;
      Beyond : Boolean := False;
   begin
      for I in Entry_Index loop
         declare
            C : constant U8 := P.Cfg (I);
         begin
            if C mod 4 = 2 or else (C / 32) mod 4 /= 0 then
               Section_Path (Path, H);
               Texts.Append (Path, (if I < 8 then "/CSR_PMPCFG0.PMP" else "/CSR_PMPCFG2.PMP"));
               Texts.Append_Natural (Path, Natural (I));
               Texts.Append (Path, "CFG");
               Texts.Clear (Msg);
               Texts.Append_Hex (Msg, U64 (C));
               if C mod 4 = 2 then
                  Texts.Append (Msg, " has W without R (reserved)");
                  Add (F, E100, S.Prod, Texts.Image (Path), Msg);
               end if;
               if (C / 32) mod 4 /= 0 then
                  Texts.Clear (Msg);
                  Texts.Append_Hex (Msg, U64 (C));
                  Texts.Append (Msg, " sets the reserved bits 5 and 6");
                  Add (F, E101, S.Prod, Texts.Image (Path), Msg);
               end if;
            end if;
            if First_Unlocked < 0 and then Mode_Of (C) /= Off and then not Has_L (C) then
               First_Unlocked := Integer (I);
            end if;
            if Natural (I) >= S.Target_Entries and then (Mode_Of (C) /= Off or else Has_L (C)) then
               Beyond := True;
            end if;
         end;
      end loop;

      if First_Unlocked >= 0 then
         for I in Entry_Index loop
            if Integer (I) > First_Unlocked and then Has_L (P.Cfg (I)) then
               Section_Path (Path, H);
               Texts.Append (Path, "/PMP");
               Texts.Append_Natural (Path, Natural (I));
               Texts.Append (Path, "CFG");
               Texts.Clear (Msg);
               Texts.Append (Msg, "entry ");
               Texts.Append_Natural (Msg, Natural (I));
               Texts.Append (Msg, " of hart ");
               Texts.Append (Msg, Digit (Natural (H)));
               Texts.Append (Msg, " is locked, after the unlocked entry ");
               Texts.Append_Natural (Msg, First_Unlocked);
               Add (F, E102, S.Prod, Texts.Image (Path), Msg);
               exit;
            end if;
         end loop;
      end if;

      if Beyond then
         Section_Path (Path, H);
         Texts.Clear (Msg);
         Texts.Append (Msg, "hart ");
         Texts.Append (Msg, Digit (Natural (H)));
         Texts.Append (Msg, " uses entries beyond the ");
         Texts.Append_Natural (Msg, S.Target_Entries);
         Texts.Append (Msg, " of the target:");
         for I in Entry_Index loop
            if Natural (I) >= S.Target_Entries and then (Mode_Of (P.Cfg (I)) /= Off or else Has_L (P.Cfg (I)))
            then
               Texts.Append (Msg, " ");
               Texts.Append_Natural (Msg, Natural (I));
            end if;
         end loop;
         Add (F, E103, S.Prod, Texts.Image (Path), Msg);
      end if;

      for I in Entry_Index loop
         if T (I).Active and then T (I).Locked and then (T (I).R or else T (I).W or else T (I).X) then
            declare
               Whole  : constant Boolean := T (I).First = 0 and then T (I).Last = Space (P.Bits) - 1;
               Hidden : Boolean := False;
            begin
               for J in Entry_Index loop
                  if J > I and then T (J).Active and then T (I).First <= T (J).First
                    and then T (J).Last <= T (I).Last
                  then
                     Hidden := True;
                  end if;
               end loop;
               if Whole or else Hidden then
                  Section_Path (Path, H);
                  Texts.Append (Path, "/PMP");
                  Texts.Append_Natural (Path, Natural (I));
                  Texts.Append (Path, "CFG");
                  Texts.Clear (Msg);
                  Texts.Append (Msg, "entry ");
                  Texts.Append_Natural (Msg, Natural (I));
                  Texts.Append (Msg, " of hart ");
                  Texts.Append (Msg, Digit (Natural (H)));
                  Texts.Append (Msg, " is locked and grants ");
                  Texts.Append (Msg, Rights_Image (Rights_Of (T (I))));
                  Texts.Append (Msg, " to all modes over ");
                  if Whole then
                     Texts.Append (Msg, "the whole address space");
                  else
                     Texts.Append_Range (Msg, T (I).First, T (I).Last);
                     Texts.Append (Msg, ", hiding a later entry");
                  end if;
                  Add (F, E105, S.Prod, Texts.Image (Path), Msg);
               end if;
            end;
         end if;
      end loop;
   end Layout;

   ---------------------------------------------------------------------------------------------------
   --  The PMP of the harts of a partition against its zones

   type Kind_Or_Other is (Own, Foreign, Peer, Grant, Critical, Bus, Other);

   --  Whether reaching a zone of kind <K> in mode <Md> is a finding, and its code.
   function Reports (K : Kind_Or_Other; Md : Mode) return Boolean is
     (case Md is
         when U => K /= Own,
         when M => K not in Own | Other);

   function Code_For (K : Kind_Or_Other; Md : Mode; Locked : Boolean) return Rule_Code is
     (case Md is
         when U =>
           (case K is
               when Own | Foreign => E124,
               when Peer          => (if Locked then E136 else E124),
               when Grant         => E126,
               when Critical      => E125,
               when Bus           => E135,
               when Other         => E123),
         when M =>
           (case K is
               when Own | Other | Foreign => E124,
               when Peer                  => E128,
               when Grant | Critical      => E127,
               when Bus                   => E135));

   Max_Pieces : constant := 6;
   type Piece is record
      Zone  : Zone_Hit := 0;
      First : Address := 0;
      Last  : Address := 0;
   end record;
   type Piece_Array is array (1 .. Max_Pieces) of Piece;
   type Reach is record
      Hit    : Boolean := False;
      Pieces : Piece_Array;
      Count  : Natural range 0 .. Max_Pieces := 0;
      More   : Natural := 0;
   end record;
   type Reach_Table is array (Mode, Rule_Code) of Reach;

   procedure Note_Piece (R : in out Reach; Zone : Zone_Hit; First, Last : Address) is
   begin
      R.Hit := True;
      if R.Count > 0 and then R.Pieces (R.Count).Zone = Zone and then R.Pieces (R.Count).Last < Last
        and then R.Pieces (R.Count).Last + 1 = First
      then
         R.Pieces (R.Count).Last := Last;
      elsif R.Count < Max_Pieces then
         R.Count := R.Count + 1;
         R.Pieces (R.Count) := (Zone => Zone, First => First, Last => Last);
      elsif R.More < Natural'Last then
         R.More := R.More + 1;
      end if;
   end Note_Piece;

   procedure Partition_Rules (S : System; Pi : Partition_Index; F : in out List)
     with Pre => Pi <= S.Partition_Count
   is
      P    : Partition renames S.Partitions (Pi);
      Ctx  : constant Context := Context_Of (S, P);
      Z    : Zone_Array := [others => (others => <>)];
      NZ   : Zone_Count := 0;
      Path : Path_Text;
      Msg  : Message_Text;

      procedure Add_Zone (Where : Span; Kind : Zone_Kind; Label : Name) is
      begin
         if NZ < Max_Zones then
            NZ := NZ + 1;
            Z (NZ) := (Where => Where, Kind => Kind, Label => Label);
         end if;
      end Add_Zone;

      function Kind_By (Their : Context) return Zone_Kind is
        (if Ctx /= None and then Their = Ctx then Peer else Foreign);

      function Owns_Envm return Boolean is
        (for some B in 1 .. P.Block_Count => Named (P.Blocks (B).Label, "envm"));

      function Used (Memory_Name : Name) return Boolean is
        (for some W in 1 .. S.Window_Count => Same (S.Windows (W).Memory, Memory_Name));

      --  Whether <W> is the window of a hart: any window but fast_text, which only in the ITIM of <H>.
      function Applies (W : Window; H : Hart_Id) return Boolean is
        (W.Kind /= Fast_Text
         or else (for some M in 1 .. S.Memory_Count =>
                    S.Memories (M).Itim and then S.Memories (M).Has_Hart and then S.Memories (M).Hart = H
                    and then Same (S.Memories (M).Label, W.Memory)));

      procedure Build_Zones is
         Label : Texts.Text (Name_Capacity);
      begin
         for W in 1 .. S.Window_Count loop
            if Owned (S.Windows (W), Pi) then
               Add_Zone (S.Windows (W).Where, Own, To_Name (""));
            end if;
         end loop;
         for B in 1 .. P.Block_Count loop
            Add_Zone (P.Blocks (B).Where, Own, To_Name (""));
         end loop;
         Add_Zone (S.Mtime, Own, To_Name (""));

         for W in 1 .. S.Window_Count loop
            declare
               Win  : Window renames S.Windows (W);
               Peer_Owner : constant Boolean :=
                 Kind_By (Context_Of (S, S.Partitions (Win.Owners (1)))) = Peer
                 or else (Win.Owner_Count = 2
                          and then Kind_By (Context_Of (S, S.Partitions (Win.Owners (2)))) = Peer);
            begin
               if not Owned (Win, Pi) then
                  Texts.Clear (Label);
                  if Win.Channel.Len > 0 then
                     Texts.Append (Label, "channel ");
                     Append_Quoted (Label, Win.Channel);
                  else
                     Texts.Append (Label, Kind_Image (Win.Kind));
                     Texts.Append (Label, " of ");
                     Append_Quoted (Label, S.Partitions (Win.Owners (1)).Label);
                  end if;
                  Add_Zone (Win.Where, (if Peer_Owner then Peer else Foreign), To_Name (Texts.Image (Label)));
               end if;
            end;
         end loop;

         for M in 1 .. S.Memory_Count loop
            declare
               Mem : Memory renames S.Memories (M);
            begin
               if Mem.Has_Hart and then not P.Harts (Mem.Hart) and then (not Mem.Itim or else Used (Mem.Label))
               then
                  Texts.Clear (Label);
                  Append_Name (Label, Mem.Label);
                  Texts.Append (Label, " of hart ");
                  Texts.Append (Label, Digit (Natural (Mem.Hart)));
                  Add_Zone (Mem.Where, Kind_By (Context_Of (S, Mem.Hart)), To_Name (Texts.Image (Label)));
               end if;
            end;
         end loop;

         for Q in 1 .. S.Partition_Count loop
            if Q /= Pi then
               for B in 1 .. S.Partitions (Q).Block_Count loop
                  Texts.Clear (Label);
                  Append_Name (Label, S.Partitions (Q).Blocks (B).Label);
                  Texts.Append (Label, " of partition ");
                  Append_Quoted (Label, S.Partitions (Q).Label);
                  Add_Zone (S.Partitions (Q).Blocks (B).Where, Kind_By (Context_Of (S, S.Partitions (Q))),
                            To_Name (Texts.Image (Label)));
               end loop;
            end if;
         end loop;

         for C in 1 .. S.Critical_Count loop
            declare
               B : Block renames S.Critical (C);
            begin
               if not (Named (B.Svd, "ENVM") and then Owns_Envm)
                 and then not (B.Has_Hart and then P.Harts (B.Hart))
               then
                  Add_Zone (B.Where,
                            (if Named (B.Label, "SYSREG") or else Named (B.Label, "MPUCFG") then Grant
                             else Critical),
                            B.Label);
               end if;
            end;
         end loop;

         if Ctx = A then
            for B in 1 .. S.Hi_Count loop
               Add_Zone (S.Hi_Bus (B).Where, Bus, To_Name ("the HI window of context B"));
            end loop;
         elsif Ctx = B then
            for B in 1 .. S.Lo_Count loop
               Add_Zone (S.Lo_Bus (B).Where, Bus, To_Name ("the LO window of context A"));
            end loop;
         end if;
      end Build_Zones;

      procedure Hart_Rules (H : Hart_Id) is
         Cfg      : Cfg_Array;
         Addr     : Addr_Array;
         Bits     : constant Pmpaddr_Bits := S.Harts (H).Bits;
         Sp       : constant Address := Space (Bits);
         T        : Table;
         Check_U  : constant Boolean := P.User;
         Check_M  : Boolean;
         Reached  : Reach_Table := [others => [others => (others => <>)]];
         Lack_Win : array (1 .. Max_Windows) of Piece := [others => (others => <>)];
         Lacks_W  : array (1 .. Max_Windows) of Boolean := [others => False];
         Lack_Blk : array (1 .. Max_Blocks) of Piece := [others => (others => <>)];
         Lacks_B  : array (1 .. Max_Blocks) of Boolean := [others => False];
         Lack_Mt  : Piece;
         Lacks_Mt : Boolean := False;
         Lo, Hi, Next : Address;
         Pt       : Point;
      begin
         Combine (S.Harts (H), Cfg, Addr);
         T := Decode (Cfg, Addr, Bits);
         Check_M := (for some I in Entry_Index => Has_L (Cfg (I))) and then not P.Monitor;

         Lo := 0;
         while Lo < Sp loop
            pragma Loop_Variant (Increases => Lo);
            Next := Next_Bound (T, Z, NZ, Lo, Sp);
            Hi := Next - 1;
            --  Every address of [Lo, Hi] is evaluated as Lo is: the rights of each mode and access,
            --  the deciding entry and the zone are those of Lo.
            Lemma_Uniform (T, Z, NZ, Lo, Hi);
            Pt := Evaluate (T, Z, NZ, Lo);
            pragma Assert (for all A in Lo .. Hi => Evaluate (T, Z, NZ, A) = Pt);

            for Md in Mode loop
               if (Md = U and then Check_U) or else (Md = M and then Check_M) then
                  declare
                     R    : constant Rights := Decide (T, Lo, Md);
                     Kind : constant Kind_Or_Other :=
                       (if Pt.Hit_Zone = 0 then Other
                        else (case Z (Pt.Hit_Zone).Kind is
                                 when Own => Own, when Foreign => Foreign, when Peer => Peer,
                                 when Grant => Grant, when Critical => Critical, when Bus => Bus));
                  begin
                     for Acc in Access_Kind loop
                        if R (Acc) and then Reports (Kind, Md) then
                           Note_Piece (Reached (Md, Code_For (Kind, Md, By_Lock (T, Lo))), Pt.Hit_Zone, Lo, Hi);
                           exit;
                        end if;
                     end loop;
                  end;
               end if;
            end loop;

            if Check_U then
               declare
                  R : constant Rights := Decide (T, Lo, U);
               begin
                  for W in 1 .. S.Window_Count loop
                     if Owned (S.Windows (W), Pi) and then Applies (S.Windows (W), H)
                       and then Holds (S.Windows (W).Where, Lo) and then not Has (R, Needs (S.Windows (W).Kind))
                       and then not Lacks_W (W)
                     then
                        Lacks_W (W) := True;
                        Lack_Win (W) := (Zone => 0, First => Lo, Last => Hi);
                     end if;
                  end loop;
                  for B in 1 .. P.Block_Count loop
                     if Holds (P.Blocks (B).Where, Lo) and then not (R (Read) and then R (Write))
                       and then not Lacks_B (B)
                     then
                        Lacks_B (B) := True;
                        Lack_Blk (B) := (Zone => 0, First => Lo, Last => Hi);
                     end if;
                  end loop;
                  if Holds (S.Mtime, Lo) and then not R (Read) and then not Lacks_Mt then
                     Lacks_Mt := True;
                     Lack_Mt := (Zone => 0, First => Lo, Last => Hi);
                  end if;
               end;
            end if;
            Lo := Next;
         end loop;

         for W in 1 .. S.Window_Count loop
            if Lacks_W (W) then
               Partition_Path (Path, Pi, ".memory");
               Texts.Clear (Msg);
               Texts.Append (Msg, "hart ");
               Texts.Append (Msg, Digit (Natural (H)));
               Texts.Append (Msg, " of ");
               Append_Quoted (Msg, P.Label);
               Texts.Append (Msg, " lacks ");
               Texts.Append (Msg, Rights_Image (Needs (S.Windows (W).Kind)));
               Texts.Append (Msg, " in U mode on its ");
               Texts.Append (Msg, Kind_Image (S.Windows (W).Kind));
               Texts.Append (Msg, " window ");
               Append_Name (Msg, S.Windows (W).Memory);
               Texts.Append (Msg, " from ");
               Texts.Append_Range (Msg, Lack_Win (W).First, Lack_Win (W).Last);
               Add (F, E120, S.Prod, Texts.Image (Path), Msg);
            end if;
         end loop;
         for B in 1 .. P.Block_Count loop
            if Lacks_B (B) then
               Partition_Path (Path, Pi, ".peripherals");
               Texts.Clear (Msg);
               Texts.Append (Msg, "hart ");
               Texts.Append (Msg, Digit (Natural (H)));
               Texts.Append (Msg, " of ");
               Append_Quoted (Msg, P.Label);
               Texts.Append (Msg, " cannot read and write ");
               Append_Name (Msg, P.Blocks (B).Label);
               Texts.Append (Msg, " in U mode at its address ");
               Texts.Append_Range (Msg, Lack_Blk (B).First, Lack_Blk (B).Last);
               Add (F, E121, S.Prod, Texts.Image (Path), Msg);
            end if;
         end loop;
         if Lacks_Mt then
            Partition_Path (Path, Pi, "");
            Texts.Clear (Msg);
            Texts.Append (Msg, "hart ");
            Texts.Append (Msg, Digit (Natural (H)));
            Texts.Append (Msg, " of ");
            Append_Quoted (Msg, P.Label);
            Texts.Append (Msg, " cannot read the page of mtime ");
            Texts.Append_Range (Msg, Lack_Mt.First, Lack_Mt.Last);
            Texts.Append (Msg, " in U mode");
            Add (F, E122, S.Prod, Texts.Image (Path), Msg);
         end if;

         for Md in Mode loop
            for C in Rule_Code loop
               if Reached (Md, C).Hit then
                  Partition_Path (Path, Pi, "");
                  Texts.Clear (Msg);
                  Texts.Append (Msg, (if Md = U then "U" else "M"));
                  Texts.Append (Msg, " mode of hart ");
                  Texts.Append (Msg, Digit (Natural (H)));
                  Texts.Append (Msg, " (");
                  Append_Quoted (Msg, P.Label);
                  Texts.Append (Msg, ") reaches ");
                  for K in 1 .. Reached (Md, C).Count loop
                     declare
                        Pc : constant Piece := Reached (Md, C).Pieces (K);
                     begin
                        if K > 1 then
                           Texts.Append (Msg, "; ");
                        end if;
                        if Pc.Zone in 1 .. NZ then
                           Append_Name (Msg, Z (Pc.Zone).Label);
                        else
                           Texts.Append (Msg, "what is not its own");
                        end if;
                        Texts.Append (Msg, " ");
                        Texts.Append_Range (Msg, Pc.First, Pc.Last);
                     end;
                  end loop;
                  if Reached (Md, C).More > 0 then
                     Texts.Append (Msg, " and ");
                     Texts.Append_Natural (Msg, Reached (Md, C).More);
                     Texts.Append (Msg, " more");
                  end if;
                  if C = E126 then
                     Texts.Append (Msg, ", which exposes APBBUS_CR, the clocks and resets of all peripherals "
                                   & "and the MPUs");
                  end if;
                  Add (F, C, S.Prod, Texts.Image (Path), Msg);
               end if;
            end loop;
         end loop;
      end Hart_Rules;

   begin
      Build_Zones;
      for H in Hart_Id loop
         if P.Harts (H) then
            declare
               G : Hart_Pmp renames S.Harts (H);
            begin
               if P.User and then G.Gen_Count > 0 and then G.Gen (G.Gen_Count).Index >= S.Target_Entries then
                  Partition_Path (Path, Pi, "");
                  Texts.Clear (Msg);
                  Texts.Append (Msg, "hart ");
                  Texts.Append (Msg, Digit (Natural (H)));
                  Texts.Append (Msg, " of ");
                  Append_Quoted (Msg, P.Label);
                  Texts.Append (Msg, " needs ");
                  Texts.Append_Natural (Msg, G.Gen_Count);
                  Texts.Append (Msg, " unlocked entries after the ");
                  Texts.Append_Natural (Msg, G.Gen (1).Index);
                  Texts.Append (Msg, " of the XML (to index ");
                  Texts.Append_Natural (Msg, G.Gen (G.Gen_Count).Index);
                  Texts.Append (Msg, "); the target has ");
                  Texts.Append_Natural (Msg, S.Target_Entries);
                  Add (F, E129, S.Prod, Texts.Image (Path), Msg);
               end if;
            end;
            Hart_Rules (H);
         end if;
      end loop;
   end Partition_Rules;

   ---------------------------------------------------------------------------------------------------
   --  The way masks of the L2

   --  The mask of master <Label>, 0 if the input has none.
   function Mask_Of (S : System; Label : String) return U64 is
   begin
      for K in 1 .. S.Mask_Count loop
         if Named (S.Masks (K).Master, Label) then
            return S.Masks (K).Mask;
         end if;
      end loop;
      return 0;
   end Mask_Of;

   --  The data and instruction cache masters of hart <H>.
   function Data_Master (H : Hart_Id) return String is
     (case H is
         when 0 => "E51_DCACHE", when 1 => "U54_1_DCACHE", when 2 => "U54_2_DCACHE", when 3 => "U54_3_DCACHE",
         when 4 => "U54_4_DCACHE");
   function Instruction_Master (H : Hart_Id) return String is
     (case H is
         when 0 => "E51_ICACHE", when 1 => "U54_1_ICACHE", when 2 => "U54_2_ICACHE", when 3 => "U54_3_ICACHE",
         when 4 => "U54_4_ICACHE");

   --  The partition that has hart <H>, 0 for none.
   function Partition_Of (S : System; H : Hart_Id) return Partition_Count is
   begin
      for P in 1 .. S.Partition_Count loop
         if S.Partitions (P).Harts (H) then
            return P;
         end if;
      end loop;
      return 0;
   end Partition_Of;

   procedure Append_Ways (T : in out Texts.Text; Ways : U64) is
      First : Boolean := True;
   begin
      Texts.Append (T, "[");
      for W in 0 .. 15 loop
         if (Ways and Eval.Pow2 (W)) /= 0 then
            if not First then
               Texts.Append (T, ", ");
            end if;
            First := False;
            Texts.Append_Natural (T, W);
         end if;
      end loop;
      Texts.Append (T, "]");
   end Append_Ways;

   procedure Way_Masks (S : System; F : in out List) is
      Ways    : constant := 16;
      Scratch : U64 := 0;
      Cache   : U64 := 0;
      Msg     : Message_Text;
      Path    : Path_Text;
   begin
      if S.Way_Enable >= Ways or else S.Scratchpad_Ways > S.Way_Enable then
         Texts.Clear (Msg);
         Texts.Append (Msg, "WAY_ENABLE ");
         Texts.Append_Hex (Msg, S.Way_Enable);
         Texts.Append (Msg, " and NUM_SCRATCH_PAD_WAYS ");
         Texts.Append_Hex (Msg, S.Scratchpad_Ways);
         Texts.Append (Msg, " leave no cache way of 16");
         Add (F, E072, S.Prod, "mss_memory_map/cache/WAY_ENABLE", Msg);
         return;      --  the masks are not checked without a split
      end if;
      --  cache ways 0 .. WAY_ENABLE - NUM_SCRATCH_PAD_WAYS, then the scratchpad ways up to WAY_ENABLE
      for W in 0 .. Ways - 1 loop
         if U64 (W) > S.Way_Enable - S.Scratchpad_Ways and then U64 (W) <= S.Way_Enable then
            Scratch := Scratch + Eval.Pow2 (W);
         elsif U64 (W) <= S.Way_Enable - S.Scratchpad_Ways then
            Cache := Cache + Eval.Pow2 (W);
         end if;
         pragma Loop_Invariant (Scratch < Eval.Pow2 (W + 1) and then Cache < Eval.Pow2 (W + 1));
      end loop;
      for K in 1 .. S.Mask_Count loop
         Texts.Clear (Path);
         Texts.Append (Path, "mss_memory_map/cache/WAY_MASK_");
         Append_Name (Path, S.Masks (K).Master);
         if (S.Masks (K).Mask and Scratch) /= 0 then
            Texts.Clear (Msg);
            Texts.Append_Hex (Msg, S.Masks (K).Mask);
            Texts.Append (Msg, " includes scratchpad ways (");
            Texts.Append_Hex (Msg, S.Masks (K).Mask and Scratch);
            Texts.Append (Msg, ")");
            Add (F, E073, S.Prod, Texts.Image (Path), Msg);
         end if;
         if (S.Masks (K).Mask and Cache) = 0 then
            Texts.Clear (Msg);
            Texts.Append_Hex (Msg, S.Masks (K).Mask);
            Texts.Append (Msg, " has no cache way");
            Add (F, E085, S.Prod, Texts.Image (Path), Msg);
         end if;
      end loop;

      --  l2.cache_partitioning: the cache ways of each hart it names, and no cache way shared by the harts
      --  of two partitions
      if S.Partitioned = [Hart_Id => False] then
         return;
      end if;
      for H in Hart_Id loop
         if S.Partitioned (H) then
            for Data in reverse Boolean loop
               declare
                  Label : constant String := (if Data then Data_Master (H) else Instruction_Master (H));
                  Have  : constant U64 := Mask_Of (S, Label) and Cache;
               begin
                  if Have /= U64 (S.Partition_Ways (H)) then
                     Texts.Clear (Path);
                     Texts.Append (Path, "mss_memory_map/cache/WAY_MASK_");
                     Texts.Append (Path, Label);
                     Texts.Clear (Msg);
                     Texts.Append (Msg, "cache ways ");
                     Append_Ways (Msg, Have);
                     Texts.Append (Msg, "; l2.cache_partitioning gives hart ");
                     Texts.Append (Msg, Digit (Natural (H)));
                     Texts.Append (Msg, " ");
                     Append_Ways (Msg, U64 (S.Partition_Ways (H)));
                     Add (F, E146, S.Prod, Texts.Image (Path), Msg);
                  end if;
               end;
            end loop;
         end if;
      end loop;
      for A in Hart_Id loop
         for B in Hart_Id loop
            if A < B and then Partition_Of (S, A) /= 0 and then Partition_Of (S, B) /= 0
              and then Partition_Of (S, A) /= Partition_Of (S, B)
            then
               declare
                  Shared : constant U64 :=
                    (Mask_Of (S, Data_Master (A)) or Mask_Of (S, Instruction_Master (A)))
                    and (Mask_Of (S, Data_Master (B)) or Mask_Of (S, Instruction_Master (B))) and Cache;
               begin
                  if Shared /= 0 then
                     Texts.Clear (Msg);
                     Texts.Append (Msg, "hart ");
                     Texts.Append (Msg, Digit (Natural (A)));
                     Texts.Append (Msg, " and hart ");
                     Texts.Append (Msg, Digit (Natural (B)));
                     Texts.Append (Msg, " of different partitions share the cache ways ");
                     Append_Ways (Msg, Shared);
                     Add (F, E147, S.Prod, "l2.cache_partitioning", Msg);
                  end if;
               end;
            end if;
         end loop;
      end loop;
   end Way_Masks;

   procedure Check (S : Model.System; F : in out Findings.List) is
      Nonzero : Boolean := False;
      Msg     : Message_Text;
   begin
      Way_Masks (S, F);
      Mpu.Check (S, F);
      for H in Hart_Id loop
         Layout (S, H, F);
         if (for some I in Entry_Index => S.Harts (H).Cfg (I) /= 0 or else S.Harts (H).Addr (I) /= 0) then
            Nonzero := True;
         end if;
      end loop;
      if not S.Pmp_Enabled and then Nonzero then
         Texts.Clear (Msg);
         Texts.Append (Msg, "PMP is 0, but the PMP sections set entries");
         Add (F, E104, S.Prod, "mss_memory_map/apb_split/MEM_CONFIGS_ENABLED.PMP", Msg);
      end if;
      for Pi in 1 .. S.Partition_Count loop
         Partition_Rules (S, Pi, F);
      end loop;
   end Check;

end Pmp_Check.Rules;
