--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Body of Pmp_Csr: the CSR accessors are pmp_regs.S.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

package body Pmp_Csr is

   function Pmp_Read_Addr (I : U64) return U64
     with Import, Convention => C, External_Name => "pmp_read_addr";
   procedure Pmp_Write_Addr (I : U64; Value : U64)
     with Import, Convention => C, External_Name => "pmp_write_addr";
   function Pmp_Read_Cfg (Reg : U64) return U64
     with Import, Convention => C, External_Name => "pmp_read_cfg";
   procedure Pmp_Write_Cfg (Reg : U64; Value : U64)
     with Import, Convention => C, External_Name => "pmp_write_cfg";

   function Read_Addr (I : Index) return U64 is (Pmp_Read_Addr (U64 (I)));

   procedure Write_Addr (I : Index; Value : U64) is
   begin
      Pmp_Write_Addr (U64 (I), Value);
   end Write_Addr;

   function Read_Cfg (Reg : U64) return U64 is (Pmp_Read_Cfg (Reg));

   procedure Write_Cfg (Reg : U64; Value : U64) is
   begin
      Pmp_Write_Cfg (Reg, Value);
   end Write_Cfg;

   function Shift (I : Index) return U64 is (2 ** (8 * Natural (I mod 8)));

   function Reg_Of (I : Index) return U64 is (if I < 8 then 0 else 2);

   function Byte (Cfg0, Cfg2 : U64; I : Index) return U64 is
     ((if I < 8 then Cfg0 else Cfg2) / Shift (I) mod 256);

   function Cfg_Of (I : Index) return U64 is
     (Read_Cfg (Reg_Of (I)) / Shift (I) mod 256);

   procedure Set_Cfg (I : Index; Cfg : U64) is
      Old : constant U64 := Read_Cfg (Reg_Of (I));
   begin
      Write_Cfg (Reg_Of (I),
                 (Old and not (255 * Shift (I))) or (Cfg mod 256) * Shift (I));
   end Set_Cfg;

   procedure Set (I : Index; Cfg : U64; Addr : U64) is
   begin
      Write_Addr (I, Addr);
      Set_Cfg (I, Cfg);
   end Set;

   procedure Clear_All is
   begin
      Write_Cfg (0, 0);
      Write_Cfg (2, 0);
      for I in Index loop
         Write_Addr (I, 0);
      end loop;
   end Clear_All;

   function Napot_Addr (Base, Size : U64) return U64 is
     ((Base + Size / 2 - 1) / 4);

   function Addr_Of (A : U64) return U64 is (A / 4);

   function Count (M : U64) return U64 is
      Rest : U64 := M;
      N    : U64 := 0;
   begin
      while Rest /= 0 loop
         N := N + Rest mod 2;
         Rest := Rest / 2;
      end loop;
      return N;
   end Count;

   function Granularity return U64 is
      Value : U64;
      G     : U64 := 0;
   begin
      Set_Cfg (0, OFF);
      Write_Addr (0, Addr_Mask);
      Value := Read_Addr (0);
      Write_Addr (0, 0);
      while G < 54 and then Value mod 2 = 0 loop
         G := G + 1;
         Value := Value / 2;
      end loop;
      return G;
   end Granularity;

   function Ones (I : Index) return U64 is
      Value : U64;
   begin
      Set_Cfg (I, OFF);
      Write_Addr (I, not 0);
      Value := Read_Addr (I);
      Write_Addr (I, 0);
      return Value;
   end Ones;

   function Width (V : U64) return U64 is
      Rest : U64 := V;
      N    : U64 := 0;
   begin
      while Rest /= 0 loop
         N := N + 1;
         Rest := Rest / 2;
      end loop;
      return N;
   end Width;

   function Implemented (Ones_Value : U64) return U64 is
      W : constant U64 := Width (Ones_Value);
   begin
      if W >= 54 then
         return Addr_Mask;
      end if;
      return 2 ** Natural (W) - 1;
   end Implemented;

   function Legal_Addr (Value : U64; Cfg : U64; G : U64) return U64 is
      V : U64 := Value and Addr_Mask;
   begin
      if (Cfg and Mode) = NAPOT and then G >= 2 then
         V := V or (2 ** Natural (G - 1) - 1);
      elsif ((Cfg and Mode) = OFF or else (Cfg and Mode) = TOR)
        and then G >= 1
      then
         V := V and not (2 ** Natural (G) - 1);
      end if;
      return V;
   end Legal_Addr;

end Pmp_Csr;
