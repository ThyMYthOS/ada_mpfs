--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0

package Test_Name is

   Peak : constant String := "istack_peak_embedded_test";
   Peak_Limit : constant := 7680;
   --  Bytes: the peak of the first exception in a trap when the runtime has
   --  sorted the frame descriptions before main (7144 on the E51, 7496 on the
   --  U54), and below the 8256 and 8608 of a first search in the trap
   Overflow : constant String := "istack_overflow_embedded_test";
   --  with "_e51" or "_u54": the name of the image and in the report

end Test_Name;
