--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  console_mmuart4_test: the console is MMUART4. The verdict comes out on
--  that port (serial 4 of tests/qemu/tests.list) and on no other, and the
--  runtime has programmed it as the link symbols say.

with Console_Checks;

procedure Console_Mmuart4_Test is
begin
   Console_Checks.Port_Test ("console_mmuart4_test", Console_Checks.Base_4);
end Console_Mmuart4_Test;
