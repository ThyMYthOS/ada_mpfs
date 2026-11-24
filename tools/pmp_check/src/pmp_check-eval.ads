--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The PMP of a hart evaluated after the Privileged Spec v1.10 (the MPFS has no Smepmp), and the
--  intervals of the address space in which the evaluation does not change.
--
--  Decoding: an entry is OFF, TOR, NA4 or NAPOT (bits 4:3 of its configuration byte), with R, W, X
--  (bits 0 to 2) and L (bit 7); pmpaddr holds address bits 55:2, of which a hart implements its low
--  <Bits> (WARL), and the entry is taken within those bits. TOR matches [pmpaddr(i-1) * 4,
--  pmpaddr(i) * 4) (pmpaddr(-1) is 0) and nothing if that is empty; NA4 the four bytes at
--  pmpaddr * 4; NAPOT with t trailing ones the 2 ** (t + 3) bytes at the pmpaddr with those bits
--  cleared, times 4, and all of it the whole space.
--
--  Semantics: the matching entry with the lowest index decides an access. For U mode it grants its
--  R, W and X; for M mode only if L is set, an entry without L lets M through. If no entry matches, M
--  is allowed and U denied.
--
--  Intervals: the first and one past the last byte of every entry and of every zone of the target cut
--  the space of a hart into intervals. Next_Bound gives the end of the interval that starts at an
--  address, and Lemma_Uniform states what the checker relies on: within an interval the matching
--  entry and the zone, and so the evaluation of every mode and access, are those of its first byte.
--
--  @req GEN-015

with Interfaces;
with Pmp_Check.Model; use Pmp_Check.Model;

package Pmp_Check.Eval
  with SPARK_Mode
