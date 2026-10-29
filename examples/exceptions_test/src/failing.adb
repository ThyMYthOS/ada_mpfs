--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package body Failing is

   procedure Run (N : Natural) is
   begin
      if N = 0 then
         raise Boom with Message;
      end if;
      Run (N - 1);
   end Run;

end Failing;
