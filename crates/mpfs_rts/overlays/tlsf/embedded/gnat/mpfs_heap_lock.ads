--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
--
--  The lock of the heap (MPFS_Heap). This specification is the interface;
--  the body is the part that depends on the number of harts:
--
--    one hart (this body): the lock is "no interrupt on this hart". Acquire
--    clears mstatus.MIE and returns the old bit, Release sets it again if it
--    was set. Nothing else can run on the hart, so nothing else is needed.
--    Valid for the machine mode of a single hart only (a trap handler of
--    another privilege mode, or a second hart, is not excluded).
--
--    several harts: a body that, after the interrupts are masked, takes a
--    lock word with an atomic operation (amoswap.w, or lr.w and sc.w) and
--    gives it back in Release. The state then holds both the old mstatus.MIE
--    and what Release needs. Specification and callers do not change.
--
--  Rules for the caller, which a body may rely on:
--    - Acquire and Release are paired and nested;
--    - nothing between them blocks, waits for an interrupt or calls Acquire
--      again: the heap is not reentrant (MPFS_Heap never calls itself under
--      the lock), so a second Acquire would wait for itself;
--    - the time between them is short: it is a time with interrupts off.

with Interfaces;

package MPFS_Heap_Lock is
   pragma Preelaborate;

   --  What Release needs to restore: opaque to the caller.
   type Saved_State is private;

   function Acquire return Saved_State;

   procedure Release (State : Saved_State);

private

   type Saved_State is new Interfaces.Unsigned_64;

end MPFS_Heap_Lock;
