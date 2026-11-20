--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The isolation of U mode from M mode by the PMP of the hart that runs the
--  image, with locked entries, as an AMP partition that runs its application
--  in U mode and its kernel in M mode would set it up. The memory is the
--  four pages of pmp_pages of pmp_probe/pmp_try.S and the code pages of
--  pmp_try.S (pmp_user_page) and pmp_isolation.S (pmp_csr_page):
--
--    entry 0  pmp_user_page   R X  locked   the code of the U-mode access
--    entry 1  pmp_csr_page    R X  locked   U-mode code that touches pmpcfg0
--    entry 2  P0              R W  locked   the data of the application
--    P1                       no entry      the data of the kernel
--
--  Single accesses in M and U mode through pmp_try give 0 or the mcause of
--  the fault. What is checked: U mode reaches its data and nothing else, the
--  kernel's page included (where no entry matches, U mode is denied and M
--  mode is not); U mode cannot read or write a PMP CSR (illegal
--  instruction, mcause 2); the locked entries bind M mode as well, with the
--  rights U mode has (a locked entry has the same rights in both modes, so
--  M mode cannot write the code page and cannot execute the data); M mode
--  cannot change the locked entries (writes are ignored); M mode can open
--  the kernel's page to U mode with an entry that is not locked, and close
--  it again; a locked entry without rights over the kernel's page then locks
--  M mode out of it as well, until reset.
--
--  The test needs four entries and a granule of at most 4 KiB. It reports
--  pmp_isolation_test_e51, pmp_isolation_test_u54 (hart 1) or
--  pmp_isolation_test_u54h<n> (harts 2 to 4).
--
--  @verifies HW-005

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with System.Storage_Elements;
with Bare_Console; use Bare_Console;
with Pmp_Csr;      use Pmp_Csr;
with Test_Report;

