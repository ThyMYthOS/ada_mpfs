--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  What unhandled_test and unhandled_task_test raise, and nobody handles.

package Failing is

   Boom : exception;

   Message : constant String := "nobody handles this";

   --  Raises Boom with the message Failing.Message through N + 1 frames.
   procedure Run (N : Natural);

end Failing;
