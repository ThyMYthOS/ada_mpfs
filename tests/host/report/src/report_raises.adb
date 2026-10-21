--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  An unhandled exception after a passing check: the exit status must be
--  non-zero.

with Host_Report;

procedure Report_Raises is
begin
   Host_Report.Start ("report_raises");
   Host_Report.Check (True, "holds");
   raise Program_Error;
end Report_Raises;
