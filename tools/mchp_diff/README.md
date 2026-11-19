# `tools/mchp_diff/`

- **Purpose:** The differential test of the reader of the MSS Configurator XML (`config/gen/mpfs_gen/xml_reader.py`) against Microchip's configuration generator.
- **License:** Apache-2.0. Microchip's generator (MIT) is not part of the repository: it is fetched at run time and used as a test oracle only; nothing of it is taken over.

| File | Content |
|---|---|
| `exceptions.yaml` | The differences that the test admits, each with the define, the XML, whose defect it is (`ours` or `microchip`) and the reason. Empty. |
| `mchp_diff.py` | The test: fetches the generator, runs it on each XML, compares its defines with the reader. |
| `oracle.env` | The pin of the generator: the repository, the commit and its date, the path of the script and its SHA-256. |

```sh
python3 -I tools/mchp_diff/mchp_diff.py                 # every config/boards/*/*.xml, the differences only
python3 -I tools/mchp_diff/mchp_diff.py --all FILE.xml  # one XML, every define
```

## The oracle

Microchip's HAL turns the XML into C headers with `soc_config_generator/mpfs_configuration_generator.py` of
[polarfire-soc/platform](https://github.com/polarfire-soc/platform). `oracle.env` pins tag 2026.08 (commit
`8d52d59`, 2026-08-26; the script calls itself version 0.6.4). The test fetches that one commit, and of it only
the directory of the script, into `build/mchp_diff/platform-<commit>` (outside the tracked tree, `--cache` for
another place), and checks the commit and the SHA-256 of the script on every run; a changed or other clone is
refused, not used. The generator needs nothing beyond the Python standard library.

It runs as untrusted code: `python3 -I SCRIPT XML OUT` with the XML copied alone into a temporary directory
and the output written to another one. Given the path of a file, the generator lists that file's directory and
takes the newest `.xml` in it, so the copy must be alone; it ends with status 0 also where it gives up, so the
test takes the run as done only if `fpga_design_config/fpga_design_config.h`, the header it writes last, is
there.

## The comparison

The generator writes a header per section, a `#define LIBERO_SETTING_<prefix><register> <value>` per register
(the RW fields shifted to their offsets and added, the rule that the reader follows), and the memory elements
(`LIBERO_SETTING_<name>` and `<name>_SIZE`, the text of the XML) and the design information in
`fpga_design_config.h`. The prefix tells apart registers of the same name: `MSS_` for `mss_sys`, `mss_pll` and
`mss_cfm`, `SGMII_` for `sgmii_pll` and `sgmii_cfm`, `DDR_` for `ddr_pll`, `HART<n>_` for `pmp_h<n>`,
`<MASTER>_` for `mpu_<master>`; the alternative IO set has `ALT_` in the register names of the XML already.
`HEADERS` in `mchp_diff.py` maps each header to its section and prefix. The decimal sections (`clocks`,
`nvm_map`) come out as decimal literals, the others as hex literals with `UL` or `ULL`; the test reads every
value as a C literal.

Each define falls into one class, and every register and memory element of the reader must have a define:

| Class | Meaning | Fails |
|---|---|---|
| compared | a register of the reader's model, a memory element (address or size), a field of the design information; agrees or differs | if it differs |
| outside the model | a section that the reader only validates (`hsio`, `sgmii_pll`, `ddr_pll`, the rest of `mss_ddr`) | no |
| the generator's own | `HEADER_GENERATOR_VERSION` and its three parts | no |
| unmapped | an unknown header, a name without the prefix of its header, a register the section does not have, a value that is not a C literal, a define given twice (each is guarded by `#if !defined`, so C keeps the first) | yes |
| missing | a register or memory element of the reader that no define gives | yes |

A failing row fails the run (status 1) unless `exceptions.yaml` admits it. An entry needs exactly the keys
`define`, `xml` (the path in the repository), `defect` (`ours` or `microchip`) and a `reason` that is not empty;
an entry that admits nothing of the XMLs run is refused (status 2), so the list cannot keep a stale entry. A
defect of ours is fixed in the reader; a defect of Microchip's generator is explained in the entry, not copied
into the reader.

## Results

At the pinned commit, every overlapping value of the three reference XMLs agrees, and the exception list is
empty (the run of `tests/host/mchp_diff`):

| XML | Defines | Compared (agree) | Outside the model | Generator's own | Unmapped, missing |
|---|---|---|---|---|---|
| `icicle` | 876 | 348 (348) | 524 | 4 | 0, 0 |
| `icicle_es` | 811 | 348 (348) | 459 | 4 | 0, 0 |
| `video_kit` | 876 | 348 (348) | 524 | 4 | 0, 0 |

The 348 are the 314 registers of the core sections, 13 memory elements with address and size, the five strings
of the design information and the three parts of the format version. `PLL_PHADJ` of the MSS PLL agrees at
`0x4003`: the reader takes Microchip's sum there on purpose (the known defect of the configurator,
`config/README.md`).

A new format version of the XML enters the allowlist of the reader only with a reference XML and a green run of
this test (`tests/host/mchp_diff`, run in CI by the `svd` job of `registers.yml`).
