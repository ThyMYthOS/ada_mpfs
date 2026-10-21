/*
 * SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
 * SPDX-License-Identifier: GPL-3.0-or-later WITH GCC-exception-3.1
 *
 * app-sections.ld -- the hook of the application, included at the end of the SECTIONS of every
 * placement (sections.ld). Empty on purpose. An application that needs sections of its own ships
 * a file of this name and puts its -L ahead of the runtime's (MPFS_APP_LD of mpfs_link.gpr).
 * The region names of sections.ld (REGION_TEXT, REGION_RAM, REGION_FAST_TEXT, ...) are visible.
 */
