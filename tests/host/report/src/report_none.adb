--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  No check at all: Host_Report must exit non-zero.

with Host_Report;

procedure Report_None is
begin
   Host_Report.Start ("report_none");
   Host_Report.Finish;
end Report_None;
