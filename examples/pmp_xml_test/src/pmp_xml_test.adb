--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The PMP of the hart that runs the image holds what the MSS Configurator
--  XML sets for it. The values of the XML are the table Pmp_Xml, generated
--  from the XML (config/gen/mpfs_gen pmp). The test
--
--    1. reads pmpcfg0, pmpcfg2 and pmpaddr0 .. 15 before anything else and
--       prints them, one "at start hart <n>" line each (what power-on,
--       reset or a boot stage before it leaves; reported, not checked: on
--       the Icicle Kit they are not zero after a power cycle);
--    2. if no entry is locked: counts the entries, measures the width of
--       pmpaddr (all ones written to pmpaddr0 and read back, WARL) and the
--       granularity G, then writes the values of the XML as Microchip's
--       pmp_configure() does (pmpcfg0 and pmpcfg2 0, pmpaddr0 .. 15, pmpcfg0,
--       pmpcfg2); if an entry is locked, a boot stage has configured the PMP
--       already and the test writes nothing (and the width is not measured);
--    3. reads every CSR back and compares it with the value of the XML as the
--       hart must return it (the WARL rules of Pmp_Csr.Legal_Addr and
--       Legal_Cfg, pmpaddr compared in the bits the hart implements, at most
--       bits 53:0; zero for an entry the hart does not have);
--    4. checks that the XML uses no entry the hart does not have.
--
--  With the XML of the Icicle Kit a U54 ends with entry 0 locked (NAPOT over
--  the whole address space, RWX): only a reset undoes it. It reports
--  pmp_xml_test_e51, pmp_xml_test_u54 (hart 1) or pmp_xml_test_u54h<n>
--  (harts 2 to 4).
--
--  @verifies GEN-010, HW-003

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;
with Pmp_Csr;      use Pmp_Csr;
with Pmp_Xml;
with Test_Report;

procedure Pmp_Xml_Test is

   --  An info line with a value in hex; Entry_Name adds the index of an
   --  entry (no string concatenation: there is no memcpy to link).
   procedure Show (What : String; Value : U64; Entry_Name : U64 := 16);

   procedure Show (What : String; Value : U64; Entry_Name : U64 := 16) is
   begin
      Put ("  info: ");
      Put (What);
      if Entry_Name < 16 then
         Put_Dec (Entry_Name);
      end if;
      Put (" = ");
      Put_Hex (Value, 16);
      Put_Line ("");
   end Show;

   procedure Compare (What : String; Found, Want : U64);

   procedure Compare (What : String; Found, Want : U64) is
   begin
      Test_Report.Check (Found = Want, What);
      if Found /= Want then
         Show ("found", Found);
         Show ("expected", Want);
      end if;
   end Compare;

   Locked_Bits : constant U64 := 16#8080_8080_8080_8080#;

   Id     : constant U64 := Hart_Id;
   Xml    : constant Pmp_Xml.Hart_Pmp := Pmp_Xml.Pmp (Pmp_Xml.Hart_Index (Id));
   Locked : Boolean;

   --  The values of the XML in the types of Pmp_Csr.
   Xml_Cfg0 : constant U64 := U64 (Xml.Cfg0);
   Xml_Cfg2 : constant U64 := U64 (Xml.Cfg2);
   function Xml_Addr (I : Index) return U64 is
     (U64 (Xml.Addr (Pmp_Xml.Entry_Index (I))));

   --  The CSRs as found at the start, read before anything is written.
   Start_Cfg0 : constant U64 := Read_Cfg (0);
   Start_Cfg2 : constant U64 := Read_Cfg (2);
   Start_Addr : array (Index) of U64;

   --  One line per CSR as found at the start, with the hart in each, so
   --  that the logs of several harts can be searched for "at start".
   procedure Show_Start (What : String; Value : U64; Entry_Name : U64 := 16);

   procedure Show_Start (What : String; Value : U64; Entry_Name : U64 := 16)
   is
   begin
      Put ("  info: at start hart ");
      Put_Dec (Id);
      Put (" ");
      Put (What);
      if Entry_Name < 16 then
         Put_Dec (Entry_Name);
      end if;
      Put (" = ");
      Put_Hex (Value, 16);
      Put_Line ("");
   end Show_Start;

   N      : U64 := 16;
   G      : U64 := 0;
   Impl   : U64 := Addr_Mask;
   Want0, Want2, Cfg : U64;
   Fits   : Boolean := True;
