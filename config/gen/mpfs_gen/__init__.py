# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The configuration generator: from a system description (system.yaml) and the MSS Configurator XML of the
board to the data of the partitions.

  target       the facts of the chip and the defaults of the runtime, shared with standalone.py
  model        the immutable data classes of a system description and of an MSS Configurator XML
  checks       the error codes GEN-Exxx and the rules that the JSON schema cannot express
  yaml_reader  system.yaml: YAML, the schema config/gen/schema/system.schema.json, defaults, normalisation
  xml_reader   the MSS Configurator XML: format versions, the core sections, widths against the SVD
  presets      the system description of each runtime variant that ./x build builds without one

`python3 config/gen/mpfs_gen check FILE...` validates system descriptions, `python3 config/gen/mpfs_gen xml
FILE...` reads MSS Configurator XMLs (config/README.md).
The package uses the shared generator library tools/gen_ada, which it puts on the module path.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
_TOOLS = str(ROOT / "tools")
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
