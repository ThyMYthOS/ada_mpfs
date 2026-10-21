--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Every check holds: Host_Report must exit 0.

with Host_Report;

procedure Report_Ok is
begin
   Host_Report.Start ("report_ok");
   Host_Report.Check (Host_Report.Failures = 0, "no failure so far");
   Host_Report.Finish;
end Report_Ok;
