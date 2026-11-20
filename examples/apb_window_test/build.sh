#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Build hook of ./x build: see examples/common/bare_build.sh.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=examples/common/bare_build.sh
. ../common/bare_build.sh
bare_build apb_window_test start pmp_mask pmp_regs pmp_try bare_console pmp_csr test_report apb_window_test
