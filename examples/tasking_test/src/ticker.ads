--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A periodic library-level task (Ravenscar: no task hierarchy) that counts
--  its periods.

with Interfaces;

package Ticker is

   Ticks : Interfaces.Unsigned_32 := 0 with Volatile;

   task Worker with Priority => 10, Storage_Size => 4096;

end Ticker;
