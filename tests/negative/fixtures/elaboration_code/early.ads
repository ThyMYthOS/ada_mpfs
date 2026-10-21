--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Fixture: a library-level constant initialised by a call needs elaboration
--  code, which an image without a binder does not have.

pragma Restrictions (No_Elaboration_Code);

with Bare_Console;

package Early is
   Id : constant Bare_Console.U64 := Bare_Console.Hart_Id;
end Early;
