--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  The rules the checker evaluates, each reported with the code the generator gives the same rule
--  (config/README.md), at the same path:
--
--  The PMP table of the XML of each hart (path mss_memory_map/pmp_h<n>...):
--    GEN-E100  an entry with W set and R clear
--    GEN-E101  a configuration byte with bit 5 or 6 set
--    GEN-E102  a locked entry after an unlocked entry in use (not OFF). It also covers the two
--              properties of the layout: no unlocked entry can let M mode through a locked deny entry
--              (an unlocked entry decides M mode only if it comes first), and the base of a locked TOR
--              entry is locked (the entry before it is locked, or an unlocked OFF entry whose pmpaddr
--              the L of the TOR entry locks).
--    GEN-E103  an entry in use (not OFF, or locked) at an index beyond the entries of the target
--    GEN-E104  entries set while MEM_CONFIGS_ENABLED.PMP is 0
--    GEN-E105  a locked entry with rights over the whole space or over the range of a later entry
--  The PMP of each hart, the table of the XML with the generated entries set at their indices
--  (path partitions[<i>]...), evaluated over the intervals of Eval for every mode and access against
--  the zones of its partition (own, foreign, peer: foreign of the same AMP context, grant: SYSREG and
--  MPUCFG, critical, bus: the bus window of the other context; the first zone that holds an interval
--  names it). U mode for a U partition; M mode where the hart has a locked entry and the partition is
--  not the monitor.
--    GEN-E120  U mode lacks a right on a window of its own (fast_text only in the ITIM of the hart)
--    GEN-E121  U mode cannot read and write a peripheral of its own
--    GEN-E122  U mode cannot read the page of mtime
--    GEN-E123  U mode reaches what is in no zone
--    GEN-E124  U mode reaches a foreign zone, or a peer zone through an unlocked entry; M mode a
--              foreign zone
--    GEN-E125  U mode reaches a critical block
--    GEN-E126  U mode reaches SYSREG or MPUCFG
--    GEN-E127  M mode reaches a critical block, SYSREG or MPUCFG
--    GEN-E128  M mode reaches a peer zone
--    GEN-E129  a generated entry beyond the entries of the target
--    GEN-E135  U or M mode reaches the bus window of the other context
--    GEN-E136  U mode reaches a peer zone through a locked entry
--  The way masks of the L2 (path mss_memory_map/cache/...), against the split of the XML:
--    GEN-E072  WAY_ENABLE and NUM_SCRATCH_PAD_WAYS leave no cache way (or WAY_ENABLE above 15); the
--              masks are then not checked
--    GEN-E073  a way mask includes a scratchpad way
--    GEN-E085  a way mask has no cache way
--  l2.cache_partitioning of system.yaml, where given:
--    GEN-E146  the cache ways of the data or instruction mask of a hart it names are not its ways
--    GEN-E147  two harts of different partitions share a cache way in their masks (path
--              l2.cache_partitioning)
--  The MPU of the DMA masters: Pmp_Check.Mpu (GEN-E140 to GEN-E145).
--
--  @req GEN-015, GEN-019

with Pmp_Check.Findings;
with Pmp_Check.Model;

package Pmp_Check.Rules
  with SPARK_Mode
is
   procedure Check (S : Model.System; F : in out Findings.List);

end Pmp_Check.Rules;
