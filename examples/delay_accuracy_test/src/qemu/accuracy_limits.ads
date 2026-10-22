--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The limits of delay_accuracy_test under QEMU (the default,
--  DELAY_ACCURACY=qemu). QEMU's mtime follows the host's clock and the guest
--  is scheduled by the host, so a delay can be late by as much as the host
--  takes to run the vCPU again: the test then only requires that a delay is
--  never early, and that it is not late by a whole scheduling slice of a
--  loaded CI machine.

package Accuracy_Limits is

   Strict : constant Boolean := False;
   --  False: the lateness and idle limits below are the loose ones of an
   --  emulator

   Max_Late_Ticks : constant := 20_000;
   --  20 ms; mtime ticks are 1 us

   Rounds : constant := 10;
   --  delays per interval

   Idle_Max_Instret : constant := 0;
   --  not used when not Strict

end Accuracy_Limits;
