#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Build hook of ./x build: see examples/common/bare_build.sh.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=examples/common/bare_build.sh
. ../common/bare_build.sh
bare_build pmp_probe start pmp_mask bare_console pmp_probe
