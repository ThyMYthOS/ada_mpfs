--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Entry point of the image: start.S calls it as main.

pragma Restrictions (No_Elaboration_Code);

procedure Pmp_Probe
  with Export, Convention => C, External_Name => "main";
