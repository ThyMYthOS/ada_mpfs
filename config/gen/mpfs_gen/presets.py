# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-002
"""The standalone presets: the system description of each runtime variant that ./x build builds without
one, and the parameters of standalone.py that a description of one partition stands for.

  VARIANTS                         the 30 runtime variants (hart class, CPUs, profile, privilege mode)
  variant_name(...)                the name of a variant as in build/rts: light-u54-cpus2-u
  preset_text(...)                 the system.yaml of a variant (rendered, not committed)
  preset(...)                      the System of that text, read by yaml_reader like any description
  standalone_args(system)          the parameters of standalone.py for a system of one partition

A preset is the partition that ./x build gives a variant without options: the harts of the variant (the
E51 is hart 0, a U54 variant of n CPUs has the harts 1 to n), the memory profile lim, every other value
the default of its field. The defaults are not repeated here: the text names only the harts, the profile,
the privilege mode and the region, and the reader applies the rest from target.py, which standalone.py
uses too. standalone_args() maps a description back to the parameters of standalone.py, so that
`standalone.py <standalone_args(preset(v))>` writes the bytes of `./x build` for v (tests/host/system_yaml).
"""
from gen_ada import errors, spdx

from . import target
from .model import System
from .yaml_reader import read_text

CPUS = {"e51": (1,), "u54": (1, 2, 3, 4)}
VARIANTS: tuple[tuple[str, int, str, str], ...] = tuple(
    (hart, cpus, profile, priv)
    for hart in target.HARTS for cpus in CPUS[hart] for profile in target.PROFILES for priv in target.PRIVILEGES)

# The memory profile of standalone.py for the regions of code and data (placement script place-<profile>.ld).
MEMORY_PROFILE = {("lim", "lim"): "lim", ("scratchpad", "scratchpad"): "scratchpad", ("envm", "lim"): "envm"}


class PresetError(errors.InputError):
    """A variant that does not exist, or a description that standalone.py cannot stand for."""


def variant_name(hart: str, cpus: int, profile: str, priv: str) -> str:
    return f"{profile}-{hart}-cpus{cpus}-{priv}"


def harts_of(hart: str, cpus: int) -> list[int]:
    """The harts of a variant: hart 0 for the E51, harts 1 to <cpus> for the U54."""
    if (hart, cpus) not in {(h, c) for h, cs in CPUS.items() for c in cs}:
        raise PresetError(f"no runtime variant for {hart} with {cpus} CPUs")
    return [target.E51_HART] if hart == "e51" else list(target.U54_HARTS[:cpus])


def preset_text(hart: str, cpus: int, profile: str, priv: str) -> str:
    """The system.yaml of the variant."""
    if profile not in target.PROFILES or priv not in target.PRIVILEGES:
        raise PresetError(f"no runtime variant for profile {profile!r} and privilege mode {priv!r}")
    harts = harts_of(hart, cpus)
    lines = [
        *spdx.header("yaml", "Apache-2.0").splitlines(),
        "#",
        f"# The standalone preset of the runtime variant {variant_name(hart, cpus, profile, priv)}: the partition",
        "# that ./x build gives it without options. Rendered by config/gen/mpfs_gen/presets.py.",
        "schema: 1",
        "board: icicle",
        "partitions:",
        "  - name: standalone",
        f"    harts: [{', '.join(map(str, harts))}]",
        f"    profile: {profile}",
        f"    priv: {priv}",
        "    memory:",
        "      code: { region: lim }",
        "      data: { region: lim }",
    ]
    return "\n".join(lines) + "\n"


def preset(hart: str, cpus: int, profile: str, priv: str) -> System:
    """The System of the preset of the variant."""
    return read_text(preset_text(hart, cpus, profile, priv), f"preset {variant_name(hart, cpus, profile, priv)}")


def standalone_args(system: System) -> list[str]:
    """The parameters of standalone.py that give the partition data of <system>, a system of one
    partition whose windows take their whole regions."""
    if len(system.partitions) != 1:
        raise PresetError(f"standalone.py describes one partition, the system has {len(system.partitions)}")
    part = system.partitions[0]
    memory = MEMORY_PROFILE.get((part.memory.code.region, part.memory.data.region))
    if memory is None or part.memory.code.size is not None or part.memory.data.size is not None:
        raise PresetError("standalone.py places code and data in whole regions: lim and lim, scratchpad and "
                          "scratchpad, or envm and lim, without a size")
    args = ["--hart", "e51" if target.E51_HART in part.harts else "u54",
            "--harts", ",".join(map(str, part.harts)),
            "--profile", part.profile,
            "--memory", memory,
            "--console", part.console,
            "--stack-size", str(part.stacks.main),
            "--interrupt-stack-size", str(part.stacks.interrupt),
            "--secondary-stack-size", str(part.stacks.secondary)]
    if part.memory.fast_text is not None and part.memory.fast_text.size is not None:
        args += ["--itim-length", hex(part.memory.fast_text.size)]
    ways = system.l2.ways
    if ways is not None:
        args += ["--cache-ways", str(ways.cache), "--lim-ways", str(ways.lim),
                 "--scratchpad-ways", str(ways.scratchpad)]
    return args
