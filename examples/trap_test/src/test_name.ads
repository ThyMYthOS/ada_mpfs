--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The name of the test in its report: Test_Report.Start gets Base & "_e51"
--  (and so on), the name of the row in tests/qemu/tests.list. An example that
--  builds the same sources with another runtime profile (examples/STYLE.md,
--  "Profile variants") has a Test_Name of its own in src/, mapped to this unit
--  by the Naming package of its project.

package Test_Name is

   Base : constant String := "trap_test";

end Test_Name;
