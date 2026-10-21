--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package body Unprovable
  with SPARK_Mode
is
   function Add (A, B : Integer) return Integer is (A + B);
end Unprovable;
