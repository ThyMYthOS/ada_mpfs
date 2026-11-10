--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  A library-level task. The declarative part of its body is elaborated when
--  the task is activated, after the library units are elaborated; it notes
--  itself in the log (Elab_Log) like the units of the chain. Its priority is
--  the highest, so that it runs, as soon as it is activated, before the main
--  program does (a task of a lower priority than the main program starts when
--  that waits).

with System;

package Elab_Tasks is

   task Worker with Priority => System.Priority'Last, Storage_Size => 4096;

   --  True once the statements of the task have run
   function Started return Boolean;

end Elab_Tasks;
