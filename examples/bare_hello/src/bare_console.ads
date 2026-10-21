--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Polled output on MMUART0 without a runtime and without elaboration code.

pragma Restrictions (No_Elaboration_Code);

package Bare_Console is

   type U64 is mod 2 ** 64;

   --  Id of the executing hart (CSR mhartid).
   function Hart_Id return U64;

   procedure Put (Text : String);
   procedure Put_Line (Text : String);

   --  Hexadecimal, "0x" and exactly Width (1 .. 16) digits.
   procedure Put_Hex (Value : U64; Width : Positive)
     with Pre => Width <= 16;

   --  Decimal, without leading zeros.
   procedure Put_Dec (Value : U64);

end Bare_Console;