procedure Pmp_Isolation_Test is

   function Try (Op, Addr, User, Value : U64) return U64
     with Import, Convention => C, External_Name => "pmp_try";

   Pages : U64
     with Import, Convention => C, External_Name => "pmp_pages";
   User_Page : U64
     with Import, Convention => C, External_Name => "pmp_user_page";
   Csr_Page : U64
     with Import, Convention => C, External_Name => "pmp_csr_page";
   Csr_Page_Read : U64
     with Import, Convention => C, External_Name => "pmp_csr_page_read";

   function To_U64 (A : System.Address) return U64 is
     (U64 (System.Storage_Elements.To_Integer (A)));

   Load  : constant U64 := 0;
   Store : constant U64 := 1;
   Exec  : constant U64 := 2;

   Ok          : constant U64 := 0;
   Fetch_Fault : constant U64 := 1;
   Illegal     : constant U64 := 2;
   Load_Fault  : constant U64 := 5;
   Store_Fault : constant U64 := 7;

   Page : constant U64 := 4096;
   Data : constant U64 := 8;   --  the word that loads and stores use

   App    : constant U64 := To_U64 (Pages'Address);         --  P0
   Kernel : constant U64 := App + Page;                     --  P1
   UP     : constant U64 := To_U64 (User_Page'Address);
   CP     : constant U64 := To_U64 (Csr_Page'Address);
   CP_Rd  : constant U64 := To_U64 (Csr_Page_Read'Address);

   procedure Expect (What : String; Op, Addr : U64; User : Boolean;
                     Want : U64);

   procedure Expect (What : String; Op, Addr : U64; User : Boolean;
                     Want : U64) is
      Got : constant U64 := Try (Op, Addr, (if User then 1 else 0), 0);
   begin
      Test_Report.Check (Got = Want, What);
      if Got /= Want then
         Test_Report.Info ("mcause (0: no trap)", Got);
         Test_Report.Info ("expected", Want);
      end if;
   end Expect;

   Locked_Bits : constant U64 := 16#8080_8080_8080_8080#;
   N, G        : U64;
   Cfg, Addr2  : U64;
begin
   case Hart_Id is
      when 0 => Test_Report.Start ("pmp_isolation_test_e51");
      when 2 => Test_Report.Start ("pmp_isolation_test_u54h2");
      when 3 => Test_Report.Start ("pmp_isolation_test_u54h3");
      when 4 => Test_Report.Start ("pmp_isolation_test_u54h4");
      when others => Test_Report.Start ("pmp_isolation_test_u54");
   end case;
   Test_Report.Info ("hart", Hart_Id);
   Test_Report.Check
     (((Read_Cfg (0) or Read_Cfg (2)) and Locked_Bits) = 0,
      "no PMP entry is locked when the test starts");
   if ((Read_Cfg (0) or Read_Cfg (2)) and Locked_Bits) /= 0 then
      Test_Report.Finish;
   end if;

   N := Count (Mask);
   G := Granularity;
   Test_Report.Info ("pmp entries", N);
   Test_Report.Info ("pmp granularity G", G);
   Test_Report.Check (N >= 4, "the hart has the four entries the test needs");
   Test_Report.Check (G <= 10, "the granule is at most 4 KiB");
   if N < 4 or else G > 10 then
      Test_Report.Finish;
   end if;

   --  The partition: three locked entries, the kernel's page has none.
   Clear_All;
   Set (0, NAPOT or R or X or L, Napot_Addr (UP, Page));
   Set (1, NAPOT or R or X or L, Napot_Addr (CP, Page));
   Set (2, NAPOT or R or W or L, Napot_Addr (App, Page));

   --  U mode: its data, and nothing else.
   Expect ("U: load from the application's page", Load, App + Data, True, Ok);
   Expect ("U: store to the application's page",
           Store, App + Data, True, Ok);
   Expect ("U: load from the kernel's page faults (5)",
           Load, Kernel + Data, True, Load_Fault);
   Expect ("U: store to the kernel's page faults (7)",
           Store, Kernel + Data, True, Store_Fault);
   Expect ("U: execute in the kernel's page faults (1)",
           Exec, Kernel, True, Fetch_Fault);
   Expect ("U: store to the locked code page R X faults (7)",
           Store, UP, True, Store_Fault);
   Expect ("U: execute in the application's page RW faults (1)",
           Exec, App, True, Fetch_Fault);
   Expect ("U: write pmpcfg0 is an illegal instruction (2)",
           Exec, CP, True, Illegal);
   Expect ("U: read pmpcfg0 is an illegal instruction (2)",
           Exec, CP_Rd, True, Illegal);

   --  M mode: not subject to what no entry matches, bound by the locked
   --  entries with the rights U mode has.
   Expect ("M: load from the kernel's page", Load, Kernel + Data, False, Ok);
   Expect ("M: store to the kernel's page", Store, Kernel + Data, False, Ok);
   Expect ("M: execute in the kernel's page", Exec, Kernel, False, Ok);
   Expect ("M: load from the application's page",
           Load, App + Data, False, Ok);
   Expect ("M: store to the application's page",
           Store, App + Data, False, Ok);
   Expect ("M: store to the locked code page R X faults (7)",
           Store, CP, False, Store_Fault);
   Expect ("M: execute in the locked data page RW faults (1)",
           Exec, App, False, Fetch_Fault);

   --  M mode cannot change what is locked.
   Cfg := Read_Cfg (0);
   Addr2 := Read_Addr (2);
   Write_Cfg (0, 0);
   Test_Report.Check
     (Byte (Read_Cfg (0), 0, 0) = Byte (Cfg, 0, 0)
        and then Byte (Read_Cfg (0), 0, 1) = Byte (Cfg, 0, 1)
        and then Byte (Read_Cfg (0), 0, 2) = Byte (Cfg, 0, 2),
      "M: the configuration bytes of the locked entries ignore a write");
   Write_Addr (2, 0);
   Test_Report.Check (Read_Addr (2) = Addr2,
                      "M: pmpaddr2 of a locked entry ignores a write");
   Expect ("U: load from the application's page after M tried to clear it",
           Load, App + Data, True, Ok);
   Expect ("U: load from the kernel's page after M tried to clear it (5)",
           Load, Kernel + Data, True, Load_Fault);

   --  M mode can open the kernel's page to U mode with an entry that is not
   --  locked, and close it again.
   Set (3, NAPOT or R or W, Napot_Addr (Kernel, Page));
   Expect ("U: load from the kernel's page with an open entry",
           Load, Kernel + Data, True, Ok);
   Expect ("U: store to the kernel's page with an open entry",
           Store, Kernel + Data, True, Ok);
   Set_Cfg (3, OFF);
   Expect ("U: load from the kernel's page, entry closed again (5)",
           Load, Kernel + Data, True, Load_Fault);

   --  A locked entry without rights locks M mode out as well.
   Set (3, NAPOT or L, Napot_Addr (Kernel, Page));
   Expect ("M: load from a locked page without rights faults (5)",
           Load, Kernel + Data, False, Load_Fault);
   Expect ("M: store to a locked page without rights faults (7)",
           Store, Kernel + Data, False, Store_Fault);
   Expect ("U: load from a locked page without rights faults (5)",
           Load, Kernel + Data, True, Load_Fault);
   Expect ("M: the application's page is still there",
           Load, App + Data, False, Ok);

   Test_Report.Finish;
end Pmp_Isolation_Test;
