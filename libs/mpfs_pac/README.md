# `libs/mpfs_pac/`

- **Purpose:** Register package `MPFS_Registers` (PAC), generated from the merged SVD. Library project `mpfs_pac.gpr`.
- **License:** CC-BY-4.0 (generated sources, derived from the SVD); Apache-2.0 (project file and hand-written sources in `src/`)

| Path | Content |
|---|---|
| `mpfs_pac.gpr` | Library project. `src/generated` is compiled without `-gnatwe`, every hand-written source in `src/` with `-gnatwa -gnatwe -gnaty`. |
| `src/generated/` | Output of `./x pac generate`, never edited by hand. Every file carries the generated notice, the SHA-256 of the SVD and the attribution. |
| `src/mpfs_registers-bases.ads` | Hand-written: the distance between the `_LO` and the `_HI` base address of a peripheral. `./x pac check` verifies it against the SVD. |

## Generation

`./x pac generate` takes the merged SVD (`build/svd/PolarfireSoC.svd`, rebuilt if its hash is not the recorded one) and

1. runs svd2ada, built from the commit pinned in `tools/toolchain.env` (`./x toolchain install pac` installs it together with everything else the generation and `./x pac check` need), with `-p MPFS_Registers --boolean --gen-uint-always --no-uint-subtypes`;
2. checks that every group of peripherals with the same `<groupName>` in the SVD (CAN, GPIO, H2FINT, I2C, MMUART, MSRTC, MSTIMER, SPI and WDOG: the `_LO`/`_HI` instances and their siblings) came out as one package (`MPFS_Registers.MMUART` with `MMUART0_LO_Periph`, ...) with one shared type (`MMUART_Peripheral`) and one instance per member. svd2ada does the sharing itself: the base instance of a group in `svd/base/` carries `groupName`, the other instances are `derivedFrom` it. If the registers of the members differ, svd2ada silently keeps one type per layout; the check aborts then;
3. adds `Volatile, Async_Readers, Async_Writers, Effective_Writes` to every `*_Periph` instance, and `Effective_Reads => True` to every instance of a peripheral that has a `<readAction>` (`clear`, `set`, `modify` or `modifyExternal`) on a field in the SVD, also through `derivedFrom`: MMUART (RBR), SPI (RX_DATA), I2C (DATA), QSPI, CAN (RX buffers), USB, MMC (SRS08), PLIC (claim) and the system controller mailbox (SCB_REGS.MESSAGE). The set comes from the SVD (`svd/patches/*.yaml`, `svd/additions/plic.yaml`); the generation aborts if such a peripheral has no instance in the output or the SVD has no `readAction` at all;
4. removes `with System;` where it is not used and adds the header.

svd2ada gives two registers of the same name prefix but different size one Ada type. The pinned commit still does that, but this SVD has no such registers; the generation aborts if one appears.

`./x pac check` regenerates into a temporary directory, fails on any difference from `src/generated`, checks the base addresses and compiles the package with `-gnatc` for the E51 (`rv64imac_zicsr_zifencei`, `lp64`) and the U54 (`rv64imafdc_zicsr_zifencei`, `lp64d`).

The generator is in `tools/pac.sh` and `tools/pac_gen.py`; its tests are `tests/host/pac/run.sh`.
