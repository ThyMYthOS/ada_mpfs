--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  Derived from rowsail/ada_esp32s3 examples/common/bare/boot/heap_guard.ads @ d75142d
--  (Apache-2.0); modified for PolarFire SoC: Max_Request is the largest
--  request that Tlsf_Core serves (Tlsf_Math.Max_Alloc), not Storage_Count'Last
--  (on a 64-bit target that is far above what the size classes cover), and the
--  pragma Preelaborate.

with Interfaces.C;
with System.Storage_Elements; use System.Storage_Elements;
with Tlsf_Math;

--  The pure request-size arithmetic of the malloc/free glue (MPFS_Heap), split
--  out with SPARK contracts so gnatprove can machine-check that no size request
--  can wrap into a smaller allocation than the caller asked for -- the classic
--  malloc/calloc integer-overflow class.  MPFS_Heap's body proper takes the
--  lock (inline asm) and hands raw addresses to Tlsf_Core, both outside
--  SPARK's model; THIS is the pure size math it calls first.
package Heap_Guard with SPARK_Mode => On, Preelaborate is

   subtype Size_T is Interfaces.C.size_t;
   use type Interfaces.C.size_t;

   --  Largest byte count the allocator serves: the size classes of Tlsf_Math
   --  cover it, and it is a Storage_Count, so no size arithmetic on it wraps.
   Max_Request : constant Size_T := Size_T (Tlsf_Math.Max_Alloc);

   --  A single malloc/realloc request is serviceable iff it is within
   --  Max_Request, so the later Storage_Count (N) conversion cannot wrap.
   function Request_Fits (N : Size_T) return Boolean
   is (N <= Max_Request)
     with Post => Request_Fits'Result = (N <= Max_Request);

   --  calloc element-array sizing.  Ok is set iff Count elements of Elem bytes
   --  neither overflow size_t nor exceed Max_Request; then Total is that product
   --  (the Storage_Count multiplication is proved not to overflow).  Otherwise
   --  Ok is False and Total is 0 -- so a wrapping request can never yield a live
   --  but under-sized buffer.  Count = 0 or Elem = 0 is a valid 0-byte request
   --  (handled before any conversion, so a huge Count with Elem = 0 cannot wrap
   --  the Storage_Count (Count) cast).
   procedure Array_Bytes
     (Count, Elem : Size_T; Total : out Storage_Count; Ok : out Boolean)
     with Post =>
       (if Count = 0 or else Elem = 0
          then Ok and then Total = 0
        elsif Count <= Size_T'Last / Elem and then Count * Elem <= Max_Request
          then Ok and then Total = Storage_Count (Count * Elem)
        else not Ok and then Total = 0);

end Heap_Guard;
