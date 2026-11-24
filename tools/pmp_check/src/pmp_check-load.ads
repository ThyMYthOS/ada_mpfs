--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The check input (the JSON of `mpfs_gen derive --check-json`, config/README.md) read into the model:
--  every key the checker needs must be there with a value of its type and range, the five harts once
--  each with 16 configuration bytes and 16 pmpaddr values, every range inside the 2 ** 56 bytes a PMP
--  entry can name, every owner of a window a partition. Keys the checker does not need are ignored, so
--  that a larger document (the system.json to come) can carry the same keys.
--
--  @req GEN-015

with Pmp_Check.Json;
with Pmp_Check.Model;
with Pmp_Check.Texts;

package Pmp_Check.Load
  with SPARK_Mode
is
   procedure Read (Doc : Json.Document; Src : String; Root : Json.Node_Id; S : out Model.System;
                   Ok : out Boolean; Err : in out Texts.Text);

end Pmp_Check.Load;
