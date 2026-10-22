# SPDX-FileCopyrightText: AdaCore
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Common base of the riscv64 boards (the board `mpfs` is in riscv/mpfs).
#
# Derived from alire-project/bb-runtimes riscv/__init__.py @ 09e7cd6 (no license notice upstream;
# GPL-3.0-or-later taken from its COPYING3, see PROVENANCE.md); modified for PolarFire SoC: only
# class RiscV64 is kept, the other boards (Spike, PolarFireSOC, HiFive1, the RV32 and RV64 generic
# ones) are removed.

from support import readfile
from support.bsp_sources.target import DFBBTarget


class RiscV64(DFBBTarget):
    @property
    def name(self):
        return "riscv64"

    @property
    def target(self):
        return "riscv64-elf"

    @property
    def has_huge_memory(self):
        return True

    @property
    def has_timer_64(self):
        return True

    @property
    def is_64bit(self):
        return True

    @property
    def system_ads(self):
        return {"light": "system-xi-riscv.ads"}

    def dump_runtime_xml(self, rts_name, rts):
        cnt = super(RiscV64, self).dump_runtime_xml(rts_name, rts)
        if rts_name == "embedded":
            cnt = cnt.replace(
                '"-nostartfiles"', '"--specs=${RUNTIME_DIR(ada)}/link-zcx.spec"'
            )
        return cnt

    def amend_rts(self, rts_profile, conf):
        super(DFBBTarget, self).amend_rts(rts_profile, conf)
        if rts_profile == "embedded":
            conf.config_files.update({"link-zcx.spec": readfile("riscv/link-zcx.spec")})
