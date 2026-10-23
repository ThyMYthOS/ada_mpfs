--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A task (Jorvik: a library-level task without entries) that raises an
--  exception through four frames and handles it itself, and says so.

package Worker is
   pragma Elaborate_Body;


   Caught : Boolean := False with Volatile;
   Done   : Boolean := False with Volatile;

end Worker;