begin
   for I in Index loop
      Start_Addr (I) := Read_Addr (I);
   end loop;

   case Id is
      when 0 => Test_Report.Start ("pmp_xml_test_e51");
      when 2 => Test_Report.Start ("pmp_xml_test_u54h2");
      when 3 => Test_Report.Start ("pmp_xml_test_u54h3");
      when 4 => Test_Report.Start ("pmp_xml_test_u54h4");
      when others => Test_Report.Start ("pmp_xml_test_u54");
   end case;
   Test_Report.Info ("hart", Id);

   --  1. What the hart has when the image starts.
   Show_Start ("pmpcfg0", Start_Cfg0);
   Show_Start ("pmpcfg2", Start_Cfg2);
   for I in Index loop
      Show_Start ("pmpaddr", Start_Addr (I), U64 (I));
   end loop;
   Locked := ((Start_Cfg0 or Start_Cfg2) and Locked_Bits) /= 0;
   Put ("  info: xml = ");
   Put_Line (Pmp_Xml.Xml);

   --  2. Apply the XML unless a boot stage has done so (and locked it).
   if Locked then
      Put_Line ("  info: an entry is locked at start: the PMP is compared "
                & "as it is, nothing is written, the width of pmpaddr is "
                & "not measured (bits 53:0 compared)");
   else
      N := Count (Mask);
      Impl := Ones (0);
      Show ("pmpaddr0 after writing all ones", Impl);
      Test_Report.Info ("pmpaddr width", Width (Impl));
      Impl := Implemented (Impl);
      Show ("pmpaddr bits compared", Impl);
      G := Granularity;
      Write_Cfg (0, 0);
      Write_Cfg (2, 0);
      for I in Index loop
         Write_Addr (I, Xml_Addr (I));
      end loop;
      Write_Cfg (0, Xml_Cfg0);
      Write_Cfg (2, Xml_Cfg2);
   end if;
   Test_Report.Info ("pmp entries", N);
   Test_Report.Info ("pmp granularity G", G);

   --  3. Read back and compare.
   Want0 := 0;
   Want2 := 0;
   for I in Index loop
      Cfg := Byte (Xml_Cfg0, Xml_Cfg2, I);
      Test_Report.Info ("entry", U64 (I));
      if U64 (I) < N then
         Compare ("pmpaddr holds the value of the XML (implemented bits)",
                  Read_Addr (I) and Impl,
                  Legal_Addr (Xml_Addr (I), Cfg, G) and Impl);
         if I < 8 then
            Want0 := Want0 or Legal_Cfg (Cfg) * 2 ** (8 * Natural (I));
         else
            Want2 := Want2 or Legal_Cfg (Cfg) * 2 ** (8 * Natural (I - 8));
         end if;
      else
         Compare ("pmpaddr of an entry the hart does not have reads zero",
                  Read_Addr (I) and Addr_Mask, 0);
         Fits := Fits and then Cfg = 0 and then Xml_Addr (I) = 0;
      end if;
   end loop;
   Compare ("pmpcfg0 holds the value of the XML", Read_Cfg (0), Want0);
   Compare ("pmpcfg2 holds the value of the XML", Read_Cfg (2), Want2);

   --  4. The XML must not need more entries than the hart has.
   Test_Report.Check (Fits, "the XML sets no entry beyond those of the hart");

   Test_Report.Finish;
end Pmp_Xml_Test;
