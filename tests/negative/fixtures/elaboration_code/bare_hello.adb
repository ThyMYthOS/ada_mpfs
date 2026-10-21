--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Fixture: the main of bare_hello that uses the package Early.

pragma Restrictions (No_Elaboration_Code);
pragma Suppress (All_Checks);

with Bare_Console; use Bare_Console;
with Early;

procedure Bare_Hello is
begin
   Put_Dec (Early.Id);
   Put_Line ("");
end Bare_Hello;
