--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Texts of a bounded length for the messages of the checker: what does not fit is cut off.

package Pmp_Check.Texts
  with SPARK_Mode
is
   type Text (Capacity : Positive) is record
      Data : String (1 .. Capacity) := [others => ' '];
      Len  : Natural := 0;
   end record;

   --  The characters of T (at most its capacity).
   function Image (T : Text) return String is (T.Data (1 .. Natural'Min (T.Len, T.Capacity)));

   procedure Clear (T : in out Text)
     with Post => T.Len = 0;

   procedure Append (T : in out Text; S : String);

   --  0x and the lower-case hex digits of V, as Python's format "#x" writes them.
   procedure Append_Hex (T : in out Text; V : U64);

   procedure Append_Address (T : in out Text; A : Address);

   --  The decimal digits of N.
   procedure Append_Natural (T : in out Text; N : Natural);

   --  [0x<first>, 0x<last>]
   procedure Append_Range (T : in out Text; First, Last : Address);

end Pmp_Check.Texts;
