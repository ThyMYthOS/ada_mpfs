--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The MPU of the DMA masters, decoded and checked.

with Pmp_Check.Texts;

package body Pmp_Check.Mpu
  with SPARK_Mode
is
   use Findings;

   subtype Path_Text is Texts.Text (Findings.Path_Capacity);
   subtype Message_Text is Texts.Text (Findings.Message_Capacity);

   procedure Napot_Region (Fld : U64; First, Last : out Address) is
      Limit : constant U64 := Eval.Pow2 (Addr_Bits);
      Sp    : constant Address := Mpu_Space;
      V     : constant U64 := Fld or Hardwired;
      Ones  : Natural range 9 .. Addr_Bits - 1 := 9;   --  bits 8:0 are ones
      Base  : U64;
   begin
      pragma Assert (V < Limit);
      if V = Limit - 1 then
         First := 0;
         Last := Sp - 1;
         return;
      end if;
      while Ones < Addr_Bits - 1 and then (V and Eval.Pow2 (Ones)) /= 0 loop
         pragma Loop_Variant (Increases => Ones);
         Ones := Ones + 1;
      end loop;
      Base := V and not (Eval.Pow2 (Ones) - 1);    --  V with its trailing ones cleared
      pragma Assert (Base <= V);
      pragma Assert (Address (Base) * 4 <= Sp - 4);
      First := Address (Base) * 4;
      if First + Address (Eval.Pow2 (Ones + 3)) < Sp then
         Last := First + Address (Eval.Pow2 (Ones + 3)) - 1;
      else
         Last := Sp - 1;
      end if;
   end Napot_Region;

   function Table_Of (S : System; M : Master_Id) return Eval.Table is
      T : Eval.Table := [others => (others => <>)];
      E : Mpu_Entry;
      C : U8;
      D : Eval.Decoded;
   begin
      for K in 1 .. S.Mpus (M).Count loop
         E := S.Mpus (M).Entries (K);
         C := Cfg (E.Value);
         if E.Index < Mpu_Entries (M) and then E.Index <= 15 and then Eval.Mode_Of (C) = Eval.Napot then
            D := (Active => True, Locked => Eval.Has_L (C), R => C mod 2 = 1, W => C / 2 mod 2 = 1,
                  X => C / 4 mod 2 = 1, others => <>);
            Napot_Region (Field (E.Value), D.First, D.Last);
            T (Entry_Index (E.Index)) := D;
         end if;
         pragma Loop_Invariant (Eval.Valid (T, Mpu_Space));
         pragma Loop_Invariant (for all I in Entry_Index => (if T (I).Active then Natural (I) < Mpu_Entries (M)));
      end loop;
      return T;
   end Table_Of;

   procedure First_Outside (S : System; P : Partition_Index; Lo, Hi : Address; Found : out Boolean;
                            A : out Address)
   is
      Best  : Natural range 0 .. Max_Windows;
      Reach : Address;
   begin
      A := Lo;
      Found := False;
      loop
         pragma Loop_Invariant (A in Lo .. Hi and then not Found);
         pragma Loop_Invariant (for all X in Lo .. A - 1 => Owner_Holds (S, P, X));
         pragma Loop_Variant (Increases => A);
         --  the window of <P> that holds <A> and reaches farthest
         Best := 0;
         Reach := A;
         for W in 1 .. S.Window_Count loop
            if Owns (S.Windows (W), P) and then Holds (S.Windows (W).Where, A)
              and then (Best = 0 or else S.Windows (W).Where.Last > Reach)
            then
               Best := W;
               Reach := S.Windows (W).Where.Last;
            end if;
            pragma Loop_Invariant (Best <= W);
            pragma Loop_Invariant
              (if Best = 0 then
                 (for all V in 1 .. W => not (Owns (S.Windows (V), P) and then Holds (S.Windows (V).Where, A)))
               else Owns (S.Windows (Best), P) and then Holds (S.Windows (Best).Where, A)
                    and then Reach = S.Windows (Best).Where.Last);
         end loop;
         if Best = 0 then
            Found := True;
            return;
         end if;
         pragma Assert (Reach >= A);
         pragma Assert (for all X in A .. Reach => Holds (S.Windows (Best).Where, X));
         pragma Assert (for all X in A .. Reach => Owner_Holds (S, P, X));
         if Reach >= Hi then
            pragma Assert (for all X in Lo .. Hi => Owner_Holds (S, P, X));
            A := Lo;
            return;
         end if;
         A := Reach + 1;
      end loop;
   end First_Outside;

   --  One past the end of the piece from <A> on that no window of <P> holds, at most <Hi> + 1: the
   --  lowest first byte of a window of <P> above <A>.
   function Piece_End (S : System; P : Partition_Index; A, Hi : Address) return Address
     with Pre  => A <= Hi and then Hi < Max_Address,
          Post => A < Piece_End'Result and then Piece_End'Result <= Hi + 1
   is
      E : Address := Hi + 1;
   begin
      for W in 1 .. S.Window_Count loop
         if Owns (S.Windows (W), P) and then S.Windows (W).Where.First > A and then S.Windows (W).Where.First < E
         then
            E := S.Windows (W).Where.First;
         end if;
         pragma Loop_Invariant (A < E and then E <= Hi + 1);
      end loop;
      return E;
   end Piece_End;

   function Master_Name (M : Master_Id) return String is
     (case M is
         when Fic0 => "fic0", when Fic1 => "fic1", when Fic2 => "fic2", when Crypto => "crypto",
         when Gem0 => "gem0", when Gem1 => "gem1", when Usb => "usb", when Mmc => "mmc", when Scb => "scb",
         when Trace => "trace");

   function Upper (M : Master_Id) return String is
     (case M is
         when Fic0 => "FIC0", when Fic1 => "FIC1", when Fic2 => "FIC2", when Crypto => "CRYPTO",
         when Gem0 => "GEM0", when Gem1 => "GEM1", when Usb => "USB", when Mmc => "MMC", when Scb => "SCB",
         when Trace => "TRACE");

   procedure Section_Path (T : in out Texts.Text; M : Master_Id) is
   begin
      Texts.Clear (T);
      Texts.Append (T, "mss_memory_map/mpu_");
      Texts.Append (T, Master_Name (M));
   end Section_Path;

   procedure Register_Path (T : in out Texts.Text; M : Master_Id; Index : Natural) is
   begin
      Section_Path (T, M);
      Texts.Append (T, "/MPU_CFG_PMP");
      Texts.Append_Natural (T, Index);
   end Register_Path;

   procedure Check_Master (S : System; M : Master_Id; F : in out List) is
      Count : constant Positive := Mpu_Entries (M);
      Path  : Path_Text;
      Msg   : Message_Text;
      T     : Eval.Table;
      Reaches, Wide, Beyond : Boolean := False;
      Reached : Message_Text;      --  the entries that grant a right
      Wide_At : Message_Text;      --  those over the whole space
      Pieces  : Message_Text;      --  the pieces outside the windows of the owner
   begin
      --  the entries of the XML, one by one
      for K in 1 .. S.Mpus (M).Count loop
         declare
            E : constant Mpu_Entry := S.Mpus (M).Entries (K);
            C : constant U8 := Cfg (E.Value);
         begin
            Register_Path (Path, M, E.Index);
            Texts.Clear (Msg);
            Texts.Append (Msg, "entry ");
            Texts.Append_Natural (Msg, E.Index);
            Texts.Append (Msg, " of ");
            Texts.Append (Msg, Upper (M));
            if E.Index >= Count then
               if C /= 0 then
                  Texts.Append (Msg, " is in use (");
                  Texts.Append_Hex (Msg, U64 (C));
                  Texts.Append (Msg, "); ");
                  Texts.Append (Msg, Upper (M));
                  Texts.Append (Msg, " has ");
                  Texts.Append_Natural (Msg, Count);
                  Texts.Append (Msg, " entries");
                  Add (F, E142, S.Prod, Texts.Image (Path), Msg);
               end if;
            elsif Eval.Mode_Of (C) in Eval.Tor | Eval.Na4 then
               Texts.Append (Msg, (if Eval.Mode_Of (C) = Eval.Tor then " is TOR (" else " is NA4 ("));
               Texts.Append_Hex (Msg, U64 (C));
               Texts.Append (Msg, "), which the MPU takes as off");
               Add (F, E140, S.Prod, Texts.Image (Path), Msg);
            elsif Eval.Mode_Of (C) = Eval.Napot and then Field (E.Value) mod 512 /= Hardwired then
               Texts.Append (Msg, " has the PMP field ");
               Texts.Append_Hex (Msg, Field (E.Value));
               Texts.Append (Msg, "; the MPU sets bits 8:0");
               Add (F, E141, S.Prod, Texts.Image (Path), Msg);
            end if;
         end;
      end loop;
      if Mpu_Bypass (M) then
         return;
      end if;

      --  what the master reaches: the union of its NAPOT entries with a right
      T := Table_Of (S, M);
      for I in Entry_Index loop
         if T (I).Active and then (T (I).R or else T (I).W or else T (I).X) then
            if Reaches then
               Texts.Append (Reached, ", ");
            end if;
            Reaches := True;
            Texts.Append_Natural (Reached, Natural (I));
            if T (I).First = 0 and then T (I).Last = Mpu_Space - 1 then
               if Wide then
                  Texts.Append (Wide_At, ", ");
               end if;
               Wide := True;
               Texts.Append_Natural (Wide_At, Natural (I));
            end if;
            if S.Mpus (M).Has_Owner then
               declare
                  Found : Boolean;
                  A     : Address;
               begin
                  First_Outside (S, S.Mpus (M).Owner, T (I).First, T (I).Last, Found, A);
                  if Found then
                     if Beyond then
                        Texts.Append (Pieces, ", ");
                     end if;
                     Beyond := True;
                     Texts.Append_Range (Pieces, A, Piece_End (S, S.Mpus (M).Owner, A, T (I).Last) - 1);
                     Texts.Append (Pieces, " (entry ");
                     Texts.Append_Natural (Pieces, Natural (I));
                     Texts.Append (Pieces, ")");
                  end if;
               end;
            end if;
         end if;
      end loop;

      if Wide then
         Section_Path (Path, M);
         Texts.Clear (Msg);
         Texts.Append (Msg, Upper (M));
         Texts.Append (Msg, " reaches the whole address space through entries ");
         Texts.Append (Msg, Texts.Image (Wide_At));
         Add (F, E145, S.Prod, Texts.Image (Path), Msg);
      end if;
      if Reaches and then not S.Mpus (M).Has_Owner then
         Section_Path (Path, M);
         Texts.Clear (Msg);
         Texts.Append (Msg, Upper (M));
         Texts.Append (Msg, ", which no partition owns, reaches what entries ");
         Texts.Append (Msg, Texts.Image (Reached));
         Texts.Append (Msg, " grant");
         Add (F, E144, S.Prod, Texts.Image (Path), Msg);
      end if;
      if Beyond then
         Section_Path (Path, M);
         Texts.Clear (Msg);
         Texts.Append (Msg, Upper (M));
         Texts.Append (Msg, ", owned by '");
         Texts.Append (Msg, Image (S.Partitions (S.Mpus (M).Owner).Label));
         Texts.Append (Msg, "', reaches ");
         Texts.Append (Msg, Texts.Image (Pieces));
         Texts.Append (Msg, " outside the windows of its owner");
         Add (F, E143, S.Prod, Texts.Image (Path), Msg);
      end if;
   end Check_Master;

   procedure Check (S : System; F : in out Findings.List) is
   begin
      for M in Master_Id loop
         Check_Master (S, M, F);
      end loop;
   end Check;

end Pmp_Check.Mpu;
