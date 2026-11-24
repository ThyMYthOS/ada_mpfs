--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The size of the log ring in bytes. The log of a full run is about 3 KB;
--  the test of the example builds an image with a ring that is too small
--  (MSS_INIT_RING_DIR names the directory of another ring_size.ads).

package Ring_Size is

   Size : constant := 4096;

end Ring_Size;
