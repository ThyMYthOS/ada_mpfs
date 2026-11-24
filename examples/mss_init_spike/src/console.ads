--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What the image reports with: the text goes into the log (Log) and the
--  console sink is kicked (Sink, which sends by interrupt once it is open).
--  While the sink is closed this only fills the log.

with Interfaces;

package Console is

   procedure Put (Text : String);
   procedure Put_Line (Text : String);

   --  "0x" and exactly Width (1 .. 16) hexadecimal digits.
   procedure Put_Hex (Value : Interfaces.Unsigned_64; Width : Positive)
     with Pre => Width <= 16;

   --  Decimal, without leading zeros.
   procedure Put_Dec (Value : Interfaces.Unsigned_64);

end Console;
