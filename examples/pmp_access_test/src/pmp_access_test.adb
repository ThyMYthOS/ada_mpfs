--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The access semantics of the PMP of the hart that runs the image, after the
--  Privileged Spec v1.10 (3.6.1). The test programs entries of its own over
--  four pages of 4 KiB (pmp_pages of pmp_probe/pmp_try.S, P0 .. P3) and
--  makes single accesses in M and U mode through pmp_try, which reports the
--  mcause of the
--  trap (1 instruction, 5 load, 7 store access fault) or 0. Three groups,
--  each from all entries OFF:
--
--    A  U mode and NAPOT: R, RW and X regions allow just that; where no entry
--       matches, U is denied; entries without L do not apply to M mode.
--    B  TOR, NA4 and the order: a TOR range over two pages; an NA4 word; the
--       entry with the lowest index that matches decides, also against a
--       NAPOT entry that allows everything in the last entry of the hart
--       (7 under QEMU, 15 with 16 entries), which is used where no other
--       entry matches.
--    C  L (last: it holds until reset): locked entries apply to M mode; a
--       write to a locked pmpaddr or configuration byte is ignored, and so is
--       one to pmpaddr(i - 1) of a locked TOR entry i; unlocked entries still
--       take writes.
--
--  The test needs six entries and a granule of at most 4 KiB; with G > 0 the
--  NA4 cases are left out (NA4 is not selectable then). It reports
--  pmp_access_test_e51, pmp_access_test_u54 (hart 1) or
--  pmp_access_test_u54h<n> (harts 2 to 4).
--
--  @verifies HW-003

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with System.Storage_Elements;
with Bare_Console; use Bare_Console;
with Pmp_Csr;      use Pmp_Csr;
with Test_Report;