is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;

   subtype Exponent is Natural range 0 .. 56;

   --  2 ** N, spelt out (the provers do not reason well about a power with a variable exponent).
   function Pow2 (N : Exponent) return U64 is
     (case N is
         when 0 => 2 ** 0,
         when 1 => 2 ** 1,
         when 2 => 2 ** 2,
         when 3 => 2 ** 3,
         when 4 => 2 ** 4,
         when 5 => 2 ** 5,
         when 6 => 2 ** 6,
         when 7 => 2 ** 7,
         when 8 => 2 ** 8,
         when 9 => 2 ** 9,
         when 10 => 2 ** 10,
         when 11 => 2 ** 11,
         when 12 => 2 ** 12,
         when 13 => 2 ** 13,
         when 14 => 2 ** 14,
         when 15 => 2 ** 15,
         when 16 => 2 ** 16,
         when 17 => 2 ** 17,
         when 18 => 2 ** 18,
         when 19 => 2 ** 19,
         when 20 => 2 ** 20,
         when 21 => 2 ** 21,
         when 22 => 2 ** 22,
         when 23 => 2 ** 23,
         when 24 => 2 ** 24,
         when 25 => 2 ** 25,
         when 26 => 2 ** 26,
         when 27 => 2 ** 27,
         when 28 => 2 ** 28,
         when 29 => 2 ** 29,
         when 30 => 2 ** 30,
         when 31 => 2 ** 31,
         when 32 => 2 ** 32,
         when 33 => 2 ** 33,
         when 34 => 2 ** 34,
         when 35 => 2 ** 35,
         when 36 => 2 ** 36,
         when 37 => 2 ** 37,
         when 38 => 2 ** 38,
         when 39 => 2 ** 39,
         when 40 => 2 ** 40,
         when 41 => 2 ** 41,
         when 42 => 2 ** 42,
         when 43 => 2 ** 43,
         when 44 => 2 ** 44,
         when 45 => 2 ** 45,
         when 46 => 2 ** 46,
         when 47 => 2 ** 47,
         when 48 => 2 ** 48,
         when 49 => 2 ** 49,
         when 50 => 2 ** 50,
         when 51 => 2 ** 51,
         when 52 => 2 ** 52,
         when 53 => 2 ** 53,
         when 54 => 2 ** 54,
         when 55 => 2 ** 55,
         when 56 => 2 ** 56)
     with Post => Pow2'Result >= 1 and then Pow2'Result <= 2 ** 56
                  and then (if N <= 54 then Pow2'Result <= 2 ** 54);

   --  The bytes a pmpaddr of <Bits> implemented bits addresses: 2 ** (Bits + 2).
   function Space (Bits : Pmpaddr_Bits) return Address is (Address (Pow2 (Bits)) * 4);

   type Decoded is record
      Active : Boolean := False;    --  matches some byte
      Locked : Boolean := False;    --  L, whether active or not
      R, W, X : Boolean := False;
      First  : Address := 0;
      Last   : Address := 0;
   end record;

   type Table is array (Entry_Index) of Decoded;

   function Valid (T : Table; Limit : Address) return Boolean is
     (for all I in Entry_Index =>
        (if T (I).Active then T (I).First <= T (I).Last and then T (I).Last < Limit));

   function Mode_Of (Cfg : U8) return Natural is (Natural (Cfg / 8 mod 4))
     with Post => Mode_Of'Result <= 3;

   Off   : constant := 0;
   Tor   : constant := 1;
   Na4   : constant := 2;
   Napot : constant := 3;

   function Has_L (Cfg : U8) return Boolean is (Cfg >= 16#80#);

   --  The entries of a table of CSRs, within <Bits> bits of pmpaddr.
   function Decode (Cfg : Cfg_Array; Addr : Addr_Array; Bits : Pmpaddr_Bits) return Table
     with Post => Valid (Decode'Result, Space (Bits))
                  and then (for all I in Entry_Index => Decode'Result (I).Locked = Has_L (Cfg (I)));

   --  The match of an entry: No_Match or the index of the entry.
   type Match is range -1 .. 15;
   No_Match : constant Match := -1;

   function Matches (E : Decoded; A : Address) return Boolean is
     (E.Active and then E.First <= A and then A <= E.Last);

   --  The entry with the lowest index that matches <A>.
   function Lowest (T : Table; A : Address) return Match
     with Post =>
       (if Lowest'Result = No_Match then (for all I in Entry_Index => not Matches (T (I), A))
        else Matches (T (Entry_Index (Lowest'Result)), A)
             and then (for all I in Entry_Index =>
                         (if I < Entry_Index (Lowest'Result) then not Matches (T (I), A))));

   type Mode is (U, M);
   type Access_Kind is (Read, Write, Execute);
   type Rights is array (Access_Kind) of Boolean;
   None_Granted : constant Rights := [others => False];
   All_Granted  : constant Rights := [others => True];

   function Rights_Of (E : Decoded) return Rights is ([Read => E.R, Write => E.W, Execute => E.X]);

   --  What mode <Md> may do at <A>.
   function Decide (T : Table; A : Address; Md : Mode) return Rights is
     (if Lowest (T, A) = No_Match then (if Md = M then All_Granted else None_Granted)
      elsif Md = U or else T (Entry_Index (Lowest (T, A))).Locked
      then Rights_Of (T (Entry_Index (Lowest (T, A))))
      else All_Granted);

   --  Whether the entry that decides <A> is locked.
   function By_Lock (T : Table; A : Address) return Boolean is
     (Lowest (T, A) /= No_Match and then T (Entry_Index (Lowest (T, A))).Locked);

   --  The zones of the target that a partition is checked against, in their order of priority: the
   --  first zone that holds an address names it.
   type Zone_Kind is (Own, Foreign, Peer, Grant, Critical, Bus);
   type Zone is record
      Where : Span;
      Kind  : Zone_Kind := Own;
      Label : Name;
   end record;
   Max_Zones : constant := 512;
   subtype Zone_Count is Natural range 0 .. Max_Zones;
   subtype Zone_Hit is Natural range 0 .. Max_Zones;    --  0: no zone
   type Zone_Array is array (1 .. Max_Zones) of Zone;

   function In_Zone (Z : Zone; A : Address) return Boolean is
     (Z.Where.First <= A and then A <= Z.Where.Last);

   function First_Zone (Z : Zone_Array; N : Zone_Count; A : Address) return Zone_Hit
     with Post =>
       First_Zone'Result <= N
       and then (if First_Zone'Result = 0 then (for all K in 1 .. N => not In_Zone (Z (K), A))
                 else In_Zone (Z (First_Zone'Result), A)
                      and then (for all K in 1 .. First_Zone'Result - 1 => not In_Zone (Z (K), A)));

   --  The evaluation of an address: the entry that decides it and the zone it is in. The rights of
   --  every mode and access and the finding that follows from them are functions of this pair.
   type Point is record
      Hit_Entry : Match;
      Hit_Zone  : Zone_Hit;
   end record;

   function Evaluate (T : Table; Z : Zone_Array; N : Zone_Count; A : Address) return Point is
     ((Hit_Entry => Lowest (T, A), Hit_Zone => First_Zone (Z, N, A)));

   --  No bound of an entry or a zone lies inside [Lo, Hi]: each starts at or before Lo or after Hi,
   --  and ends before Lo or at or after Hi.
   function No_Bound_Inside (T : Table; Z : Zone_Array; N : Zone_Count; Lo, Hi : Address) return Boolean is
     ((for all I in Entry_Index =>
         (if T (I).Active then
            (T (I).First <= Lo or else T (I).First > Hi)
            and then (T (I).Last >= Hi or else T (I).Last < Lo)))
      and then
      (for all K in 1 .. N =>
         (Z (K).Where.First <= Lo or else Z (K).Where.First > Hi)
         and then (Z (K).Where.Last >= Hi or else Z (K).Where.Last < Lo)));

   --  One past the end of the interval that starts at <Lo>: the lowest bound above <Lo>, at most
   --  <Limit>, the end of the space.
   function Next_Bound (T : Table; Z : Zone_Array; N : Zone_Count; Lo, Limit : Address) return Address
     with Pre  => Lo < Limit,
          Post => Lo < Next_Bound'Result and then Next_Bound'Result <= Limit
                  and then No_Bound_Inside (T, Z, N, Lo, Next_Bound'Result - 1);

   --  The property the check over intervals rests on: the evaluation of an interval without a bound
   --  inside is the same for all its addresses.
   procedure Lemma_Uniform (T : Table; Z : Zone_Array; N : Zone_Count; Lo, Hi : Address)
     with Ghost,
          Global => null,
          Pre    => Lo <= Hi and then No_Bound_Inside (T, Z, N, Lo, Hi),
          Post   => (for all A in Lo .. Hi => Evaluate (T, Z, N, A) = Evaluate (T, Z, N, Lo));

end Pmp_Check.Eval;
