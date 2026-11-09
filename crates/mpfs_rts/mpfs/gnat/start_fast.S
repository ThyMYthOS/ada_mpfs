/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * start_fast.S -- the start code for an image with code or data in the local memories (ITIM,
 * DTIM): start.S assembled with MPFS_FAST, which adds the check and the copy step (see there).
 * An image without such code has start.S from the library, byte for byte what it was before the
 * feature, and nothing of this (crates/mpfs_rts/README.md, "ITIM and DTIM").
 *
 * gen_runtime.sh copies the object to adalib/start_fast.o, and Mpfs_Link.Fast_Switches puts it on the
 * link line: it defines _start, __gnat_exit and the trap stub before libgnat.a is searched, so
 * start.o, which defines the same, is not taken from the library.
 */
/* @req RTS-017 */

#define MPFS_FAST 1
#include "start.S"
