# SPDX-FileCopyrightText: AdaCore
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Board `mpfs` (Microchip PolarFire SoC, one hart in machine mode) and its hart classes.
#
# Derived from alire-project/bb-runtimes riscv/__init__.py (class PolarFireSOC) @ 09e7cd6
# (no license notice upstream; GPL-3.0-or-later taken from its COPYING3, see PROVENANCE.md);
# modified for PolarFire SoC: the hart class (E51 or U54) selects the ISA switches and the FPU,
# the linker scripts are not part of the runtime (the partition data provides them), the hart
# literals stay as upstream until the own port units replace them.

from riscv import RiscV64


class HartClass(object):
    """The parameters of a hart class (master plan #41, section 4.1)."""

    def __init__(self, name, march, mabi, has_fpu):
        self.name = name
        self.march = march
        self.mabi = mabi
        self.has_fpu = has_fpu


#  E51: RV64IMAC monitor core, no FPU. U54: RV64GC application cores with FPU. The CSR and
#  fence.i instructions are separate extensions (zicsr, zifencei) with GCC 12 and newer;
#  the start code and the trap handler need both.
HART_CLASSES = {
    "e51": HartClass("e51", "rv64imac_zicsr_zifencei", "lp64", False),
    "u54": HartClass("u54", "rv64imafdc_zicsr_zifencei", "lp64d", True),
}


class MPFS(RiscV64):
    def __init__(self, hart_class):
        if hart_class not in HART_CLASSES:
            raise ValueError(
                "unknown hart class %r (expected one of: %s)"
                % (hart_class, ", ".join(sorted(HART_CLASSES)))
            )
        #  Target.__init__ evaluates the properties below, so this comes first.
        self.hart = HART_CLASSES[hart_class]
        super(MPFS, self).__init__()

        #  No loader scripts: the linker script comes from the partition data. The
        #  upstream common-RAM.ld and memory-map.ld are not imported.
        self.add_gnat_sources(
            "riscv/mpfs/start-ram.S",
            "riscv/sifive/fe310/svd/i-fe310.ads",
            "riscv/sifive/fe310/svd/i-fe310-plic.ads",
            "riscv/sifive/fe310/s-macres.adb",
            "src/s-textio__ns16550.adb",
            "src/s-bbbopa__polarfiresoc.ads",
            "riscv/src/riscv_def.h",
        )
        self.add_gnarl_sources(
            "riscv/mpfs/a-intnam.ads",
            "src/s-bbpara__polarfiresoc.ads",
            "src/s-bbbosu__riscv.adb",
            "src/s-bbsuti__riscv_clint.adb",
            "src/s-bbsumu__generic.adb",
            "src/s-bbcppr__new.ads",
            "src/s-bbcppr__riscv.adb",
            "src/s-bbcpsp__riscv.ads",
            "src/s-bbcpsp__riscv.adb",
            "riscv/src/context_switch.S",
            "riscv/src/trap_handler.S",
            "riscv/src/s-bbripl.ads",
            "riscv/mpfs/s-bbripl.adb",
        )

    @property
    def name(self):
        return "mpfs"

    @property
    def compiler_switches(self):
        #  -mcmodel=medany is the default of the toolchain spec and is not repeated here.
        return ("-march=" + self.hart.march, "-mabi=" + self.hart.mabi)

    @property
    def system_ads(self):
        return {
            "light": "system-xi-riscv.ads",
            "light-tasking": "system-xi-riscv-sifive-sfp.ads",
            "embedded": "system-xi-riscv-sifive-full.ads",
        }

    @property
    def has_single_precision_fpu(self):
        return self.hart.has_fpu

    @property
    def has_double_precision_fpu(self):
        return self.hart.has_fpu

    @property
    def loaders(self):
        return None
