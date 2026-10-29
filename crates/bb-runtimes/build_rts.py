# SPDX-FileCopyrightText: 2016-2020 AdaCore
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Derived from alire-project/bb-runtimes build_rts.py @ 09e7cd6 (no license notice upstream;
# GPL-3.0-or-later taken from its COPYING3, see PROVENANCE.md); modified for PolarFire SoC: the
# only board is `mpfs`, selected with a hart class (--hart e51|u54); all other boards and the
# documentation generator are removed.
#
# Python script to gather files for the bareboard runtime.
# Don't use any fancy features.  Ideally, this script should work with any
# Python version starting from 2.6 (yes, it's very old but that's the system
# python on oldest host).

from support import Compiler, set_target_compiler
from support.files_holder import FilesHolder
from support.bsp_sources.installer import Installer

from riscv.mpfs import MPFS, HART_CLASSES

import argparse
import os
import subprocess
import sys

BOARDS = ("mpfs",)


def build_configs(target, hart):
    if target == "mpfs":
        return MPFS(hart)
    print("Error: undefined target %s (the only board is: %s)" % (target, ", ".join(BOARDS)))
    sys.exit(2)


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help=("Forces the installation by overwriting " "any pre-existing runtime."),
    )
    parser.add_argument(
        "--rts-src-descriptor",
        default=os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "gnat_rts_sources",
            "lib",
            "gnat",
            "rts-sources.json",
        ),
        help="The runtime source descriptor file (rts-sources.json); default: the common "
        "GNAT and GNARL sources of this directory (gnat_rts_sources)",
    )
    parser.add_argument(
        "--compiler",
        default="gnat",
        help="The compiler to generate flags for (gnat or gnat_llvm, defaults to gnat)",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="install",
        help="Where built runtimes will be installed",
    )
    parser.add_argument(
        "-l",
        "--link",
        action="store_true",
        help="Use symlinks instead of copies when installing",
    )
    parser.add_argument("-b", "--build", action="store_true", help="Build the runtimes")
    parser.add_argument("--build-flags", help="Flags passed to gprbuild")
    parser.add_argument(
        "--shared",
        action="store_true",
        help="Additionally build shared runtime "
        "(only available on platforms that support shared libraries)",
    )
    parser.add_argument(
        "--hart",
        required=True,
        choices=sorted(HART_CLASSES),
        help="The hart class the runtime is generated for (e51 or u54)",
    )
    parser.add_argument(
        "target",
        nargs="+",
        choices=BOARDS,
        help="List of target boards to generate runtimes for (only: mpfs)",
    )
    parser.add_argument(
        "--profiles",
        type=str,
        help="Comma seperated list of profiles to generate runtimes for",
    )
    args = parser.parse_args()

    if args.verbose:
        FilesHolder.verbose = True
    if args.link:
        FilesHolder.link = True
    if args.force:
        Installer.overwrite = True

    set_target_compiler(Compiler[args.compiler])

    boards = []

    for arg in args.target:
        board = build_configs(arg, args.hart)
        boards.append(board)

    dest = os.path.abspath(args.output)
    if not os.path.exists(dest):
        os.makedirs(dest)

    # Install the runtimes sources
    projects = []
    for board in boards:
        print("install runtime sources for %s" % board.name)
        sys.stdout.flush()
        installer = Installer(board)
        projects += installer.install(
            dest,
            rts_descriptor=args.rts_src_descriptor,
            profiles=args.profiles.split(",") if args.profiles is not None else None,
        )

    # and build them
    if args.build:
        for prj in projects:
            # Objects needed before building the runtime
            obj_dir = os.path.join(os.path.dirname(prj), "obj")
            if not os.path.isdir(obj_dir):
                if os.path.exists(obj_dir):
                    raise RuntimeError("obj should be a directory")
                os.makedirs(obj_dir)
            board.pre_build_step(obj_dir)
            print("building project %s" % prj)
            sys.stdout.flush()
            cmd = ["gprbuild", "-j0", "-p", "-v", "-P", prj]
            if args.build_flags is not None:
                cmd += args.build_flags.split()
            subprocess.check_call(cmd)
            if args.shared:
                cmd.extend(["-f", "-XLIBRARY_TYPE=dynamic", "-largs", "-L" + obj_dir])
                subprocess.check_call(cmd)
            # Post-process: remove build artifacts from obj directory
            cleanup_ext = (".o", ".ali", ".stdout", ".stderr", ".d", ".lexch", ".so")
            for fname in os.listdir(obj_dir):
                _, ext = os.path.splitext(fname)
                if ext in cleanup_ext:
                    os.unlink(os.path.join(obj_dir, fname))

    print("runtimes successfully installed in %s" % dest)


if __name__ == "__main__":
    main()
