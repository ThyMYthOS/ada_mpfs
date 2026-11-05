--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  console_mmuart1_test: the console is MMUART1. The verdict comes out on
--  that port (serial 1 of tests/qemu/tests.list) and on no other, and the
--  runtime has programmed it as the link symbols say.

with Console_Checks;

procedure Console_Mmuart1_Test is
begin
   Console_Checks.Port_Test ("console_mmuart1_test", Console_Checks.Base_1);
end Console_Mmuart1_Test;
