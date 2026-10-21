--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Fixture: the addition can overflow, and nothing says it cannot.

package Unprovable
  with SPARK_Mode
is
   function Add (A, B : Integer) return Integer
     with Post => Add'Result = A + B;
end Unprovable;
