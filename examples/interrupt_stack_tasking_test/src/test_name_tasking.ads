--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package Test_Name is

   Peak : constant String := "istack_peak_tasking_test";
   Peak_Limit : constant := 1024;
   --  Bytes: the peak of the trap in this profile is 600 (E51) and 856 (U54)
   Overflow : constant String := "istack_overflow_tasking_test";
   --  with "_e51" or "_u54": the name of the image and in the report

end Test_Name;
