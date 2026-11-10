--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

with Elab_Log;

package body Elab_C is
begin
   Noted_At := Elab_Log.Count;
   Elab_Log.Note (Elab_Log.Unit_C);
end Elab_C;
