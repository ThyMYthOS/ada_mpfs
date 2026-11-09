# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Shared plumbing of the code generators (see tools/README.md).

The generators of the repository (tools/pac_gen.py, tools/svd.py, tools/trace.py,
tools/regmap2svd.py, crates/mpfs_rts/gen_intnam.py) import the modules they need from here; a
generator holds only what is its own: its inputs, its rules and its output format.
"""