procedure Pmp_Access_Test is

   function Try (Op, Addr, User, Value : U64) return U64
     with Import, Convention => C, External_Name => "pmp_try";

   Pages : U64
     with Import, Convention => C, External_Name => "pmp_pages";
   User_Page : U64
     with Import, Convention => C, External_Name => "pmp_user_page";
   Mtval : U64
     with Import, Volatile, Convention => C, External_Name => "pmp_try_mtval";

   function To_U64 (A : System.Address) return U64 is
     (U64 (System.Storage_Elements.To_Integer (A)));

   Load  : constant U64 := 0;
   Store : constant U64 := 1;
   Exec  : constant U64 := 2;

   Ok          : constant U64 := 0;
   Fetch_Fault : constant U64 := 1;
   Load_Fault  : constant U64 := 5;
   Store_Fault : constant U64 := 7;

   Page : constant U64 := 4096;
   Data : constant U64 := 8;   --  the word that loads and stores use

   P0 : constant U64 := To_U64 (Pages'Address);
   P1 : constant U64 := P0 + Page;
   P2 : constant U64 := P0 + 2 * Page;
   P3 : constant U64 := P0 + 3 * Page;
   UP : constant U64 := To_U64 (User_Page'Address);

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

   procedure Expect_Mtval (Addr : U64; What : String);

   procedure Expect_Mtval (Addr : U64; What : String) is
   begin
      Test_Report.Check (Mtval = Addr, What);
   end Expect_Mtval;

   --  Entry 0: the page of try_op, which U mode must execute.
   procedure User_Code;

   procedure User_Code is
   begin
      Set (0, NAPOT or R or X, Napot_Addr (UP, Page));
   end User_Code;

   Locked_Bits : constant U64 := 16#8080_8080_8080_8080#;
   N, G        : U64;
   A1, A2, A3  : U64;
   Cfg         : U64;
   Last        : Index;
begin
   case Hart_Id is
      when 0 => Test_Report.Start ("pmp_access_test_e51");
      when 2 => Test_Report.Start ("pmp_access_test_u54h2");
      when 3 => Test_Report.Start ("pmp_access_test_u54h3");
      when 4 => Test_Report.Start ("pmp_access_test_u54h4");
      when others => Test_Report.Start ("pmp_access_test_u54");
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
   Test_Report.Check (N >= 6, "the hart has the six entries the test needs");
   Test_Report.Check (G <= 10, "the granule is at most 4 KiB");
   if N < 6 or else G > 10 then
      Test_Report.Finish;
   end if;

   --  A: U mode and NAPOT; M mode is not subject to entries without L.
   Clear_All;
   User_Code;
   Set (1, NAPOT or R, Napot_Addr (P0, Page));
   Set (2, NAPOT or R or W, Napot_Addr (P1, Page));
   Set (3, NAPOT or X, Napot_Addr (P2, Page));
   Expect ("U: load from a NAPOT entry R", Load, P0 + Data, True, Ok);
   Expect ("U: store to a NAPOT entry R faults (7)",
           Store, P0 + Data, True, Store_Fault);
   Expect_Mtval (P0 + Data, "mtval of the store fault is its address");
   Expect ("U: execute in a NAPOT entry R faults (1)",
           Exec, P0, True, Fetch_Fault);
   Expect_Mtval (P0, "mtval of the fetch fault is its address");
   Expect ("U: load from a NAPOT entry RW", Load, P1 + Data, True, Ok);
   Expect ("U: store to a NAPOT entry RW", Store, P1 + Data, True, Ok);
   Expect ("U: execute in a NAPOT entry RW faults (1)",
           Exec, P1, True, Fetch_Fault);
   Expect ("U: execute in a NAPOT entry X", Exec, P2, True, Ok);
   Expect ("U: load from a NAPOT entry X faults (5)",
           Load, P2 + Data, True, Load_Fault);
   Expect_Mtval (P2 + Data, "mtval of the load fault is its address");
   Expect ("U: store to a NAPOT entry X faults (7)",
           Store, P2 + Data, True, Store_Fault);
   Expect ("U: load where no entry matches faults (5)",
           Load, P3 + Data, True, Load_Fault);
   Expect ("U: store where no entry matches faults (7)",
           Store, P3 + Data, True, Store_Fault);
   Expect ("U: execute where no entry matches faults (1)",
           Exec, P3, True, Fetch_Fault);
   Expect ("M: store to a NAPOT entry R without L",
           Store, P0 + Data, False, Ok);
   Expect ("M: load from a NAPOT entry X without L",
           Load, P2 + Data, False, Ok);
   Expect ("M: execute in a NAPOT entry RW without L", Exec, P1, False, Ok);
   Expect ("M: store where no entry matches", Store, P3 + Data, False, Ok);

   --  B: TOR (P0 and P1), NA4 (the word P2 + 4), and the lowest index
   --  decides: entry 4 denies P2, the last entry of the hart (Last) allows
   --  everything in P0 .. P3.
   Clear_All;
   User_Code;
   Set (1, OFF, Addr_Of (P0));
   Set (2, TOR or R or W, Addr_Of (P2));
   if G = 0 then
      Set (3, NA4 or R, Addr_Of (P2 + 4));
   else
      Test_Report.Info ("NA4 left out, granularity G", G);
   end if;
   Set (4, NAPOT, Napot_Addr (P2, Page));
   Last := Index (N - 1);
   Test_Report.Info ("last entry", U64 (Last));
   Set (Last, NAPOT or R or W or X, Napot_Addr (P0, 4 * Page));
   Expect ("U: store to the first page of a TOR entry RW",
           Store, P0 + Data, True, Ok);
   Expect ("U: store to the last word of a TOR entry RW",
           Store, P2 - 4, True, Ok);
   Expect ("U: execute in a TOR entry RW faults, a later entry RWX "
           & "does not decide (1)", Exec, P0, True, Fetch_Fault);
   if G = 0 then
      Expect ("U: load from an NA4 entry R", Load, P2 + 4, True, Ok);
      Expect ("U: store to an NA4 entry R faults (7)",
              Store, P2 + 4, True, Store_Fault);
   end if;
   Expect ("U: load from a NAPOT entry without rights faults, a later entry "
           & "RWX does not decide (5)", Load, P2 + Data, True, Load_Fault);
   Expect ("U: load where only the last entry RWX matches",
           Load, P3 + Data, True, Ok);
   Expect ("U: store where only the last entry RWX matches",
           Store, P3 + Data, True, Ok);
   Expect ("U: execute where only the last entry RWX matches",
           Exec, P3, True, Ok);

   --  C: L. Entry 2 is TOR over P0 and P1, R, locked; entry 3 denies P2,
   --  locked. They hold until reset.
   Clear_All;
   User_Code;
   Set (1, OFF, Addr_Of (P0));
   Set (2, TOR or R or L, Addr_Of (P2));
   Set (3, NAPOT or L, Napot_Addr (P2, Page));
   Expect ("M: load from a locked TOR entry R", Load, P0 + Data, False, Ok);
   Expect ("M: store to a locked TOR entry R faults (7)",
           Store, P1 + Data, False, Store_Fault);
   Expect ("M: execute in a locked TOR entry R faults (1)",
           Exec, P0, False, Fetch_Fault);
   Expect ("M: load from a locked NAPOT entry without rights faults (5)",
           Load, P2 + Data, False, Load_Fault);
   Expect ("M: store where no entry matches", Store, P3 + Data, False, Ok);
   Expect ("U: load from a locked TOR entry R", Load, P1 + Data, True, Ok);
   Expect ("U: store to a locked TOR entry R faults (7)",
           Store, P1 + Data, True, Store_Fault);

   A1 := Read_Addr (1);
   A2 := Read_Addr (2);
   A3 := Read_Addr (3);
   Cfg := Read_Cfg (0);
   Write_Addr (1, A1 + 16#400#);
   Test_Report.Check
     (Read_Addr (1) = A1,
      "pmpaddr1, the base of a locked TOR entry, ignores a write");
   Write_Addr (2, A2 + 16#400#);
   Test_Report.Check (Read_Addr (2) = A2,
                      "pmpaddr2 of a locked entry ignores a write");
   Write_Addr (3, 0);
   Test_Report.Check (Read_Addr (3) = A3,
                      "pmpaddr3 of a locked entry ignores a write");
   Write_Cfg (0, 0);
   Test_Report.Check
     (Byte (Read_Cfg (0), 0, 2) = Byte (Cfg, 0, 2)
        and then Byte (Read_Cfg (0), 0, 3) = Byte (Cfg, 0, 3),
      "the configuration bytes of locked entries ignore a write");
   Test_Report.Check (Byte (Read_Cfg (0), 0, 0) = 0,
                      "the configuration byte of an unlocked entry takes it");
   Write_Addr (4, 16#1234_5000#);
   Test_Report.Check
     ((Read_Addr (4) and Addr_Mask) = Legal_Addr (16#1234_5000#, OFF, G),
      "pmpaddr4 of an unlocked entry takes a write");
   Expect ("M: store to the locked TOR entry R still faults (7)",
           Store, P1 + Data, False, Store_Fault);

   Test_Report.Finish;
end Pmp_Access_Test;
