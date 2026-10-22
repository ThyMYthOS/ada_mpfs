# `libs/mpfs_pac/`

- **Purpose:** Register package `MPFS_Registers` (PAC), generated from the merged SVD. Library project `mpfs_pac.gpr`.
- **License:** CC-BY-4.0 (generated sources, derived from the SVD); Apache-2.0 (project file and hand-written sources in `src/`)

| Path | Content |
|---|---|
| `mpfs_pac.gpr` | Library project. `src/generated` is compiled without `-gnatwe`, every hand-written source in `src/` with `-gnatwa -gnatwe -gnaty`. |
| `src/generated/` | Output of `./x pac generate`, never edited by hand and **not committed** (`.gitignore`). Every file carries the generated notice, the SHA-256 of the SVD, the svd2ada commit and the attribution. `./x test lib`, `./x analyze` and `./x pac ensure` generate it when it is missing or does not have the recorded hash. |
| `MPFS_Registers.sha256` | The SHA-256 of the generated package (`tools/pac_gen.py hash`: the `*.ads` files in name order), the counterpart of `svd/PolarfireSoC.sha256`. It changes with the SVD, with svd2ada and with the post-processing; `./x pac generate` rewrites it and the commit that changes the SVD commits it. |
| `src/mpfs_registers-bases.ads` | Hand-written: the distance between the `_LO` and the `_HI` base address of a peripheral. `./x pac check` verifies it against the SVD. |

## Generation

`./x pac generate` takes the merged SVD (`build/svd/PolarfireSoC.svd`, rebuilt if its hash is not the recorded one) and

1. runs svd2ada, built from the commit pinned in `tools/toolchain.env` (`./x toolchain install pac` installs it together with everything else the generation and `./x pac check` need), with `-p MPFS_Registers --boolean --gen-uint-always --no-uint-subtypes`;
2. checks that every group of peripherals with the same `<groupName>` in the SVD (CAN, GPIO, H2FINT, I2C, MMUART, MSRTC, MSTIMER, SPI and WDOG: the `_LO`/`_HI` instances and their siblings) came out as one package (`MPFS_Registers.MMUART` with `MMUART0_LO_Periph`, ...) with one shared type (`MMUART_Peripheral`) and one instance per member. svd2ada does the sharing itself: the base instance of a group in `svd/base/` carries `groupName`, the other instances are `derivedFrom` it. If the registers of the members differ, svd2ada silently keeps one type per layout; the check aborts then;
3. adds the SPARK aspects `Volatile, Async_Readers, Async_Writers, Effective_Writes` (see below) to every `*_Periph` instance, and `Effective_Reads => True` to every instance of a peripheral that has a `<readAction>` (`clear`, `set`, `modify` or `modifyExternal`) on a field in the SVD, also through `derivedFrom`: MMUART (RBR), SPI (RX_DATA), I2C (DATA), QSPI, CAN (RX buffers), USB, MMC (SRS08), PLIC (claim) and the system controller mailbox (SCB_REGS.MESSAGE). The set comes from the SVD (`svd/patches/*.yaml`, `svd/additions/plic.yaml`); the generation aborts if such a peripheral has no instance in the output or the SVD has no `readAction` at all;
4. removes `with System;` where it is not used and adds the header.

svd2ada gives two registers of the same name prefix but different size one Ada type. The pinned commit still does that, but this SVD has no such registers; the generation aborts if one appears.

`./x pac check` regenerates into a temporary directory, fails if the hash of the result is not the one in `MPFS_Registers.sha256` (it shows the differences from a `src/generated` that is there), checks the base addresses and compiles the package with `-gnatc` for the E51 (`rv64imac_zicsr_zifencei`, `lp64`) and the U54 (`rv64imafdc_zicsr_zifencei`, `lp64d`).

The generator is in `tools/pac.sh` and `tools/pac_gen.py`; its tests are `tests/host/pac/run.sh`.

## SPARK aspects of the register instances

Every `*_Periph` instance in `src/generated` is external state in the sense of SPARK: the hardware changes it or reacts to it without the program doing anything. The aspects tell the proof tools which accesses to the registers matter, so that they neither flag a register write as useless nor assume that two reads of a register return the same value.

Definitions: [SPARK Reference Manual](https://docs.adacore.com/spark2014-docs/html/lrm/), chapter 7 (version 28.0w when this was written):

- [7.1.2 External State](https://docs.adacore.com/spark2014-docs/html/lrm/packages.html#external-state): the four properties, their defaults and the combinations that are allowed;
- [7.1.3 External State - Variables and Types](https://docs.adacore.com/spark2014-docs/html/lrm/packages.html#external-state-variables-and-types): the Boolean aspects on a variable and where reading and writing such a variable is allowed;
- `Volatile` is the Ada aspect, [Ada Reference Manual C.6 Shared Variable Control](https://www.ada-auth.org/standards/22rm/html/RM-C-6.html).

| Aspect | Meaning | Why the register instances have it |
|---|---|---|
| `Volatile` | The object can be read or written by something outside the program. Each access is a real access: the compiler may not remove, merge or reorder it, and SPARK treats the object as external state, which it handles differently from an ordinary variable. | Every register is memory-mapped hardware. |
| `Async_Readers` | A component outside the program (a device, another processor or task) might read or consume a value written to the object. Every update is considered to be read by some external reader, so a write is never useless, even if the program never reads the value back. (7.1.2) | The hardware acts on what is written: a control register, a data register, an interrupt enable. |
| `Async_Writers` | A component outside the program might update the value of the object. Each successive read might return a different value, so a read is an input to the program. (7.1.2) | Status, FIFO, counter and interrupt registers change by themselves. |
| `Effective_Writes` | Every update of the object is significant: every value written matters, for example a sequence of values written to a port, so no write may be dropped as redundant. (7.1.2) | A write to a register can start something (a command, a clear or a trigger), so a repeated write is not the same as one write. |
| `Effective_Reads` | Every read of the object is significant: the value read is used in determining how the next value is processed, as with a value read from a port. A read changes the state of the hardware, for example it removes a byte from a FIFO or clears a flag, so it cannot be dropped and reading twice is not reading once. SPARK counts such a read as an update of the object: only a function with side effects can read the object, a nonvolatile or volatile function cannot. (7.1.2, 7.1.3) | Only the registers with a read side effect, which the SVD names with `<readAction>`: the instances listed in step 3 of the generation. |

Two rules of 7.1.2 explain why the generator lists the aspects one by one. If an external state is declared without any property, all the properties default to `True`, `Effective_Reads` included. If any property is given, the ones not given default to `False`. The generated instances give `Async_Readers`, `Async_Writers` and `Effective_Writes` (and `Effective_Reads` where it applies), so `Effective_Reads` is `False` everywhere else. The combinations stay valid: `Effective_Reads` needs `Async_Writers` and `Effective_Writes` needs `Async_Readers`.

`Volatile`, `Async_Readers`, `Async_Writers` and `Effective_Writes` are on every instance, because the SVD does not tell which registers the hardware writes or acts on, so the generator assumes the worst case for all of them. `Effective_Reads` is only on the instances that have a side effect on reading; that is why the SVD records the `<readAction>` and the generator takes the aspect from it.
