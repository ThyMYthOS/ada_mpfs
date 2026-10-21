--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Passing checks but no Finish: Host_Report must exit non-zero.

with Host_Report;

procedure Report_Unfinished is
begin
   Host_Report.Start ("report_unfinished");
   Host_Report.Check (True, "holds");
end Report_Unfinished;
