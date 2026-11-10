--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The first unit of the chain: it withs nothing of the test but the log.
--  Its body notes itself, and a constant of its specification is computed by
--  a call when the specification is elaborated.

package Elab_A is
   pragma Elaborate_Body;

   function Twice (N : Integer) return Integer is (2 * N);

   Value : constant Integer := Twice (21);
   --  42, computed when the specification is elaborated

   Noted_At : Natural := 0;
   --  Elab_Log.Count when the body was elaborated (set by the body)

end Elab_A;
