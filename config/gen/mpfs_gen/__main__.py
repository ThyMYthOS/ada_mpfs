# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The command line of the configuration generator (as far as it exists).

  python3 config/gen/mpfs_gen check FILE...            validate system descriptions
  python3 config/gen/mpfs_gen preset HART CPUS PROFILE PRIV
                                                       print the standalone preset of a runtime variant
  python3 config/gen/mpfs_gen standalone-args FILE     print the parameters of standalone.py for a
                                                       description of one partition

`check` prints `FILE: ok` or one line per violated rule, `FILE: GEN-Exxx PATH: message`.
Exit status: 0 ok, 2 a description breaks a rule or the arguments are wrong.
"""
import argparse
import sys
from pathlib import Path

# Run as `python3 config/gen/mpfs_gen`, the directory of this file is the first entry of the module path,
# where target.py and the others would hide modules of the standard library: the package is imported
# from its parent instead, with tools/ for gen_ada.
HERE = Path(__file__).resolve().parent
sys.path[:] = [p for p in sys.path if p not in (str(HERE), "")]
sys.path[:0] = [str(HERE.parent), str(HERE.parents[2] / "tools")]

from gen_ada import errors

from mpfs_gen import presets, yaml_reader
from mpfs_gen.checks import SystemDescriptionError

TOOL = "mpfs_gen"


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="mpfs_gen", description="The configuration generator.")
    sub = p.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="validate system descriptions")
    check.add_argument("files", nargs="+", type=Path)
    pre = sub.add_parser("preset", help="the standalone preset of a runtime variant")
    pre.add_argument("hart", choices=("e51", "u54"))
    pre.add_argument("cpus", type=int, choices=(1, 2, 3, 4))
    pre.add_argument("profile", choices=("light", "light-tasking", "embedded"))
    pre.add_argument("priv", choices=("m", "u"))
    args = sub.add_parser("standalone-args", help="the parameters of standalone.py for a description")
    args.add_argument("file", type=Path)
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    if args.command == "preset":
        sys.stdout.write(presets.preset_text(args.hart, args.cpus, args.profile, args.priv))
        return errors.OK
    if args.command == "standalone-args":
        print(" ".join(presets.standalone_args(yaml_reader.read(args.file))))
        return errors.OK
    status = errors.OK
    for path in args.files:
        try:
            yaml_reader.read(path)
            print(f"{path}: ok")
        except SystemDescriptionError as err:
            print(err, file=sys.stderr)
            status = errors.INPUT_ERROR
    return status


if __name__ == "__main__":
    sys.exit(errors.run(main, TOOL, sys.argv[1:]))
