--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The MPU of the DMA masters, decoded and checked independently of the generator (MSS TRM
--  DS60001702S §3.4, Microchip's mss_mpu.h:84-94).
--
--  Decoding: bits 35:0 of an entry are address bits 37:2, as pmpaddr of a PMP entry, with bits 8:0
--  hardwired to 1; bits 63:56 are a configuration byte laid out as one of the PMP: bit 7 L, bits 4:3
--  the address mode, bits 2, 1, 0 X, W, R. The MPU supports only off and NAPOT ("TOR and NAT settings
--  are equivalent to off"), so an entry is the NAPOT region of the PMP decoding within 36 bits (at
--  least 4 KiB, all ones the whole 2 ** 38 bytes) or nothing. A master has the entries of MSS TRM
--  Table 3-40 (Model.Mpu_Entries); the SCB bypasses its MPU. What a master reaches is the union of the
--  regions of its NAPOT entries with a right, whatever their order.
--
--  The rules, with the codes and paths of the generator (path mss_memory_map/mpu_<master>...):
--    GEN-E140  an entry with the address mode TOR or NA4 (register path)
--    GEN-E141  a NAPOT entry with a clear bit among address bits 8:0 (register path)
--    GEN-E142  an entry in use (configuration byte not 0) beyond the entries of its master
--              (register path)
--    GEN-E143  a master owned by a partition reaches a byte that no window of its owner holds
--    GEN-E144  a master without an owner reaches a byte
--    GEN-E145  an entry grants a right over the whole address space
--  GEN-E143 to GEN-E145 once per master (section path), not for the SCB.
--
--  @req GEN-019

with Pmp_Check.Eval;
with Pmp_Check.Findings;
with Pmp_Check.Model; use Pmp_Check.Model;

package Pmp_Check.Mpu
  with SPARK_Mode
is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;

   Addr_Bits : constant := 36;                   --  the PMP field: address bits 37:2
   Hardwired : constant := 16#1FF#;              --  bits 8:0 of the PMP field

   --  The bytes an entry can name: 2 ** 38.
   function Mpu_Space return Address is (Eval.Space (Addr_Bits));

   function Field (V : U64) return U64 is (V mod 2 ** Addr_Bits)
     with Post => Field'Result < 2 ** Addr_Bits;
   function Cfg (V : U64) return U8 is (U8 (V / 2 ** 56));

   --  The region of a NAPOT entry whose PMP field is <Fld> with bits 8:0 set: with t trailing ones the
   --  2 ** (t + 3) bytes at the field with those bits cleared, times 4; all ones the whole space.
   procedure Napot_Region (Fld : U64; First, Last : out Address)
     with Pre  => Fld < 2 ** Addr_Bits,
          Post => First <= Last and then Last < Mpu_Space;

   --  The table of the entries of master <M> within its hardware entries: a NAPOT entry is active, with
   --  the region of its PMP field with bits 8:0 set; every other entry is not.
   function Table_Of (S : System; M : Master_Id) return Eval.Table
     with Post => Eval.Valid (Table_Of'Result, Mpu_Space)
                  and then (for all I in Entry_Index =>
                              (if Table_Of'Result (I).Active then Natural (I) < Mpu_Entries (M)));

   function Owns (W : Window; P : Partition_Index) return Boolean is
     (W.Owners (1) = P or else (W.Owner_Count = 2 and then W.Owners (2) = P));

   --  Whether a window of partition <P> holds <A>.
   function Owner_Holds (S : System; P : Partition_Index; A : Address) return Boolean is
     (for some W in 1 .. S.Window_Count => Owns (S.Windows (W), P) and then Holds (S.Windows (W).Where, A));

   --  The first byte of [Lo, Hi] that no window of <P> holds: Found False if there is none.
   procedure First_Outside (S : System; P : Partition_Index; Lo, Hi : Address; Found : out Boolean;
                            A : out Address)
     with Pre  => Lo <= Hi and then Hi < Max_Address,
          Post => (if Found then A in Lo .. Hi and then not Owner_Holds (S, P, A)
                                 and then (for all X in Lo .. A - 1 => Owner_Holds (S, P, X))
                   else (for all X in Lo .. Hi => Owner_Holds (S, P, X)));

   procedure Check (S : System; F : in out Findings.List);

end Pmp_Check.Mpu;
