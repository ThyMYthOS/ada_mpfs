--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The check input read into the model.

package body Pmp_Check.Load
  with SPARK_Mode
is
   use type Interfaces.Unsigned_64;
   use type Json.Node_Id;
   use type Json.Kind;
   use Model;

   procedure Read (Doc : Json.Document; Src : String; Root : Json.Node_Id; S : out Model.System;
                   Ok : out Boolean; Err : in out Texts.Text)
   is
      procedure Fail (What : String; Key : String) is
      begin
         if Ok then
            Ok := False;
            Texts.Append (Err, What);
            Texts.Append (Err, ": ");
            Texts.Append (Err, Key);
         end if;
      end Fail;

      function Get (Obj : Json.Node_Id; Key : String) return Json.Node_Id is
        (Json.Member (Doc, Src, Obj, Key));

      procedure Need (Obj : Json.Node_Id; Key : String; K : Json.Kind; N : out Json.Node_Id) is
      begin
         N := Get (Obj, Key);
         if Json.Kind_Of (Doc, N) /= K or else N = 0 then
            Fail ("missing or not " & (case K is
                                         when Json.J_Array  => "an array",
                                         when Json.J_Object => "an object",
                                         when Json.J_Number => "a number",
                                         when Json.J_String => "a string",
                                         when others        => "a value"), Key);
            N := 0;
         end if;
      end Need;

      procedure Get_U64 (Obj : Json.Node_Id; Key : String; V : out U64) is
         N : Json.Node_Id;
      begin
         Need (Obj, Key, Json.J_Number, N);
         V := (if N /= 0 then Doc.Nodes (N).Num else 0);
      end Get_U64;

      procedure Get_Small (Obj : Json.Node_Id; Key : String; Max : Natural; V : out Natural)
        with Post => V <= Max;

      procedure Get_Small (Obj : Json.Node_Id; Key : String; Max : Natural; V : out Natural) is
         Raw : U64;
      begin
         Get_U64 (Obj, Key, Raw);
         if Raw > U64 (Max) then
            Fail ("out of range", Key);
            V := 0;
         else
            V := Natural (Raw);
         end if;
      end Get_Small;

      procedure Get_Bool (Obj : Json.Node_Id; Key : String; V : out Boolean) is
         N : constant Json.Node_Id := Get (Obj, Key);
      begin
         V := Json.Kind_Of (Doc, N) = Json.J_True;
         if N = 0 or else Json.Kind_Of (Doc, N) not in Json.J_True | Json.J_False then
            Fail ("missing or not true or false", Key);
         end if;
      end Get_Bool;

      --  A string, or null for the empty name if <Nullable>.
      procedure Get_Name (Obj : Json.Node_Id; Key : String; V : out Name; Nullable : Boolean := False) is
         N : constant Json.Node_Id := Get (Obj, Key);
      begin
         V := (others => <>);
         if Nullable and then N /= 0 and then Json.Kind_Of (Doc, N) = Json.J_Null then
            return;
         end if;
         if N = 0 or else Json.Kind_Of (Doc, N) /= Json.J_String then
            Fail ("missing or not a string", Key);
            return;
         end if;
         declare
            T : constant String := Json.Text_Of (Doc, Src, N);
         begin
            if T'Length > Name_Capacity then
               Fail ("longer than 64 characters", Key);
               return;
            end if;
            V.Len := T'Length;
            V.Data (1 .. T'Length) := T;
         end;
      end Get_Name;

      --  <Key> as a number up to 4, or null (Has False) if <Nullable>.
      procedure Get_Hart (Obj : Json.Node_Id; Key : String; Has : out Boolean; H : out Hart_Id;
                          Nullable : Boolean) is
         N : constant Json.Node_Id := Get (Obj, Key);
         V : Natural;
      begin
         if Nullable and then N /= 0 and then Json.Kind_Of (Doc, N) = Json.J_Null then
            Has := False;
            H := 0;
            return;
         end if;
         Get_Small (Obj, Key, 4, V);
         Has := Ok;
         H := (if Ok and then V <= 4 then Hart_Id (V) else 0);
      end Get_Hart;

      --  base and length of <Obj> as the bytes [base, base + length - 1].
      procedure Get_Span (Obj : Json.Node_Id; V : out Span) is
         Base, Length : U64;
      begin
         V := (others => <>);
         Get_U64 (Obj, "base", Base);
         Get_U64 (Obj, "length", Length);
         if not Ok then
            return;
         end if;
         if Length = 0 or else Base >= Max_Address or else Length > Max_Address - Base then
            Fail ("a range outside the 2 ** 56 bytes of a PMP entry", "base, length");
            return;
         end if;
         V := (First => Address (Base), Last => Address (Base + Length - 1));
      end Get_Span;

      --  The array of hart numbers <Key> as a set.
      procedure Get_Harts (Obj : Json.Node_Id; Key : String; V : out Hart_Set) is
         Arr : Json.Node_Id;
         Cur : Json.Node_Id;
      begin
         V := [others => False];
         Need (Obj, Key, Json.J_Array, Arr);
         Cur := Json.First_Child (Doc, Arr);
         for Step in 1 .. Json.Max_Nodes loop
            exit when Cur = 0 or else not Ok;
            if Json.Kind_Of (Doc, Cur) /= Json.J_Number or else Doc.Nodes (Cur).Num > 4 then
               Fail ("not a hart (0 to 4)", Key);
            else
               V (Hart_Id (Doc.Nodes (Cur).Num)) := True;
            end if;
            Cur := Json.Next_Sibling (Doc, Cur);
         end loop;
      end Get_Harts;

      --  A block: name, block, base, length and, for a critical block, hart.
      procedure Get_Block (Obj : Json.Node_Id; With_Hart : Boolean; B : out Block) is
         Has  : Boolean := False;
         Hart : Hart_Id := 0;
         Label, Svd : Name;
         Where : Span;
      begin
         Get_Name (Obj, "name", Label);
         Get_Name (Obj, "block", Svd);
         Get_Span (Obj, Where);
         if With_Hart then
            Get_Hart (Obj, "hart", Has, Hart, Nullable => True);
         end if;
         B := (Label => Label, Svd => Svd, Where => Where, Has_Hart => Has, Hart => Hart);
      end Get_Block;

      procedure Get_Blocks (Obj : Json.Node_Id; Key : String; With_Hart : Boolean; V : out Block_Array;
                            Count : out Block_Count) is
         Arr : Json.Node_Id;
         Cur : Json.Node_Id;
      begin
         V := [others => (others => <>)];
         Count := 0;
         Need (Obj, Key, Json.J_Array, Arr);
         Cur := Json.First_Child (Doc, Arr);
         for Step in 1 .. Json.Max_Nodes loop
            exit when Cur = 0 or else not Ok;
            if Count = Max_Blocks then
               Fail ("more than 64 blocks", Key);
            else
               Count := Count + 1;
               Get_Block (Cur, With_Hart, V (Count));
            end if;
            Cur := Json.Next_Sibling (Doc, Cur);
         end loop;
      end Get_Blocks;

      procedure Get_Pmp (Obj : Json.Node_Id) is
         Arr, Cur, Values, Item, Gens : Json.Node_Id;
         Seen   : Hart_Set := [others => False];
         Has    : Boolean;
         H      : Hart_Id;
         Bits   : Natural;
         N      : Natural range 0 .. Hart_Entries;
         Target : Natural;
      begin
         Get_Bool (Obj, "enabled", S.Pmp_Enabled);
         Get_Small (Obj, "entries", Hart_Entries, Target);
         if Ok and then Target = 0 then
            Fail ("out of range", "entries");
         elsif Ok then
            S.Target_Entries := Target;
         end if;
         Need (Obj, "harts", Json.J_Array, Arr);
         Cur := Json.First_Child (Doc, Arr);
         for Step in 1 .. Json.Max_Nodes loop
            exit when Cur = 0 or else not Ok;
            Get_Hart (Cur, "hart", Has, H, Nullable => False);
            Get_Small (Cur, "pmpaddr_bits", Pmpaddr_Bits'Last, Bits);
            exit when not Ok or else not Has;
            if Seen (H) then
               Fail ("a hart twice", "pmp.harts");
               exit;
            end if;
            Seen (H) := True;
            if Bits = 0 then
               Fail ("out of range", "pmpaddr_bits");
               exit;
            end if;
            S.Harts (H).Bits := Bits;
            for Is_Cfg in reverse Boolean loop
               Need (Cur, (if Is_Cfg then "cfg" else "addr"), Json.J_Array, Values);
               Item := Json.First_Child (Doc, Values);
               N := 0;
               for Step2 in 1 .. Json.Max_Nodes loop
                  exit when Item = 0 or else not Ok;
                  if N = Hart_Entries or else Json.Kind_Of (Doc, Item) /= Json.J_Number
                    or else (Is_Cfg and then Doc.Nodes (Item).Num > 255)
                  then
                     Fail ("not 16 values of their range", "cfg, addr");
                  elsif Is_Cfg then
                     S.Harts (H).Cfg (Entry_Index (N)) := U8 (Doc.Nodes (Item).Num);
                     N := N + 1;
                  else
                     S.Harts (H).Addr (Entry_Index (N)) := Doc.Nodes (Item).Num;
                     N := N + 1;
                  end if;
                  Item := Json.Next_Sibling (Doc, Item);
               end loop;
               if Ok and then N /= Hart_Entries then
                  Fail ("not 16 values of their range", "cfg, addr");
               end if;
            end loop;
            Need (Cur, "generated", Json.J_Array, Gens);
            Item := Json.First_Child (Doc, Gens);
            for Step2 in 1 .. Json.Max_Nodes loop
               exit when Item = 0 or else not Ok;
               if S.Harts (H).Gen_Count = Max_Generated then
                  Fail ("more than 64 generated entries", "generated");
               else
                  declare
                     G     : Generated_Entry;
                     Index : Natural;
                     Cfg   : Natural;
                     Prior : constant Natural := S.Harts (H).Gen_Count;
                  begin
                     Get_Small (Item, "index", 255, Index);
                     Get_Small (Item, "cfg", 255, Cfg);
                     Get_U64 (Item, "addr", G.Addr);
                     G.Index := Index;
                     G.Cfg := U8 (Cfg);
                     if Ok and then Prior > 0 and then S.Harts (H).Gen (Prior).Index >= Index then
                        Fail ("generated entries not in index order", "generated");
                     end if;
                     S.Harts (H).Gen_Count := Prior + 1;
                     S.Harts (H).Gen (Prior + 1) := G;
                  end;
               end if;
               Item := Json.Next_Sibling (Doc, Item);
            end loop;
            Cur := Json.Next_Sibling (Doc, Cur);
         end loop;
         if Ok and then Seen /= [Hart_Id => True] then
            Fail ("not every hart 0 to 4", "pmp.harts");
         end if;
      end Get_Pmp;

      procedure Get_Partitions (Arr : Json.Node_Id) is
         Cur  : Json.Node_Id := Json.First_Child (Doc, Arr);
         Priv : Name;
      begin
         for Step in 1 .. Json.Max_Nodes loop
            exit when Cur = 0 or else not Ok;
            if S.Partition_Count = Max_Partitions then
               Fail ("more than 5", "partitions");
               exit;
            end if;
            declare
               P : Partition;
            begin
               Get_Name (Cur, "name", P.Label);
               Get_Harts (Cur, "harts", P.Harts);
               Get_Name (Cur, "priv", Priv);
               P.User := Named (Priv, "u");
               if Ok and then not P.User and then not Named (Priv, "m") then
                  Fail ("not m or u", "priv");
               end if;
               Get_Bool (Cur, "monitor", P.Monitor);
               Get_Blocks (Cur, "peripherals", False, P.Blocks, P.Block_Count);
               if Ok and then P.Harts = [Hart_Id => False] then
                  Fail ("a partition without harts", "harts");
               end if;
               for Other in 1 .. S.Partition_Count loop
                  if Ok and then Same (S.Partitions (Other).Label, P.Label) then
                     Fail ("two partitions of the same name", "partitions");
                  end if;
               end loop;
               S.Partition_Count := S.Partition_Count + 1;
               S.Partitions (S.Partition_Count) := P;
            end;
            Cur := Json.Next_Sibling (Doc, Cur);
         end loop;
      end Get_Partitions;

      function Partition_Named (N : Name) return Partition_Count is
      begin
         for I in 1 .. S.Partition_Count loop
            if Same (S.Partitions (I).Label, N) then
               return I;
            end if;
         end loop;
         return 0;
      end Partition_Named;

      procedure Get_Windows (Arr : Json.Node_Id) is
         Cur    : Json.Node_Id := Json.First_Child (Doc, Arr);
         Owners : Json.Node_Id;
         Owner  : Json.Node_Id;
         Kind   : Name;
         Who    : Name;
         Index  : Partition_Count;
      begin
         for Step in 1 .. Json.Max_Nodes loop
            exit when Cur = 0 or else not Ok;
            if S.Window_Count = Max_Windows then
               Fail ("more than 64", "windows");
               exit;
            end if;
            declare
               W : Window;
            begin
               Get_Name (Cur, "kind", Kind);
               if Named (Kind, "code+data") then
                  W.Kind := Code_Data;
               elsif Named (Kind, "code") then
                  W.Kind := Code;
               elsif Named (Kind, "data") then
                  W.Kind := Data;
               elsif Named (Kind, "fast_text") then
                  W.Kind := Fast_Text;
               elsif Named (Kind, "ipc") then
                  W.Kind := Ipc;
               else
                  Fail ("not a kind of window", "kind");
               end if;
               Get_Name (Cur, "memory", W.Memory);
               Get_Span (Cur, W.Where);
               Get_Name (Cur, "channel", W.Channel, Nullable => True);
               Need (Cur, "owners", Json.J_Array, Owners);
               Owner := Json.First_Child (Doc, Owners);
               W.Owner_Count := 1;
               for Step2 in 1 .. 3 loop
                  exit when Owner = 0 or else not Ok;
                  if Step2 = 3 or else Json.Kind_Of (Doc, Owner) /= Json.J_String then
                     Fail ("not one or two partitions", "owners");
                     exit;
                  end if;
                  declare
                     T : constant String := Json.Text_Of (Doc, Src, Owner);
                  begin
                     Who := (others => <>);
                     if T'Length <= Name_Capacity then
                        Who.Len := T'Length;
                        Who.Data (1 .. T'Length) := T;
                     end if;
                  end;
                  Index := Partition_Named (Who);
                  if Index = 0 then
                     Fail ("not a partition", "owners");
                     exit;
                  end if;
                  W.Owners (Step2) := Index;
                  W.Owner_Count := Step2;
                  Owner := Json.Next_Sibling (Doc, Owner);
               end loop;
               if Ok and then Json.First_Child (Doc, Owners) = 0 then
                  Fail ("not one or two partitions", "owners");
               end if;
               S.Window_Count := S.Window_Count + 1;
               S.Windows (S.Window_Count) := W;
            end;
            Cur := Json.Next_Sibling (Doc, Cur);
         end loop;
      end Get_Windows;

      procedure Get_Memories (Arr : Json.Node_Id) is
         Cur : Json.Node_Id := Json.First_Child (Doc, Arr);
      begin
         for Step in 1 .. Json.Max_Nodes loop
            exit when Cur = 0 or else not Ok;
            if S.Memory_Count = Max_Memories then
               Fail ("more than 32", "memories");
               exit;
            end if;
            declare
               M : Memory;
            begin
               Get_Name (Cur, "name", M.Label);
               Get_Span (Cur, M.Where);
               Get_Hart (Cur, "hart", M.Has_Hart, M.Hart, Nullable => True);
               Get_Bool (Cur, "itim", M.Itim);
               S.Memory_Count := S.Memory_Count + 1;
               S.Memories (S.Memory_Count) := M;
            end;
            Cur := Json.Next_Sibling (Doc, Cur);
         end loop;
      end Get_Memories;

      procedure Get_L2 (Obj : Json.Node_Id) is
         Arr : Json.Node_Id;
         Cur : Json.Node_Id;
      begin
         Get_U64 (Obj, "way_enable", S.Way_Enable);
         Get_U64 (Obj, "scratchpad_ways", S.Scratchpad_Ways);
         Need (Obj, "way_masks", Json.J_Array, Arr);
         Cur := Json.First_Child (Doc, Arr);
         for Step in 1 .. Json.Max_Nodes loop
            exit when Cur = 0 or else not Ok;
            if S.Mask_Count = Max_Masters then
               Fail ("more than 32", "way_masks");
               exit;
            end if;
            S.Mask_Count := S.Mask_Count + 1;
            Get_Name (Cur, "master", S.Masks (S.Mask_Count).Master);
            Get_U64 (Cur, "mask", S.Masks (S.Mask_Count).Mask);
            Cur := Json.Next_Sibling (Doc, Cur);
         end loop;
      end Get_L2;

      Version : U64;
      Profile : Name;
      Node    : Json.Node_Id;
      Buses   : Json.Node_Id;
   begin
      S := (others => <>);
      Ok := True;
      if Json.Kind_Of (Doc, Root) /= Json.J_Object or else Root = 0 then
         Fail ("not an object", "the document");
         return;
      end if;
      Get_U64 (Root, "version", Version);
      if Ok and then Version /= 1 then
         Fail ("not 1", "version");
      end if;
      Get_Name (Root, "security_profile", Profile);
      S.Prod := Named (Profile, "prod");
      if Ok and then not S.Prod and then not Named (Profile, "dev") then
         Fail ("not prod or dev", "security_profile");
      end if;
      Need (Root, "contexts", Json.J_Object, Node);
      Get_Harts (Node, "a_harts", S.A_Harts);
      Get_Harts (Node, "b_harts", S.B_Harts);
      Need (Root, "pmp", Json.J_Object, Node);
      if Ok then
         Get_Pmp (Node);
      end if;
      Need (Root, "partitions", Json.J_Array, Node);
      Get_Partitions (Node);
      Need (Root, "windows", Json.J_Array, Node);
      Get_Windows (Node);
      Need (Root, "memories", Json.J_Array, Node);
      Get_Memories (Node);
      Get_Blocks (Root, "critical", True, S.Critical, S.Critical_Count);
      Need (Root, "mtime", Json.J_Object, Node);
      Get_Span (Node, S.Mtime);
      Need (Root, "buses", Json.J_Object, Buses);
      Get_Blocks (Buses, "lo", False, S.Lo_Bus, S.Lo_Count);
      Get_Blocks (Buses, "hi", False, S.Hi_Bus, S.Hi_Count);
      Need (Root, "l2", Json.J_Object, Node);
      Get_L2 (Node);
   end Read;

end Pmp_Check.Load;
