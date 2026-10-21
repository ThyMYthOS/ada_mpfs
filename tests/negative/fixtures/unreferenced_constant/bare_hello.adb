--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Fixture: the main of bare_hello with a constant that nothing reads. The
--  project compiles with -gnatwa -gnatwe, so the warning must stop the build.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;

procedure Bare_Hello is
   Left_Over : constant U64 := Hart_Id;
begin
   Put_Line ("bare hello");
end Bare_Hello;
