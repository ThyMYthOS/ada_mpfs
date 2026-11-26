# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-016
"""The input of the independent checker of the PMP (tools/pmp_check): the sections of system.json that it reads.

The checker shares no logic with the generator, only data: what the partitions own and where (the target), and
the PMP entries and way masks as they will be set. This module writes exactly that, from a derived system and
its MSS Configurator XML, as canonical JSON (keys sorted, an indent of one, a newline at the end; lists in a
fixed order: the harts by number, the partitions, windows and memories in the order of the derivation, the
critical blocks by address). system.json, which the emitters will write, takes these keys over unchanged and
adds its own; the checker ignores keys it does not know.

  version             1
  security_profile    prod or dev
  contexts            a_harts, b_harts: the harts of CONTEXT_A_HART_EN and CONTEXT_B_HART_EN
  pmp                 enabled: MEM_CONFIGS_ENABLED.PMP; entries: the PMP entries of the target (16, 8 for
                      QEMU); harts: per hart its pmpaddr_bits, the 16 configuration bytes (cfg) and pmpaddr
                      values (addr) of the XML as they are (not decoded), and the generated unlocked entries
                      (generated: index, cfg, addr; an index may pass 15 when the allow list does not fit)
  partitions          name, harts, priv, monitor, peripherals (its peripherals and console at the address
                      APBBUS_CR gives: name, block of the SVD, base, length in whole pages)
  windows             kind, memory, base, length, owners, channel (null for a window of a partition)
  memories            name, base, length, hart (null for a memory of no hart), itim; a memory without a byte
                      (the scratchpad of an L2 without scratchpad ways) is left out
  critical            the critical blocks: name, block of the SVD, base, length, hart (of a bus error unit)
  mtime               the page of mtime: base, length
  buses               lo, hi: the peripherals of both APB buses at their LO and at their HI address
  l2                  way_enable, scratchpad_ways (WAY_ENABLE, NUM_SCRATCH_PAD_WAYS of the XML) and
                      way_masks (master, mask)

Every range is base and length in bytes. The values are those of the XML and of the derivation, with nothing
classified for the checker beyond what the generator decides as data: which memory is an ITIM, which block is
critical and which bus error unit belongs to which hart.
"""
import json
from typing import Any

from gen_ada import svdread

from . import pmp as pmp_
from . import target
from .derive import Derived
from .derive import contexts as contexts_
from .derive import l2 as l2_
from .derive import protection as protection_
from .derive.placement import itim_name
from .model import MssConfiguration

VERSION = 1


def _range(base: int, length: int) -> dict[str, int]:
    return {"base": base, "length": length}


def _block(b: contexts_.Block) -> dict[str, Any]:
    return {"name": b.name, "block": b.block, **_range(b.base, b.length)}


def check_input(d: Derived, config: MssConfiguration, blocks: dict[str, svdread.Block]) -> dict[str, Any]:
    """The check input of the derived system <d> of the XML <config>; <blocks> are the blocks of the SVD (for the
    bus windows). <d> needs its protection (every derivation has it)."""
    pr = d.protection
    if pr is None or d.way_masks is None:
        raise ValueError("a derived system without its protection or way masks")
    harts, _ = pmp_.of(config)
    beus = {protection_.beu_name(h): h for h in range(target.NUMBER_OF_HARTS)}
    enabled = config.register(pmp_.APB_SPLIT, "MEM_CONFIGS_ENABLED").field("PMP").value
    return {
        "version": VERSION,
        "security_profile": d.system.security_profile,
        "contexts": {"a_harts": list(pr.contexts.a_harts), "b_harts": list(pr.contexts.b_harts)},
        "pmp": {
            "enabled": bool(enabled),
            "entries": pr.entries,
            "harts": [{"hart": p.hart, "pmpaddr_bits": target.PMPADDR_BITS[p.hart],
                       "cfg": [e.cfg for e in p.entries], "addr": [e.addr for e in p.entries],
                       "generated": [{"index": e.index, "cfg": e.cfg, "addr": e.addr}
                                     for e in pr.hart(p.hart).generated]} for p in harts],
        },
        "partitions": [{"name": sp.name, "harts": list(sp.harts), "priv": sp.priv, "monitor": sp.monitor,
                        "peripherals": [_block(b) for b in dp.blocks]}
                       for sp, dp in zip(d.system.partitions, d.partitions)],
        "windows": [{"kind": w.kind, "memory": w.memory, **_range(w.origin, w.length), "owners": list(w.owners),
                     "channel": w.channel} for w in d.windows],
        "memories": [{"name": m.name, **_range(m.origin, m.length), "hart": m.hart,
                      "itim": m.hart is not None and m.name == itim_name(m.hart)} for m in d.memories if m.length],
        "critical": [{**_block(b), "hart": beus.get(b.name)} for b in pr.critical],
        "mtime": _range(pr.mtime.base, pr.mtime.length),
        "buses": {bus.lower(): [_block(b) for b in contexts_.bus_blocks(blocks, bus)] for bus in ("LO", "HI")},
        "l2": {"way_enable": config.value(l2_.CACHE, "WAY_ENABLE"),
               "scratchpad_ways": config.value(l2_.CACHE, "NUM_SCRATCH_PAD_WAYS"),
               "way_masks": [{"master": master, "mask": mask} for master, mask in d.way_masks.masks]},
    }


def text(data: dict[str, Any]) -> str:
    """<data> as canonical JSON: keys sorted, an indent of one, a newline at the end."""
    return json.dumps(data, sort_keys=True, indent=1) + "\n"
