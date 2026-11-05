--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Code and data that the application wants in the local memories of the
--  hart: Add is in the section .fast_text (ITIM) and Table in .fast_data
--  (DTIM). The sections are those of the application's own app-sections.ld
--  (the runtime declares none); start.S copies them from their load address
--  before the main program.

with Interfaces;

package Fast is

   function Add (A, B : Integer) return Integer
     with No_Inline, Linker_Section => ".fast_text";

   type Table_Type is array (1 .. 4) of Interfaces.Unsigned_64;

   Table : Table_Type :=
     [16#0123_4567_89AB_CDEF#, 16#FEDC_BA98_7654_3210#, 1, 2]
     with Linker_Section => ".fast_data";

end Fast;
