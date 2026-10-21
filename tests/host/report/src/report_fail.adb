--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  One check fails: Host_Report must exit non-zero.

with Host_Report;

procedure Report_Fail is
begin
   Host_Report.Start ("report_fail");
   Host_Report.Check (True, "holds");
   Host_Report.Check (False, "does not hold");
   Host_Report.Finish;
end Report_Fail;
