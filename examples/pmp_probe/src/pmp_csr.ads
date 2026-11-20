--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The PMP CSRs of the hart that runs the image, for the PMP test programs
--  (pmp_xml_test, pmp_access_test): access by number (pmp_regs.S), the
--  encodings of the Privileged Spec v1.10 (3.6.1) and the number of entries
--  and the granularity, both measured through the WARL behaviour of pmpaddr.

pragma Restrictions (No_Elaboration_Code);

with Bare_Console; use Bare_Console;

package Pmp_Csr is

   type Index is range 0 .. 15;

   --  The configuration byte of an entry.
   R     : constant U64 := 16#01#;
   W     : constant U64 := 16#02#;
   X     : constant U64 := 16#04#;
   OFF   : constant U64 := 16#00#;
   TOR   : constant U64 := 16#08#;
   NA4   : constant U64 := 16#10#;
   NAPOT : constant U64 := 16#18#;
   Mode  : constant U64 := 16#18#;
   L     : constant U64 := 16#80#;

   --  The bits of pmpaddr that hold an address on RV64: address bits 55:2.
   --  Bits 63:54 are WIRI in v1.10 (what they read is to be ignored; QEMU
   --  10 returns what was written), so comparisons leave them out.
   Addr_Mask : constant U64 := 2 ** 54 - 1;

   function Read_Addr (I : Index) return U64;
   procedure Write_Addr (I : Index; Value : U64);

   --  Reg is 0 (pmpcfg0, entries 0 .. 7) or 2 (pmpcfg2, entries 8 .. 15).
   function Read_Cfg (Reg : U64) return U64;
   procedure Write_Cfg (Reg : U64; Value : U64);

   --  The configuration byte of entry I in the CSRs, and the CSRs with the
   --  byte of entry I replaced (the other entries' bytes kept).
   function Cfg_Of (I : Index) return U64;
   procedure Set_Cfg (I : Index; Cfg : U64);

   --  Entry I: pmpaddr first, then the configuration byte.
   procedure Set (I : Index; Cfg : U64; Addr : U64);

   --  Every entry OFF, every pmpaddr 0 (only where nothing is locked).
   procedure Clear_All;

   --  The byte of entry I of a pair of pmpcfg0 and pmpcfg2 values.
   function Byte (Cfg0, Cfg2 : U64; I : Index) return U64;

   --  pmpaddr of a NAPOT region of Size bytes (a power of two, at least 8)
   --  at Base (a multiple of Size), and of the address A for TOR and NA4.
   function Napot_Addr (Base, Size : U64) return U64;
   function Addr_Of (A : U64) return U64;

   --  Which pmpaddr hold what is written to them (pmp_mask.S of pmp_probe):
   --  bit n set if pmpaddrn exists. Needs entries that are not locked.
   function Mask return U64
     with Import, Convention => C, External_Name => "pmp_mask";

   --  The number of bits set in Mask.
   function Count (M : U64) return U64;

   --  G of the Privileged Spec: the granule is 2 ** (G + 2) bytes. Measured
   --  on entry 0 (left OFF and 0): in the modes OFF and TOR, pmpaddr bits
   --  G - 1 .. 0 read zero. Needs entry 0 not locked.
   function Granularity return U64;

   --  pmpaddr as the hart returns Value written to an entry in mode Cfg with
   --  the granularity G (Privileged Spec v1.11, 3.6.1, which spells out what
   --  v1.10 leaves to the implementation), bits 63:54 cleared; with NAPOT
   --  and G >= 2 bits G - 2 .. 0 read one, with OFF or TOR and G >= 1 bits
   --  G - 1 .. 0 read zero.
   function Legal_Addr (Value : U64; Cfg : U64; G : U64) return U64;

   --  The configuration byte as the hart returns it: bits 6:5 read zero.
   function Legal_Cfg (Cfg : U64) return U64 is (Cfg and 16#9F#);

   --  pmpaddr I as the hart returns all ones written to it (64 ones), with
   --  the entry OFF; pmpaddr I is 0 again afterwards. pmpaddr is WARL: the
   --  bits that read one are the ones the hart implements (on the Icicle Kit
   --  a U54 returned bits 35:0 for pmpaddr0; QEMU 10 returns all 64). Needs
   --  entry I not locked.
   function Ones (I : Index) return U64;

   --  The number of the highest bit set in V, plus one (0 for V = 0): the
   --  width of pmpaddr from the value of Ones.
   function Width (V : U64) return U64;

   --  The bits a comparison of pmpaddr can rely on: those below Width of
   --  the value of Ones, within Addr_Mask.
   function Implemented (Ones_Value : U64) return U64;

end Pmp_Csr;
