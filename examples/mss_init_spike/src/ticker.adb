--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

pragma Suppress (All_Checks);

with Fabric;
with Mss_Init;
with Uart;

package body Ticker is

   use type Interfaces.Unsigned_64;

   Port : constant Uart.Port := Uart.MMUART0;

   --  A byte takes 43 us at 230400 baud: 50 ms is a port that is stuck
   Byte_Budget_Microseconds : constant := 50_000;

   Is_Open : Boolean := False;
   Is_Dead : Boolean := False;
   Count   : Natural := 0;

   Digit : constant String := "0123456789abcdef";

   procedure Write (Item : Character);
   procedure Write (Text : String);
   procedure Write_Hex (Value : Interfaces.Unsigned_64; Width : Positive);
   procedure Write_Dec (Value : Natural);

   procedure Write (Item : Character) is
      Start : constant Interfaces.Unsigned_64 := Mss_Init.Cycles;
      Span  : constant Interfaces.Unsigned_64 :=
        Byte_Budget_Microseconds * Mss_Init.Cycles_Per_Microsecond;
   begin
      if Is_Dead or else not Is_Open then
         return;
      end if;
      while not Uart.Tx_Ready (Port) loop
         if Mss_Init.Cycles - Start >= Span then
            Is_Dead := True;
            return;
         end if;
      end loop;
      Uart.Write (Port, Item);
      Count := Count + 1;
   end Write;

   procedure Write (Text : String) is
   begin
      for C of Text loop
         Write (C);
      end loop;
   end Write;

   procedure Write_Hex (Value : Interfaces.Unsigned_64; Width : Positive) is
   begin
      Write ("0x");
      for I in reverse 0 .. Width - 1 loop
         Write (Digit (Natural (Interfaces.Shift_Right (Value, 4 * I) mod 16)
                       + 1));
      end loop;
   end Write_Hex;

   procedure Write_Dec (Value : Natural) is
      Pow : Natural := 1;
   begin
      while Value / Pow >= 10 loop
         Pow := Pow * 10;
      end loop;
      while Pow > 0 loop
         Write (Digit (Value / Pow mod 10 + 1));
         Pow := Pow / 10;
      end loop;
   end Write_Dec;

   procedure Open is
   begin
      Uart.Initialize (Port, Uart.Tick_Baud);
      Is_Open := True;
   end Open;

   procedure Put_Tick
     (Count   : Natural;
      MTIME   : Interfaces.Unsigned_64;
      Control : Interfaces.Unsigned_32;
      Locked  : Boolean)
   is
      Per_Line : constant := 2;
      On_Line  : Natural := 0;
      Text     : Fabric.Description;
      Last     : Natural;
   begin
      Write ("tick ");
      Write_Dec (Count);
      Write (": mtime ");
      Write_Hex (MTIME, 8);
      Write (" PLL_CTRL ");
      Write_Hex (Interfaces.Unsigned_64 (Control), 8);
      Write (" LOCK ");
      Write (if Locked then '1' else '0');
      Write (" fabric:");
      for Item in Fabric.Index loop
         if Fabric.Occurred (Item) then
            if On_Line = Per_Line then
               Write (ASCII.CR);
               Write (ASCII.LF);
               Write ("tick ");
               Write_Dec (Count);
               Write (": fabric:");
               On_Line := 0;
            end if;
            Write (if On_Line = 0 then " " else ", ");
            Fabric.Describe (Item, Text, Last);
            Write (Text (1 .. Last));
            On_Line := On_Line + 1;
         end if;
      end loop;
      if On_Line = 0 then
         Write (" none");
      end if;
      Write (ASCII.CR);
      Write (ASCII.LF);
   end Put_Tick;

   function Written return Natural is (Ticker.Count);
   function Dead return Boolean is (Is_Dead);

end Ticker;
