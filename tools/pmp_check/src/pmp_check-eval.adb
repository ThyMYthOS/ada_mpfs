--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The PMP of a hart evaluated after the Privileged Spec v1.10, and the intervals in which it does not
--  change.

package body Pmp_Check.Eval
  with SPARK_Mode
is

   --  The entry of configuration byte <C> and pmpaddr <V>, with <Prev> the pmpaddr of the entry
   --  before it, both within <Bits> bits.
   function Decode_Entry (C : U8; V, Prev : U64; Bits : Pmpaddr_Bits) return Decoded
     with Pre  => V < Pow2 (Bits) and then Prev < Pow2 (Bits),
          Post => Decode_Entry'Result.Locked = Has_L (C)
                  and then (if Decode_Entry'Result.Active then
                              Decode_Entry'Result.First <= Decode_Entry'Result.Last
                              and then Decode_Entry'Result.Last < Space (Bits));

   function Decode_Entry (C : U8; V, Prev : U64; Bits : Pmpaddr_Bits) return Decoded is
      Limit : constant U64 := Pow2 (Bits);
      Sp    : constant Address := Space (Bits);
      E     : Decoded := (Locked => Has_L (C), R => C mod 2 = 1, W => C / 2 mod 2 = 1,
                          X => C / 4 mod 2 = 1, others => <>);
   begin
      case Mode_Of (C) is
         when Tor =>
            if V > Prev then
               pragma Assert (Address (Prev) + 1 <= Address (V));
               E.Active := True;
               E.First := Address (Prev) * 4;
               E.Last := Address (V) * 4 - 1;
               pragma Assert (E.First <= E.Last and then E.Last < Sp);
            end if;
         when Na4 =>
            E.Active := True;
            E.First := Address (V) * 4;
            E.Last := Address (V) * 4 + 3;
            pragma Assert (E.First <= E.Last and then E.Last < Sp);
         when Napot =>
            E.Active := True;
            if V = Limit - 1 then
               E.First := 0;
               E.Last := Sp - 1;
               pragma Assert (E.First <= E.Last and then E.Last < Sp);
            else
               declare
                  Ones : Natural range 0 .. Bits - 1 := 0;    --  the trailing ones of V
                  Base : U64;
               begin
                  while Ones < Bits - 1 and then (V and Pow2 (Ones)) /= 0 loop
                     pragma Loop_Variant (Increases => Ones);
                     Ones := Ones + 1;
                  end loop;
                  Base := V and not (Pow2 (Ones) - 1);    --  V with its trailing ones cleared
                  pragma Assert (Base <= V);
                  pragma Assert (Address (Base) * 4 <= Sp - 4);
                  E.First := Address (Base) * 4;
                  if E.First + Address (Pow2 (Ones + 3)) < Sp then
                     E.Last := E.First + Address (Pow2 (Ones + 3)) - 1;
                  else
                     E.Last := Sp - 1;
                  end if;
                  pragma Assert (E.First <= E.Last and then E.Last < Sp);
               end;
            end if;
         when others =>
            null;
      end case;
      pragma Assert (if E.Active then E.First <= E.Last and then E.Last < Sp);
      return E;
   end Decode_Entry;

   function Decode (Cfg : Cfg_Array; Addr : Addr_Array; Bits : Pmpaddr_Bits) return Table is
      Limit : constant U64 := Pow2 (Bits);          --  one past the largest pmpaddr within <Bits>
      T     : Table := [others => (others => <>)];
      Prev  : U64 := 0;                             --  pmpaddr of the entry before, within <Bits>
      V     : U64;
   begin
      for I in Entry_Index loop
         V := Addr (I) and (Limit - 1);
         pragma Assert (V <= Limit - 1);
         T (I) := Decode_Entry (Cfg (I), V, Prev, Bits);
         Prev := V;
         pragma Loop_Invariant (Prev < Limit);
         pragma Loop_Invariant
           (for all J in Entry_Index'First .. I =>
              (if T (J).Active then T (J).First <= T (J).Last and then T (J).Last < Space (Bits)));
         pragma Loop_Invariant
           (for all J in Entry_Index'First .. I => T (J).Locked = Has_L (Cfg (J)));
      end loop;
      return T;
   end Decode;

   function Lowest (T : Table; A : Address) return Match is
   begin
      for I in Entry_Index loop
         if Matches (T (I), A) then
            return Match (I);
         end if;
         pragma Loop_Invariant (for all J in Entry_Index'First .. I => not Matches (T (J), A));
      end loop;
      return No_Match;
   end Lowest;

   function First_Zone (Z : Zone_Array; N : Zone_Count; A : Address) return Zone_Hit is
   begin
      for K in 1 .. N loop
         if In_Zone (Z (K), A) then
            return K;
         end if;
         pragma Loop_Invariant (for all J in 1 .. K => not In_Zone (Z (J), A));
      end loop;
      return 0;
   end First_Zone;

   function Next_Bound (T : Table; Z : Zone_Array; N : Zone_Count; Lo, Limit : Address) return Address is
      R : Address := Limit;
   begin
      for I in Entry_Index loop
         if T (I).Active then
            if T (I).First > Lo and then T (I).First < R then
               R := T (I).First;
            end if;
            if T (I).Last + 1 > Lo and then T (I).Last + 1 < R then
               R := T (I).Last + 1;
            end if;
         end if;
         pragma Loop_Invariant (Lo < R and then R <= Limit);
         pragma Loop_Invariant
           (for all J in Entry_Index'First .. I =>
              (if T (J).Active then
                 (T (J).First <= Lo or else T (J).First >= R)
                 and then (T (J).Last + 1 <= Lo or else T (J).Last + 1 >= R)));
      end loop;
      for K in 1 .. N loop
         if Z (K).Where.First > Lo and then Z (K).Where.First < R then
            R := Z (K).Where.First;
         end if;
         if Z (K).Where.Last + 1 > Lo and then Z (K).Where.Last + 1 < R then
            R := Z (K).Where.Last + 1;
         end if;
         pragma Loop_Invariant (Lo < R and then R <= Limit);
         pragma Loop_Invariant
           (for all J in Entry_Index =>
              (if T (J).Active then
                 (T (J).First <= Lo or else T (J).First >= R)
                 and then (T (J).Last + 1 <= Lo or else T (J).Last + 1 >= R)));
         pragma Loop_Invariant
           (for all J in 1 .. K =>
              (Z (J).Where.First <= Lo or else Z (J).Where.First >= R)
              and then (Z (J).Where.Last + 1 <= Lo or else Z (J).Where.Last + 1 >= R));
      end loop;
      return R;
   end Next_Bound;

   procedure Lemma_Uniform (T : Table; Z : Zone_Array; N : Zone_Count; Lo, Hi : Address) is
   begin
      pragma Assert
        (for all A in Lo .. Hi => (for all I in Entry_Index => Matches (T (I), A) = Matches (T (I), Lo)));
      pragma Assert
        (for all A in Lo .. Hi => (for all K in 1 .. N => In_Zone (Z (K), A) = In_Zone (Z (K), Lo)));
   end Lemma_Uniform;

end Pmp_Check.Eval;
