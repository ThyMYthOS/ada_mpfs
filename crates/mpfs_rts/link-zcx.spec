# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
# Derived from alire-project/bb-runtimes riscv/link-zcx.spec @ 09e7cd6 (GPL-3.0-or-later WITH GCC-exception-3.1); modified for PolarFire SoC.
#
# link-zcx.spec -- the link spec of the embedded profile of the runtime mpfs_rts (zero-cost
# exceptions, master plan #41 work package P1.7, R8). gen_runtime.sh puts it into the variant in
# place of the link-zcx.spec of the pack, which is the one of bb-runtimes v15.1.0-1
# (riscv/link-zcx.spec): there "-u _Unwind_Find_FDE --eh-frame-hdr" makes the unwinder of the
# bare-board runtimes (unwind-dw2-fde-bb.c) find the frame descriptions through .eh_frame_hdr, but
# the linker of this toolchain (binutils 2.46.1) does not know --eh-frame-hdr, so the link
# fails with "unrecognized option".
#
# Here the frame descriptions are registered at run time, as in a hosted program:
#
#   crti.o crtbegin.o ... crtend.o crtn.o
#       crtbegin.o brings frame_dummy, an entry of .init_array that calls __register_frame_info
#       (__EH_FRAME_BEGIN__, an object) if that symbol is linked in; start.S runs the entries
#       before main. crtend.o ends the list of frame descriptions with a zero word. The linker
#       script (ld/sections.ld) puts crtbegin.o's empty .eh_frame first, brackets the section
#       with __eh_frame_start and __eh_frame_end, and keeps .init_array and .fini_array.
#   -u __register_frame_info
#       links unwind-dw2-fde.o of libgcc (the registration-based _Unwind_Find_FDE: the bb unwinder
#       is not in libgnat.a, mpfs/remove.list) for the weak reference of frame_dummy.
#
# The libraries are those of runtime.xml (-lgnarl -lgnat -lc -lgcc); libgcc's unwind-dw2.o and
# unwind-dw2-fde.o come from there.

*startfile:
crti.o%s crtbegin.o%s

*endfile:
-u __register_frame_info crtend.o%s crtn.o%s
