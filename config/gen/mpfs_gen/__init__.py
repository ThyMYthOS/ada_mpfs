# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The configuration generator: from a system description (system.yaml) to the data of the partitions.

  target       the facts of the chip and the defaults of the runtime, shared with standalone.py

The package uses the shared generator library tools/gen_ada, which it puts on the module path.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
_TOOLS = str(ROOT / "tools")
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
