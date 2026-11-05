# `crates/mpfs_rts/`

- **Purpose:** Runtime `mpfs_rts`; `kernel/` holds the M-mode kernel (TSF).
- **Owning phase:** P1
- **License:** the runtime sources and the packs made of them GPL-3.0-or-later WITH GCC-exception-3.1; the scripts of this directory are project code, Apache-2.0

| Path | Content |
|---|---|
| `packs.sha256` | The hashes of the six runtime packs, one line `<sha256>  <profile>-<hart>.tar` each: the SHA-256 of the uncompressed tar stream. Committed; the packs are not. |
| `build/rts/packs/<profile>-<hart>.tar.zst` | The six runtime packs (profile `light`, `light-tasking` or `embedded`; hart class `e51` or `u54`), generated, not committed (`build/` is git-ignored). Each is the source text of one runtime made by `crates/bb-runtimes/build_rts.py`: `gnat/`, `gnarl/`, `runtime.xml`, the project files, `COPYING3`, `COPYING.RUNTIME`; no objects. |
| `make_packs.sh` | `--ensure` (re)generates the packs in `build/rts/packs` that are missing or do not match `packs.sha256`; `--check` regenerates all six into a temporary directory and fails unless every hash equals `packs.sha256`; `--update` regenerates and writes `packs.sha256`. `--out DIR` and `--hashes FILE` name other locations. Exit status 0 ok, 1 difference (`--check`), 2 set-up error. Needs GNU tar, zstd, python3 and sha256sum. |
| `compare_toolchain.sh` | Compares `gnat/` and `gnarl/` of the packs (after `make_packs.sh --ensure`, or `--packs DIR`) with the runtimes shipped with the pinned `gnat_riscv64_elf` (`light-polarfiresoc` and so on, `light-rv64imac`): everything that is not a port unit must be identical. |
| `gen_runtime.sh` | `gen_runtime.sh <profile> <hart> <cpus> <priv>` builds one variant of the runtime into `build/rts/<profile>-<hart>-cpus<n>-<priv>/` (see below). |
| `gen_intnam.py` | `gen_intnam.py [--check]` writes `mpfs/gnarl/a-intnam.ads` (`Ada.Interrupts.Names`) from the merged SVD and `svd/additions/local_interrupts.yaml`; `--check` (CI) fails unless the committed file is what the generator makes. See "Interrupt names". |
| `mpfs_rts.gpr` | Abstract project: `Runtime_Path` and `Target` from the scenario variables `MPFS_PROFILE`, `MPFS_HART`, `MPFS_CPUS`, `MPFS_PRIV` (and `MPFS_RTS_ROOT` for the root of the variants). |
| `mpfs/` | Own port units, laid over the pack by `gen_runtime.sh` (`gnat/`, `gnarl/` below it): `gnat/start.S`, `gnat/s-bbbopa.ads`, `gnat/s-textio.ad[sb]` (the console, see below), `gnarl/s-bbripl.ad[sb]`, `gnarl/s-bbsuti.adb`, `gnarl/s-bbhart.ad[sb]` and `gnarl/s-bbricl.ad[sb]`, `gnarl/context_switch.S` and `gnat/riscv_def.h`, `gnarl/s-bbbosu.adb`. `mpfs/remove.list` names the files of the pack that an own unit replaces under another name (`gnat/start-ram.S`) or that must stay out of the library (`embedded: gnat/unwind-dw2-fde-bb.c`: a line `<profile>: <path>` applies to that profile's pack only). |

| `overlays/<name>/` | Overlays, laid over the pack after the port units (`gnat/`, `gnarl/`, `ld/` below each, and `<profile>/gnat`, `<profile>/gnarl`, `<profile>/ld` for that profile only). `overlays/tlsf/embedded/gnat/` is the heap of the embedded profile (see "Heap and secondary stack"). |
| `ld/` | The linker scripts (P1.3): `mpfs-memory.ld`, `place-lim.ld`, `place-scratchpad.ld`, `place-envm.ld`, `sections.ld` (the shared `SECTIONS`) and `app-sections.ld` (the empty hook of the application). `gen_runtime.sh` puts them into `ld/` of every variant. |
| `mpfs_link.gpr` | Abstract project with the link switches of an image: the placement script of the variant and the partition data as `--defsym` values (scenario variables `MPFS_PLACEMENT`, `MPFS_BOOT_ROLE`, `MPFS_HARTS`, `MPFS_APP_LD`, `MPFS_STACK_SIZE`, `MPFS_INTERRUPT_STACK_SIZE`, `MPFS_CONSOLE`, `MPFS_CONSOLE_INIT`), for the examples and tests until the partition generator writes the values. |
| `link-zcx.spec` | The link spec of the `embedded` profile (P1.7, R8): `crti.o crtbegin.o` before and `-u __register_frame_info crtend.o crtn.o` after the link, no `--eh-frame-hdr`. `gen_runtime.sh` puts it into the embedded variants in place of the spec of the pack (see "Zero-cost exceptions"). |
| `port_units.list` | The board files that may differ from the toolchain's runtimes, with their source in `crates/bb-runtimes`. |

## Packs and their hashes

The same pattern as the SVD (`svd/PolarfireSoC.sha256`, `tools/svd.py ensure`): the generated artifact is
not in the repository, its hash is, and whoever needs the artifact calls `make_packs.sh --ensure`,
which regenerates what is missing or stale. A change to `crates/bb-runtimes` is committed together with
the new `packs.sha256` (`make_packs.sh --update`); `make_packs.sh --check` (CI, host suite
`tests/host/rts_packs`) fails if the two disagree.

`make_packs.sh` runs `build_rts.py --hart <hart> --profiles <profile> mpfs` per cell, renames
`<profile>-mpfs` to `<profile>-<hart>` and packs it with GNU tar: entries sorted by name, time stamp
2026-01-01 00:00:00 UTC, owner 0:0 (numeric), modes 755 and 644, GNU format (no extended headers), then
`zstd -19 --single-thread`. The stream does not depend on the umask, the time zone, the working
directory, the order in which the file system lists a directory or the time stamps of the checkout.

**Only the tar stream is hashed, not the `.tar.zst`.** The bytes zstd produces depend on its release
(1.5.5 and 1.5.7 write different files for the same stream), so the compression is a cache format that
saves space and time; its bytes are never compared. `zstd -dc build/rts/packs/light-u54.tar.zst | sha256sum`
is the hash of that line in `packs.sha256`.

## Comparison with the toolchain

The common sources of the fork must be the ones of the compiler (GNAT 15.3.1, `tools/toolchain.env`),
or the runtime and the compiler disagree. The runtimes shipped with the toolchain are generated from
the same bb-runtimes tag, so the comparison needs no network:

| Pack | Compared with | Allowed to differ |
|---|---|---|
| `<profile>-u54` | `<profile>-polarfiresoc` | port units |
| `light-e51` | `light-rv64imac` (no FPU, generic board) | port units |
| `light-tasking-e51`, `embedded-e51` | `<profile>-polarfiresoc` | port units and the sources that depend on the FPU (`s-dorepr.adb`, `s-lidosq.adb`, `s-lisisq.adb`: where `light-rv64imac` and `light-rv64imafdc` differ), which must be those of `light-rv64imac` |

A difference outside the list fails; on a deviation prefer the source from the toolchain.

## Variant build

`gen_runtime.sh <profile> <hart> <cpus> <priv>` (profile `light`, `light-tasking` or `embedded`; hart `e51` or `u54`; cpus `1`; priv `m`:
SMP is P8 and U mode P7, so other values are refused) does this:

1. gets the pack with `make_packs.sh --ensure --cells <profile>-<hart>` (`build/rts/packs/<profile>-<hart>.tar.zst`, generated only if it is missing, unreadable or does not have its hash in `packs.sha256`; about 20 s then, nothing otherwise) and unpacks it into a work directory next to the result;
2. deletes the files that `mpfs/remove.list` names, lays the own port units (`mpfs/`) and then the overlays (`overlays/<name>/`, in the order of their names) over the pack: `gnat/*` and `gnarl/*` replace or add sources, `ld/*` goes to `ld/` (and `<overlay>/<profile>/gnat`, `gnarl` and `ld` the same for that profile only: the heap is the overlay of the embedded profile); then the register packages the port units use (`MPFS_Registers`, `MPFS_Registers.PLIC` and `MPFS_Registers.CLINT` of `libs/mpfs_pac/src/generated`, byte for byte: an application that compiles the PAC itself has the same units, and the binder compares their checksums) go to `gnat/`: they are compiled into `libgnat.a` and are in `adainclude/`, and the PAC is their only source. The PAC is not committed, only its hash (`libs/mpfs_pac/MPFS_Registers.sha256`), like the packs: unless `--pac-dir DIR` names a directory, which is then used as it is and never generated, `gen_runtime.sh` first runs `tools/pac.sh ensure` (what `./x pac ensure` does: nothing if `libs/mpfs_pac/src/generated` has the recorded hash, otherwise a generation with the pinned svd2ada, `./x toolchain install pac`; `--check` does not generate: a missing package is "not up to date"). The pack compiles with `-gnatg`, whose style check rejects the 90-character header line of the generated files, so `gen_runtime.sh` adds `-gnatyM120` (line length 120, the other style checks stay) to the `ADAFLAGS` of the pack's `target_options.gpr`; then the linker scripts of `ld/` of this crate go to `ld/` of the variant;
3. builds `libgnat.a` with `runtime_build.gpr` and, except for `light`, `libgnarl.a` with `ravenscar_build.gpr`: ordinary static library projects, `-XBUILD=Production` (`MPFS_RTS_BUILD=Debug|Assert` for the other build modes of the pack's `target_options.gpr`); the `-march` and `-mabi` of the hart class come from `runtime.xml`, `-mcmodel=medany` is the spec default of the toolchain;
4. leaves `adainclude/` (all sources), `adalib/` (`.ali` files, `libgnat.a`, `libgnarl.a`), `ld/` (the `-L` directory of the link, which the pack calls `ld_user`: the linker scripts of this crate; the partition data brings the `--defsym` values), `runtime.xml`, the license texts and the stamp `.mpfs_rts.stamp`.

The result moves into place in one step, so an aborted build leaves no half variant. The **cache key** in the stamp is the sha256 of the pack (the SHA-256 of its uncompressed tar stream, the hash that `packs.sha256` records: the compressed bytes depend on the zstd release and are not used; if the sources of the fork changed and `packs.sha256` is stale, `--ensure` warns and the key follows the pack that was really generated), the three register packages of the PAC (their content, so the key follows the files that are copied; the recorded hash of the whole PAC would also change with the packages the runtime does not use), the port units, the overlays, the switches (variant, build mode, the script itself) and the toolchain (the name of the installed GNAT directory, which carries the Alire version and a hash, and the versions that `gcc` and `gprbuild` report). A variant whose stamp has the same key and whose files are there is reused: `./x build tasking_test -P light-tasking --hart e51` runs the script every time and the second run prints `gen_runtime: light-tasking-e51-cpus1-m is up to date (key ...)` after 0.1 s instead of building for about 15 s. `--check` only reports (exit 1: it would build), `--force` rebuilds. `./x clean --rts` removes `build/rts`.

An application selects the variant with `mpfs_rts.gpr`:

    with "../../crates/mpfs_rts/mpfs_rts.gpr";
    project App is
       for Target use Mpfs_Rts.Target;
       for Runtime ("Ada") use Mpfs_Rts.Runtime_Path;

`./x build` does that for an example whose `example.conf` has `RUNTIME=mpfs_rts` (`PROFILE=` is the profile for `-P auto`): it sets the four variables (`MPFS_CPUS` is the number of harts of `--harts`, 1 without), calls `gen_runtime.sh` and then `gprbuild`. `examples/tasking_test` is the minimal example for this (a periodic task and an environment task, no output); the real test of P1.13 replaces it.

Reproducibility: the switches are not recorded in the debug info (`-gno-record-gcc-switches`) and the paths of the sources are mapped to `./build/rts/<variant>/adainclude` (relative to the repository root, like `ADA_MPFS_SDK` for the examples), so an image linked with a variant does not depend on the directory of the checkout; `./x repro` covers `tasking_test`.

Known limit of this step: the build mode `Production` keeps the `-gnatp` of the pack's `target_options.gpr` (the plan wants no `-gnatp` outside the TSF: that is a change of the fork, not of the build).

## Start code and linker base

`mpfs/gnat/start.S` replaces the upstream `start-ram.S` (which hard-wires hart 1) in `libgnat.a`; `ld/` holds the linker base. An image links with the variant's `ld/` through `mpfs_link.gpr` (`-T place-<placement>.ld`, `-Wl,-u,_start` and the partition data).

Start, in this order:
1. `mtvec` to the trap stub, `gp` and `sp`
2. `mstatus.MIE` and `mie` cleared
3. hart gate; `.data` copied from `__data_load` if that differs from `__data_start`
4. `.bss` cleared
5. `mstatus.FS` (U54 images)
6. the constructor arrays (`.preinit_array`, then `.init_array`, called in order with no arguments)
7. `main`
8. then `__gnat_exit`, which resets the MSS on a primary image and halts on a secondary one. A hart whose bit is clear in `__mpfs_harts_mask` is parked in `wfi`; on a primary image with `mie.MSIE` set (prepared for the release of P8), on a secondary image without it.

**Deliberate deviation (hart gate):** foreign harts are parked on every image, also on a secondary one. Step 1.3 of the work package (#44) and the reference runtime gate on the primary image only. But QEMU's reset code sends every hart to the entry point and has no hart gate of its own, so an ungated secondary image would run on all harts; on hardware only the release of the right hart reaches it and the gate costs nothing. The cost: a foreign hart reaching a secondary image has its `mtvec`, `mie` and `mstatus.MIE` written, as every hart does before the gate.

**Memory initialisation:** the LIM is ECC memory that is uninitialised at power-up, so every store of the start code and of the trap stub is a whole 64-bit word (the trap record is written with 64-bit stores only), and `start.S` clears `.bss`, the interrupt stacks and the stack of the environment task (a partial store into a never-written word is a read-modify-write of garbage; on hardware it would show as an ECC fault). `.noinit` and the heap are deliberately not cleared: whether the LIM needs zeroing as a whole is a hardware question (see "Heap and secondary stack"; the Icicle Kit runs answer it).

The trap stub handles every trap until the runtime installs its own handler. It uses no stack and no `gp`, writes `mcause`, `mepc`, `mtval` (64 bit each), the magic `0x54524150` and `mhartid` (32 bit each) to the 32 bytes at `__mpfs_trap_record`, which are the last 32 bytes of the RAM region of the placement (the same place for a given partition, whatever the image; the heap stops in front of them), and halts. An image that defines `__mpfs_early_trap_hook` gets control there instead of the halt, with the address of the record in `a0`: a test seam for `examples/trap_test`, not for the runtime.

| Placement | Code and read-only data | `.data` (VMA / LMA) | `.bss`, stacks, heap, trap record | For |
|---|---|---|---|---|
| `place-lim.ld` | `l2lim` | `l2lim` / `l2lim` | `l2lim` | the first boot: no L2 or DDR set-up |
| `place-scratchpad.ld` | `scratchpad` | `scratchpad` / `scratchpad` (the boot stage loads it) | `scratchpad` | scratchpad ways; no scratchpad in QEMU: build-only there |
| `place-envm.ld` | `envm` | `l2lim` / `envm` (start.S copies) | `l2lim` | the bootloader only |

`sections.ld` is the shared `SECTIONS`; a placement binds the region names `REGION_TEXT`, `REGION_DATA`, `REGION_DATA_LOAD`, `REGION_RAM`, `REGION_FAST_TEXT`, `REGION_FAST_DATA` and `REGION_FAST_LOAD` to the regions of `mpfs-memory.ld` (literal `ORIGIN`s, `LENGTH`s from `MPFS_*_LENGTH`). Notes:

- The hook `app-sections.ld` is included between the load sections and `.bss`, with the meaning it has in the reference runtime: an application that places code or data of its own ships a file of that name and puts its `-L` ahead of the runtime's (`MPFS_APP_LD` of `mpfs_link.gpr`), and the runtime does not declare sections for what an application chooses. The runtime's own `.fast_text` and `.fast_data` (ITIM and DTIM, with the ASSERT that they stay empty until P1.11) are in conflict with that rule and stay for now; P1.11 decides their final home (the hook, or an application's own sections).
- `.eh_frame` is bracketed by `__eh_frame_start` and `__eh_frame_end` (R8; a zero word follows the range for libgcc); `.preinit_array`, `.init_array` and `.fini_array` are in the region of the code, bracketed by `__preinit_array_start`/`_end`, `__init_array_start`/`_end` and `__fini_array_start`/`_end` (defined, not `PROVIDE`d; `ASSERT`: 8-byte entries, in that order), and `.tm_clone_table` of the crt files is in `.data`. `.fast_text` and `.fast_data` are in the ITIM and DTIM (`local_itim`, `dtim`) with their load address in the placement's load region; nothing copies them before P1.11, so an `ASSERT` requires both to be empty.
- `__gnat_gdb_cpu_first_id` is a 32-bit constant in `.mpfs_gdb`, the lowest hart of `__mpfs_harts_mask`. It replaces the hard-wired 1 of `s-bbbopa.ads` and the `-u __gnat_gdb_cpu_first_id` of the upstream link: nothing refers to the symbol, so the library unit that exports the upstream constant is not linked.
- `ASSERT`s: stack and interrupt stack sizes and the stack addresses are multiples of 16 and the stack is not empty; the interrupt stacks of the runtime fit `__interrupt_stack_size`; `.data` and `.bss` are 8-byte aligned (start.S copies and clears in 8-byte units); the regions of the placement are not empty; `.bss`, the stacks, the heap and the trap record do not overlap and fit; `_start` is the first byte of `.text` and no loadable section lies below it (QEMU's `-kernel` starts every hart at the lowest loaded address, not at `e_entry`); the mask names harts 0 to 4.
- A missing `--defsym` stops the link: `__mpfs_boot_role` with "undefined reference" (only `start.S` reads it), the others with "undefined symbol ... referenced in expression" (the script reads them). There are no defaults. `tests/host/rts_boot` builds the four boot scenarios (primary on the E51 and secondary on U54 hart 2, each in the LIM and in the scratchpad) and the negative builds.

## PLIC and CLINT (P1.4)

Nothing in the runtime names a hart. The id of the executing hart is `mhartid`, read at run time by `System.BB.Hart.Id` (`gnarl/s-bbhart.ad[sb]`); the PLIC context and the timer of that hart follow from it. The old literals are gone: `PLIC_Hart_Id` and `GDB_First_CPU_Id` of `s-bbbopa.ads` (the first CPU id of the debugger is the constant of the linker script, see above) and the `mtimecmp` offset `16#4008#`.

| Unit | Content |
|---|---|
| `s-bbbopa.ads` | `System.BB.Board_Parameters`: the clock (1 MHz `mtime`). The console is not here: see "Console". The bases and the layout of the PLIC and the CLINT are the PAC's (`MPFS_Registers.PLIC_Base`, `.CLINT_Base`), not repeated here. |
| `s-bbripl.ad[sb]` | `System.BB.RISCV_PLIC`: `Context_Of (Hart)` (hart 0 is context 0, hart n is context 2n-1: the E51 has no S mode, every U54 has M and S); enable block, threshold and claim/complete of the context. The registers are the PAC types (`ENABLE_H0_M_Registers`, `THRESHOLD_H0_M_Register`: 32 bits, `Volatile_Full_Access`) at "the address of the registers of context 0 plus context times the distance between context 0 and context 1", taken from the PAC components themselves (`Enable_Address`, `Threshold_Address` and `Claim_Address (Hart)` export them; `examples/interrupt_test` compares them with the named registers `ENABLE_H<n>_M` and so on for all five harts). One 32-bit access per register, loops per word, no aggregate: a 64-bit store to the PLIC is an error of the SoC (and of QEMU). `Initialize` resets only the own context: threshold (7 while it works, then 0), enables, an open claim. It does not clear the priorities (later `mpfs_boot` sets them statically) and does not touch the enables, thresholds or sources of other harts, which in an AMP system are theirs. |
| `s-bbricl.ad[sb]` | `System.BB.RISCV_CLINT`: `Mtime`, `Mtimecmp (Hart)` and `Set_Mtimecmp` (`0x4000 + 8 * Hart`, one 64-bit access), `MSIP (Hart)` and `Clear_MSIP (Hart)` (`4 * Hart`; for P8). |
| `s-bbsuti.adb` | `Board_Support.Time`: `Read_Clock` from `Mtime`, `Set_Alarm` and `Clear_Alarm_Interrupt` write the `mtimecmp` of the executing hart, with one 64-bit store (RV64) instead of the three-word sequence of RV32. The tickless logic is described under "Tick and idle" below. |

`tools/check_plic_stores.py` disassembles objects, libraries or images with the pinned `riscv64-elf-objdump` and fails if it finds a 64-bit store (`sd`, `fsd`, `amo*.d`, `sc.d`) whose base register holds an address of the window `0x0C00_0000` .. `0x1000_0000` of the PLIC: a register is "in the window" after a `lui` into it and stays so through the arithmetic that builds an address (`addi`, `add`, `slli`, `mv`, ...), a load or `csrr` gives an ordinary value, the analysis follows the branches of a function (also the back edge of a loop) and ends at a call (limit: an address that a called function returns is not followed), and stores through `sp` are stack accesses. The real compiler does write `Enables := (others => 0)` for an array of PLIC registers with three `sd`: `tests/host/rts_plic/fixtures/aggregate.adb` is the proof, and the suite `tests/host/rts_plic` runs the check over the six runtime variants and over the images of `interrupt_test` and `tasking_test`, with assembler fixtures that must fail (constant base, base computed from a hart, base set at the end of a loop, atomic, floating-point store, edge of the window) and that must pass.

**QEMU and the harts.** The default of QEMU's `microchip-icicle-kit` has the E51 and one U54 (`-smp 2`; `info cpus` shows `CPU #0 sifive-e51` and `CPU #1 sifive-u54`). An image linked for hart 2 to 4 would be started on a machine without that hart and print nothing. `tests/qemu/run_tests.sh` and `./x qemu` pass `-smp 5`. Its PLIC has the contexts `M, MS, MS, MS, MS` (context 0 is hart 0, context 2n-1 the M mode of hart n) and its CLINT the `mtimecmp` at `0x4000 + 8 * hart`, as the SoC does; both accept 32-bit accesses to the PLIC only.


## Context switch, FPU and trap frame (P1.5)

| Hart class | `-march` / `-mabi` | f registers | Task context (`__gnat_context_switch`) | Trap frame (`__gnat_trap_entry`) |
|---|---|---|---|---|
| E51 | `rv64imac_zicsr_zifencei` / `lp64` (`__riscv_float_abi_soft`) | none | `ra`, `sp`, `s0` - `s11` | 256 bytes: `x1` - `x31` |
| U54 | `rv64imafdc_zicsr_zifencei` / `lp64d` | `f0` - `f31`, `mstatus.FS` set by `start.S` | the same and `fs0` - `fs11` (offsets 112 to 200 of the context) | 512 bytes: `x1` - `x31` and `f0` - `f31` |

**Defect no. 1 (FP context), fixed in `mpfs/gnarl/context_switch.S`.** The upstream fil
(`riscv/src/context_switch.S` of bb-runtimes `v15.1.0-1` @ 09e7cd6) saves
`fs0` - `fs11` to the context of the outgoing task (`t0`, the address that `LREG t0, 0(a0)` read) and then restores them
with `FLREG fs0, 14*REGBYTES(t0)`, again from the outgoing context; the integer registers are restored from `a1`, the
incoming one. So every task that is switched in gets the callee-saved f registers of the task that was switched out. The
overlay loads the twelve registers from `a1`; nothing else of the file changed (`tests/host/rts_context` compares the
two files line by line). The defect is in the upstream release this fork is made from (`v15.1.0-1`), in the
`gnat-fsf-15` and `gnat-fsf-16` branches of alire-project/bb-runtimes (tags `v15.1.0-1` and `v16.1.0-1`) and in the
`context_switch.S` that the GNAT 15.3.1 and 16.1.0 toolchains ship (the disassembly of `libgnarl.a` shows
`fld fs0,112(t0)`); it has been there since the FPU support of 2019-04-29 (`8d277f3`). AdaCore fixed it with `86367b9`
(2026-02-13, "context_switch.S: Fix floating regs restoration on task switch", the same twelve lines) in `master` and
`release/27.x` of AdaCore/bb-runtimes; alire-project/bb-runtimes has it in `master`, but not in `gnat-fsf-15`,
`gnat-fsf-16` or the 25.x and 26.x branches. The overlay therefore stays needed as long as the runtime sources come
from `gnat-fsf-15` or `gnat-fsf-16`, and can go when they contain `86367b9`. This work does not contact anyone.
`examples/fp_context_test` is the regression test:
with the upstream restore all twelve registers of all three of its tasks are lost, with the fix none.

**`fcsr` is not part of the task context (decision of P1.5).** Saving it would cost two instructions for the save and two
for the restore (`csrr`, `sd`; `ld`, `csrw`), one more word in `Context_Buffer`, and an initial value for a new task.
Against that stands what `fcsr` holds:

- the rounding mode `frm`: nothing in the runtime or in the Ada code of this project changes it (the attributes
  `'Rounding`, `'Truncation` and the conversions to integer are done without it, `Float'Image` has no use for it), the
  reset value is round to nearest even, which is what Ada's model of the real types assumes (Ada has no portable way to
  select another mode). Where a program does change it, it is a program-wide setting, and an interrupt handler would
  inherit it from whatever task it interrupted anyway, so a per-task copy would not make the setting task-local;
- the accrued exception flags `fflags`: sticky, not visible to Ada (no `Float_Control`, no `Machine_Overflows` use of
  them), so a switch that leaves them mixed does no harm.

So the context stays at `fs0` - `fs11`, and the trap frame does not save `fcsr` either. If a project needs a task-local
rounding mode (a numerical library with directed rounding), the change is local: `FCSR` words in `Context_Buffer`
(`s-bbcpsp.ads`, an own port unit then) and two instructions on each side in `context_switch.S`.

**Trap frame.** `riscv_def.h` (overlay `mpfs/gnat/riscv_def.h`) gives `FRAME_SIZE` by the ABI: `32 * REGBYTES` when
`__riscv_float_abi_soft` is defined, else `64 * REGBYTES` (32 integer slots, of which the one of `tp` stays empty, and 32 f
slots); `trap_handler.S` and `context_switch.S` name an f register only under `#ifndef __riscv_float_abi_soft`. The
upstream header and trap handler were already right for both classes; the overlay of the header adds assembly-time checks
(a hard-float ABI without `__riscv_flen` and a frame that is not a multiple of 16 do not assemble) and the table above as
a comment, the trap handler is unchanged. The frame of the E51 is 256 bytes, of the U54 512: the interrupt stacks of the
runtime (`__interrupt_stack_size`) hold nested frames of that size.

Known limit: `Context_Buffer` (`s-bbcpsp.ads`, upstream, not an own unit) always has the twelve `FS` words, so on the E51
each task context carries 96 bytes that nothing uses; the assembly code does not touch them. A conditional record would
need an own `s-bbcpsp.ads`, which is not worth 96 bytes per task for the E51 images of P1 (it can be done together with a
per-task `fcsr`).

`tests/host/rts_context` checks all of it on the disassembly of the real objects (the twelve `fsd` and the twelve `fld`, the
frame sizes, the slots, no f instruction on the E51, a control that fails on the upstream file); `examples/fp_context_test`
(U54) and `examples/float_test` (E51 and U54) run under QEMU.

## Tick and idle (P1.6)

There is no periodic tick. `System.BB.Time` (common GNARL code) computes the next alarm of the hart (the earliest delayed task or timing event, `Time'Last` if none) and calls `Board_Support.Time.Set_Alarm`; its alarm handler calls `Clear_Alarm_Interrupt` first and then `Set_Alarm` with the next alarm. `s-bbsuti.adb` implements this on the CLINT:

- **`mtimecmp` of the own hart is the only state.** The machine timer interrupt (`mip.MTIP`) is the level `mtime >= mtimecmp`, an unsigned 64-bit comparison, so writing `mtimecmp` is also the acknowledge. `Clear_Alarm_Interrupt` writes the maximum, `2**64 - 1`, which `mtime` reaches after 584 000 years at 1 MHz; `Time'Last` is the same value, so "no alarm" needs no special case and there is nothing to wrap around. `mtime` is one counter, only read by the runtime, so `Clock` is monotonic.
- **An alarm in the past or now** is not an error: the level holds at once and the interrupt is taken as soon as `mstatus.MIE` allows it (a timing event set in the past, or a `delay until` whose time passes between the clock read and the store; the kernel runs with `MIE` clear there).
- **No spurious tick.** After reset `mtimecmp` is 0 in QEMU and undefined on the SoC, and `Install_Trap_Handler` sets `mie.MTIE`; `Install_Alarm_Handler` therefore disarms (`mtimecmp` := maximum) before it installs the handler. `examples/delay_accuracy_test` checks `mtimecmp` and `mip.MTIP` at the start and after every wake-up; `tests/host/rts_tick` checks the order in the image.
- **One 64-bit access per register access** (RV64): `Mtime` is one `ld`, `Set_Mtimecmp` one `sd` (checked by `tests/host/rts_tick` on the four tasking variants), so a clock read cannot tear and no intermediate value of an `mtimecmp` write can raise or hide an interrupt. (The RV32 code of the upstream unit needs a three-word sequence for this.)
- `Clock_Scale` must be 1 (compile-time check): `Time` is `mtime` ticks.

**Idle.** `s-bbbosu.adb` is the upstream unit with `Power_Down` = `wfi` (the upstream body is `null`: the idle task would poll). `System.Task_Primitives.Operations.Idle` calls it in a loop with `mstatus.MIE` set and the PLIC threshold at 0; the loop has no state, so there is no window between "decide to idle" and `wfi` in which a wake-up could be lost. `wfi` returns when an interrupt that is enabled in `mie` is pending (`MTIE` for the alarm, `MEIE` for the PLIC; `MSIE` is not enabled on a running hart, only on a parked one, see start code), whatever `mstatus.MIE` says; the trap is then taken, the scheduler switches to the task that became ready, and the idle task resumes after the `wfi` when nothing is ready. A `wfi` that returns without a pending interrupt (the architecture allows it) costs one more turn of the loop.

**`Clock_Frequency` = 1 MHz** is `System.BB.Board_Parameters.Clock_Frequency` (`s-bbbopa.ads`: `Decrementer_Frequency` times `Clock_Scale`), the rate of `mtime` (the RTC clock, divided from the reference clock by `RTC_CLOCK_CR.PERIOD`: the reset value 100 gives 1 MHz for a 100 MHz reference clock, a 125 MHz one needs 125, see the SVD). `Ada.Real_Time.Time_Unit` is `1.0 / Clock_Frequency`. The generated partition package (P1.12, #53; in P1 the standalone default, from P2 the XML) has `Clocks.Rtc_Toggle_Hz` and states

    pragma Compile_Time_Error
      (Ada.Real_Time.Time_Unit * Clocks.Rtc_Toggle_Hz /= 1.0, "...");

The package does not exist yet, so the check is exercised with its stand-in `examples/delay_accuracy_test/src/standalone_clocks.ads`: `tests/host/rts_tick` compiles it against the runtime variants with 1 MHz (compiles) and with 2 MHz, 999 999 Hz, 100 MHz and 32 768 Hz (rejected with the message), and against a copy of a variant whose `Clock_Frequency` is 2 MHz (rejected). What only the hardware can show is that `mtime` really runs at that rate (the GDB init sets `RTC_CLOCK_CR`, P1.14 compares `mtime` with `mcycle` and the CFM) and the accuracy of `delay until` (acceptance of #47: at most 2 ticks plus the interrupt latency; `DELAY_ACCURACY=hardware ./x build delay_accuracy_test`). A link-time form of the check (an `ASSERT` on a `--defsym` of the partition data in `ld/`) would be a new mandatory link symbol and is not part of the interface of #41 section 4.2; the compile-time check needs none.
## Console

`System.Text_IO` (`mpfs/gnat/s-textio.adb`, replacing `s-textio__ns16550.adb`) is the console of all three profiles
(`GNAT.IO`, `Ada.Text_IO` of the embedded profile, the last chance handler): polled output and input on one MMUART. Which
MMUART, and whether the runtime sets it up, is link-time data of the partition, four absolute symbols (`--defsym`) that
are not in the library, so one runtime serves every console:

| Symbol | Meaning |
|---|---|
| `__mpfs_console_base` | Base address of the MMUART (`MMUART0_LO_Base` to `MMUART4_LO_Base` of the PAC), or 0 for no console |
| `__mpfs_console_init` | 1: `Initialize` programs the port; 0: the boot stage has done it and `Initialize` only records that the service is ready |
| `__mpfs_console_dlr` | The integer baud rate divisor (16 bits: `DLR`, the low byte, and `DMR`, the high byte, of the divisor latch) |
| `__mpfs_console_dfr` | The fractional divisor in 1/64 (0 to 63); the fractional baud rate mode (`MM0.EFBR`) is on for a value other than 0 |

- **Init 1.** `Initialize` (called by the first output of `GNAT.IO`) writes, in this order: `LCR` with `DLAB` set and 8 data
  bits, the divisor latches, `DFR` and `MM0.EFBR` (the other multi-mode bits stay as they are), `LCR` 8N1 with `DLAB` clear,
  `FCR` (both FIFOs on and emptied, receive trigger one byte). It leaves `IER`, `MCR` and the clock and the reset alone.
- **Init 0.** Nothing is written but the data port; `Get`, `Is_Rx_Ready` and `Is_Tx_Ready` read it and `LSR`.
- **Console none** (`__mpfs_console_base` = 0). `Put` does nothing, `Is_Tx_Ready` is always true, `Is_Rx_Ready` always
  false, `Get` returns NUL; no register is touched, `__mpfs_console_init` or not. The RAM FIFO console is not
  there: it comes with the SMP work.
- **Clock and reset of the MMUART are not the runtime's.** Whatever `__mpfs_console_init` says, the runtime does not
  touch `SYSREG.SUBBLK_CLOCK_CR` or `SOFT_RESET_CR`: releasing the MMUART is the boot stage's task (the GDB script
  in the hardware lab, the init stub, the boot code). An image on a board nobody has released the MMUART for prints
  nothing; `./x hw run --uart-clocks` stands in for that part, `--uart-standin` for the divisor and format as well.
- **How the symbols are read.** The values are read by two instructions each (`lui`, `addi`, as `start.S` reads the
  mask), not through the address of an imported object: the compiler knows that such an address is not null and
  would fold the test for "no console". A missing symbol is an undefined reference in an image that links
  `System.Text_IO`; there are no defaults (`tests/host/rts_boot` leaves each out). An image that does not use the
  console does not need them.
- **16550 offsets.** The registers are the types of the PAC (`MPFS_Registers.MMUART`, which `gen_runtime.sh` copies into
  `adainclude/`), at the 16550 offsets: data port at `+0`, the divisor latches at `+0` and `+4` with `LCR.DLAB`, `FCR` at
  `+8`. The PAC also lists them at `+0x100` (`THR`), `+0x80` and `+0x84` (`DLR`, `DMR`) and `+0x108` (`FCR`), aliases on the
  board; QEMU's model has plain memory from `+0x20` on, so only the 16550 offsets reach the serial port there. The data
  port is written with one 32-bit store of the whole register: a read at `+0` takes a byte out of the receive FIFO.
- **The spec is an own port unit too** (`mpfs/gnat/s-textio.ads`): the pragma of the unit is
  `Restrictions (No_Elaboration_Code)` instead of `No_Elaboration_Code_All`, because the body names the PAC, which has the
  former. The interface is unchanged.

`mpfs_link.gpr` gives an image its console: `MPFS_CONSOLE` (`mmuart0` to `mmuart4`, `none`; default `mmuart0`) and
`MPFS_CONSOLE_INIT` (`1`, `0`) as scenario variables, and the lists `Console_0` to `Console_4`, `Console_None` and
`Console_No_Init` for a project with several images (`examples/textio_test`). The divisor is 22 (115200 baud at the
~40 MHz APB clock of an Icicle Kit at reset, as measured for `--uart-standin`), 21 and 45/64 for MMUART4, which the board does not
bring out and which exercises the fractional mode under QEMU. A partition generator will write these values from the
clock of the configuration.

Tests: `examples/textio_test` (the console of the runtime: registers against the link symbols, `GNAT.IO`, loopback, all
five MMUARTs, init 0), `examples/console_none_test`, and `tests/host/rts_boot` (the symbols in the images, a missing symbol
fails the link).

## Zero-cost exceptions (P1.7, R8)

Only the `embedded` profile propagates exceptions (`light` and `light-tasking` have no propagation). Its unwinder is
the **registration-based unwinder of libgcc** (`unwind-dw2.o` and `unwind-dw2-fde.o` of `libgcc.a`), not the one of
the bare-board runtimes. The design note with the reasons, the evidence and the alternatives is
[`docs/design/exceptions.md`](../../docs/design/exceptions.md); this is the mechanism.

**Why not the upstream way.** The `link-zcx.spec` of bb-runtimes (15 and 16) passes `--eh-frame-hdr`, and its
`unwind-dw2-fde-bb.c` finds the frame descriptions (FDEs) only through the `.eh_frame_hdr` that option makes. The
`riscv64-elf-ld` of this toolchain (binutils 2.46.1 in the pinned GNAT 15.3.1 toolchain, the same in GNAT 16) does not know the option: an
embedded program fails to link with `unrecognized option '--eh-frame-hdr'`
(`tests/host/rts_zcx` pins this premise).

**What is done instead.**

| Where | What |
|---|---|
| `link-zcx.spec` | `*startfile: crti.o crtbegin.o`, `*endfile: -u __register_frame_info crtend.o crtn.o`. `gen_runtime.sh` copies it over the spec of the pack (embedded only; it is part of the cache key; `--spec FILE` names another). `runtime.xml` already links with `--specs=.../link-zcx.spec -nolibc -Wl,--start-group,-lgnarl,-lgnat,-lc,-lgcc,--end-group`. |
| `mpfs/remove.list` | `embedded: gnat/unwind-dw2-fde-bb.c`: the bb unwinder is not compiled into `libgnat.a`, so `_Unwind_Find_FDE` can only come from `libgcc.a(unwind-dw2-fde.o)`, whatever the order of the archives. Listed in `port_units.list`. |
| `ld/sections.ld` | `.eh_frame` with `KEEP` between `__eh_frame_start` and `__eh_frame_end`; `.preinit_array`, `.init_array`, `.fini_array` with `KEEP` and their symbols; `.init` and `.fini`; `ASSERT`s for the 8-byte entries and the alignment of `.eh_frame`. The empty `.eh_frame` of `crtbegin.o` is the first input, so its `__EH_FRAME_BEGIN__` is `__eh_frame_start`, and the zero word of `crtend.o` ends the list. |
| `mpfs/gnat/start.S` | Before `main`, a loop calls the entries of `.preinit_array` and `.init_array` (one run of entries, `ASSERT`ed in the script). `frame_dummy` of `crtbegin.o` is an entry of `.init_array`; it calls `__register_frame_info (__EH_FRAME_BEGIN__, &object)`, which only links the object into libgcc's list (no allocation). The first search (`_Unwind_Find_FDE`, at the first raise) sorts the FDEs with `malloc`; if that fails libgcc searches linearly, so a missing heap costs time and not correctness. |

**Deviation from the work package.** Step 3 of #48 has `start.S` call `__libc_init_array`. The loop does the same
without libc: `light` and `light-tasking` link with `-nolibc`, where a call could not resolve, and a weak call to an
undefined symbol resolves to address 0, out of the reach of `auipc`/`addi` from an image above `0x8000_0000` (DDR). The
loop costs 16 to 32 bytes of code in every image (`metrics.golden`) and calls nothing where the arrays are empty. Step 2 has `-lgcc` first in the
start group; with the bb unwinder removed from the library and `-u __register_frame_info` that is not needed (the group
of the upstream `runtime.xml` stays as it is).

**Costs.** An embedded image links `unwind-dw2.o` (14 KiB code, 0.8 KiB constants) and `unwind-dw2-fde.o` (5.5 KiB) of
libgcc, `crtbegin.o` (158 bytes of code, 56 of `.bss`, 8 of data, two array entries), `.eh_frame` for everything that
is linked (the unwinder's own part is 3.8 KiB; `exceptions_test_u54` has 11.9 KiB in all, of 63 KiB of code and
constants) and the heap allocator (3.6 KiB of code and 6.5 KiB of `.bss` for the TLSF allocator, see "Heap and secondary stack"; newlib's `malloc` was about 4 KiB with its data). The images are in
`metrics.golden`: `exceptions_test` 61.8 KiB (E51) and 63.1 KiB (U54) of `text` (code and constants), `unhandled_test` 48.2 and 49.5 KiB. A search
function of our own (fallback (a) of the work package) would save the 5.5 KiB of `unwind-dw2-fde.o` and the `malloc`; it is not needed to make exceptions work.

**For other work packages.**

- Heap: libgcc calls `malloc` and `free` by name. `MPFS_Heap` of the TLSF heap defines both and newlib's allocator is
  not linked (see "Heap and secondary stack").
- P8 (SMP): `start.S` runs the constructor arrays on every hart that runs the image. `frame_dummy` registers once; a
  second registration of the same object corrupts libgcc's list. Only the first hart of the mask may run them.
- The switch to the v16 runtime sources (#41, section 3a): its `link-zcx.spec` still passes `--eh-frame-hdr`, its start
  code calls `__libc_init_array`. This crate's spec, `remove.list` and `start.S` replace both; `gen_runtime.sh` stops
  with a message if the pack no longer has `gnat/unwind-dw2-fde-bb.c`.
- The unhandled exception ends in `Ada.Exceptions.Last_Chance_Handler`: it prints with `System.IO` and calls
  `System.Machine_Reset.Stop` (MSS reset on a primary image). An application may define `__gnat_last_chance_handler`
  itself (`examples/exceptions_test/src/last_chance.ads`).

## Heap and secondary stack

### Heap

| Profile | `malloc`, `free`, `calloc` | `new` and `Unchecked_Deallocation` |
|---|---|---|
| `light`, `light-tasking` | The bump allocator of `s-memory.o` (upstream): a pointer from `__heap_start` towards `__heap_end`, `free` does nothing. It stays: no fragmentation and no bookkeeping, with an atomic compare-and-exchange of the pointer in `light-tasking`. | `System.Memory.Alloc` of the same file. |
| `embedded` | The TLSF allocator of `overlays/tlsf/embedded/gnat` (below), with `realloc`. Newlib's allocator is not linked. | `System.Memory` of the pack (unchanged) calls `malloc`, `free` and `realloc`; `Storage_Error` ("heap exhausted") when `malloc` returns null. |

The TLSF (two-level segregated fit) allocator is the one of `ada_esp32s3` (`tlsf_core`, `tlsf_math`, `heap_guard`):
allocation and release in constant time, free blocks in lists by a two-level size class with a bitmap for each level
(a fitting list is found with a find-first-set), coalescing with the physical neighbours by boundary tags. The heap is
the memory from `__heap_start` to `__heap_end` of the linker script (what is left of the RAM region after `.bss`, the
stacks and `.noinit`, in front of the 32 bytes of the trap record: about 1.8 MB in the LIM).

| Unit | Content |
|---|---|
| `tlsf_math.ad[sb]` | The size classes and the bit arithmetic (find-last-set, find-first-set, rounding, `Mapping`, `Mapping_Search`), SPARK: the bucket indices are proved to be valid subscripts. `Max_Alloc` is the largest request that is served, 2**32 - 16 bytes: the units were written for a 32-bit target and, with 64-bit sizes, a request of 2**40 bytes would index the tables out of range. |
| `heap_guard.ad[sb]` | The size arithmetic of `malloc`, `realloc` and `calloc`, SPARK: a request is refused or its byte count is exact, so a product that wraps never gives a block that is too small. |
| `tlsf_core.ad[sb]` | The allocator: `Init`, `Allocate`, `Deallocate`, `Reallocate`, `Free_Bytes`, `Invariants_Hold` (a walk of the chain of blocks, for the tests). No lock and no linker symbol. The state has no initial values (`.bss`, which the start code clears) and the body has no elaboration code (`pragma Restrictions (No_Elaboration_Code)`), so the allocator works from the first call, before the units of the program are elaborated. A block has a header of 32 bytes (the physical predecessor, the size, the state) and 16-byte alignment; the state is a 64-bit word because the LIM is ECC memory that is uninitialised at power-up, and a store that is narrower than the word into a word that was never written is a read-modify-write of garbage. |
| `mpfs_heap.ad[sb]` | `malloc`, `free`, `realloc` and `calloc` (`pragma Export`) over `Tlsf_Core`, `Free_Bytes`, `Heap_Size` and `Invariants_Hold`. The heap is set up by the first call. A request that `Heap_Guard` refuses returns null; `malloc (0)` too; `calloc` zeroes outside the lock. |
| `mpfs_heap_lock.ad[sb]` | The lock, see below. |

**Both symbols stay.** libgcc's unwinder calls `malloc` and `free` by name at the first raise (it sorts the frame
descriptions; see "Zero-cost exceptions"), and `System.Memory` calls them. `MPFS_Heap` defines both and nothing else
does: `tests/host/rts_heap` checks that `libgnat.a` has one definition of each, in `mpfs_heap.o`, that the images of
`heap_test` and `exceptions_test` have one and none of newlib's (`_malloc_r`, `_sbrk`, ...), and `heap_test` that the
free bytes shrink at the first raise.

**The lock interface.** `MPFS_Heap_Lock` is `Acquire` (returns an opaque `Saved_State`) and `Release (State)`; every
operation of `MPFS_Heap` is one pair. The body of this single-hart runtime clears `mstatus.MIE` (`csrrci`) and sets it
again if it was set (`csrsi`), so nested pairs work and an interrupt handler may allocate; it is valid for the machine
mode of one hart. The specification is cut so that a body for several harts replaces the body only: it masks the
interrupts first, as this one does, and then takes a lock word with `amoswap.w` (or `lr.w` and `sc.w`), keeping what
`Release` needs in the state; the order (mask, then lock) means no hart waits for a lock while an interrupt handler
of the same hart waits behind it. Rules for the caller, which a body may rely on: pairs are nested, nothing between
them blocks or calls `Acquire`, and the time between them is short. This file is the only place where the lock is
implemented: `overlays/tlsf/embedded/gnat/mpfs_heap_lock.adb`.

**Where it is built.** The overlay applies to the `embedded` profile only: `gen_runtime.sh` lays `<overlay>/gnat`,
`<overlay>/gnarl` and `<overlay>/ld` over every profile and `<overlay>/<profile>/gnat`, `gnarl` and `ld` over that
profile only (`overlays/tlsf/embedded/gnat`). The key of a variant covers what lands in it, so a change to the
overlay of one profile leaves the variants of the others up to date. The units are Apache-2.0 (the ones of
`ada_esp32s3`) and GPL-3.0-or-later WITH GCC-exception-3.1 (the lock and the specification of `MPFS_Heap`), see
`PROVENANCE.md`.

**Cost.** About 3.6 KiB of code (`tlsf_core` 1.9, `mpfs_heap` 1.0, `tlsf_math` 0.4, `heap_guard` 0.2, the lock 0.1) and
6.5 KiB of `.bss` for the lists, against about 4 KiB of code and data of newlib's `malloc`.

**Checks.** `tests/host/rts_heap` runs the allocator natively with assertions on (300 000 random operations with a
content for every block, the refusals, the size classes up to 16 MiB), `tests/prove/tlsf` proves `Tlsf_Math` and
`Heap_Guard` (`./x prove`), and `examples/heap_test` runs under QEMU (random sequences, fragmentation, the limit, a
task of higher priority that allocates at the same time as the environment task, the lock, libgcc's allocations).

**Not done.** The heap is not cleared at start: the allocator writes only whole 64-bit words of its headers into
memory that was never written, and the payload belongs to the caller. Whether the LIM needs to be zeroed as a whole is
a hardware question (the Icicle Kit run of the tests). `malloc` does not return memory to the system and does not
shrink the heap area; `mallinfo` and `aligned_alloc` are not provided; a program that needs them gets newlib's, whose
allocator then defines `malloc` a second time, and the link fails loudly.

### Secondary stack

The secondary stack is the stack on which Ada returns a result whose size the caller does not know (a `String` of a
computed length, an unconstrained array). `System.Secondary_Stack` is the upstream unit and is not changed; the runtime
decides its sizes and the way an overflow ends.

| Profile | Default size of a stack | Which stacks | An overflow |
|---|---|---|---|
| `light` | 16 KiB | the environment task | `Storage_Error` raised in `SS_Allocate`, which ends in the last chance handler (the profile does not propagate exceptions) |
| `light-tasking` | 8 KiB | one for each task and for the environment task, from a static pool of the binder | the same |
| `embedded` | 16 KiB | the same | `Storage_Error`, which a handler can catch; the stack is usable again after the release of the mark |

The upstream defaults (1 MiB for `light`, 512 KiB for the others) are for targets with much memory: a few tasks would
not fit the 1920 KiB of the LIM. `gen_runtime.sh` sets `Runtime_Default_Sec_Stack_Size` in `s-parame.ads` of the variant
and stops if the pack has no such line; the table is in the script and part of the cache key. A program overrides the
default with the binder switch `-D<size>` (all stacks that have no size of their own) or the `Secondary_Stack_Size`
aspect of a task (embedded, light-tasking: `examples/secstack_test/src/secstack_worker.ads`). The binder reserves the
static pool of the stacks that have no size of their own in `.bss`: the default size for each such task and for the
environment task.

**Overflow detection** is the check of the runtime, `SS_Allocate`: a request that is larger than what is left of the
stack (`Stack.Size - Stack.Top - Mem_Request < -1`) raises `Storage_Error` before anything is written; `SS_Mark` and
`SS_Release` restore `Top`, so a stack that overflowed is usable again after the release. The check is not a
`pragma Suppress` check and stays in every build mode.

**Checks.** `examples/secstack_test` (embedded), `secstack_tasking_test` (light-tasking) and `secstack_light_test`
(light), under QEMU: the results of functions with a result of unknown size, 20 nested levels, the stack is where it
was after the statement, the bytes that can be taken before the overflow are the default of the profile (and, for a
task of `embedded`, its aspect, 4096), the overflow is `Storage_Error` or one call of the last chance handler with the
place of the raise, and the stacks of two tasks that work at the same time are independent. `tests/host/rts_heap` checks
the default in `s-parame.ads` of each variant.
## Interrupt names

`gen_intnam.py` writes `mpfs/gnarl/a-intnam.ads`, which replaces the `Ada.Interrupts.Names` of the pack (it is a port unit like the others, laid over the pack by `gen_runtime.sh`). The file is generated and committed; the hand-written names of the upstream unit (`L2_Cache_Metadata_Correction`, `Bus_Error_Unit_Hart_0`, ...) are gone.

| Part | Source | Content |
|---|---|---|
| PLIC sources | the `<interrupt>` elements of the merged SVD (`build/svd/PolarfireSoC.svd`, made current with `tools/svd.py ensure`; the SVD takes them from `svd/additions/interrupts.yaml`) | one constant of type `Interrupt_ID` per source, named as in the SVD (`MMUART0`, `E51_BUS_ERROR_UNIT`, ...) with the PLIC source number as value: 185 names for 1 .. 186. Source 117 is reserved or spare in the TRM (Table 5-1, Routing of Interrupts to Processor Cores): it has no name and no constant, but it is inside `Interrupt_Range`, so the number 117 is an `Interrupt_ID`. An `Interrupt_ID` is what the claim register returns, so a name is what `Attach_Handler` takes. |
| Hart-local interrupts | `svd/additions/local_interrupts.yaml` | the nested package `Ada.Interrupts.Names.Local`: one constant per name of type `Local_Interrupt` (`range 0 .. 47`), the number being the local interrupt number (`mcause` is `Mcause_Offset` = 16 plus the number). The type is not an `Interrupt_ID` and cannot be passed as one (a test compiles that and expects the error): a local interrupt is not a PLIC source, the same number means different interrupts on the E51 and the U54 cores, and the PLIC ids and the local numbers overlap. The comment of a name lists the harts that have it and the PLIC source that the same event also raises. |

`Interrupt_Range` of `System.BB.Parameters` (`crates/bb-runtimes/src/s-bbpara__polarfiresoc.ads`, `1 .. 186`) is the range of the PLIC sources and nothing else. The generator refuses to run if the range in that file is not exactly the smallest to the largest source of the SVD, and the generated package repeats the range as a `pragma Compile_Time_Error`, so a runtime whose `Interrupt_Range` and SVD differ does not build (`a-intnam.ads` is compiled into `libgnarl.a`'s library). The parameter file is not generated, because it also holds the clock and the stacks.

The names are checked as the SVD is: a name that is not an upper-case Ada identifier, an Ada reserved word, a double name or a double value, a first source other than 1, and a local interrupt with an unknown hart or an unknown PLIC source stop the generator (exit 2). The output has no time stamp and does not depend on the order of the elements. `tests/host/rts_intnam` tests the generator on fixtures, the committed file against the SVD and, with the real compiler against the runtime variant, the bounds of `Interrupt_ID` (source 0 and source 187 are rejected, 1 and 186 and the generated names are accepted).

## Interrupt priorities

The PLIC has three priority bits: a source has a level 0 .. 7 (0 means "never interrupt") and a context has a threshold 0 .. 7 (it takes a source whose level is strictly greater). `system.ads` of the tasking profiles (`light-tasking` and `embedded`: `system-xi-riscv-sifive-sfp.ads` and `-full.ads`, the files of the pack) declares exactly seven interrupt priorities, `Interrupt_Priority` = 249 .. 255 (`Nbr_Interrupt_Priority` = 7, `Max_Interrupt_Priority` = 255), above the task priorities `Priority` = 0 .. 248. They are the levels 1 .. 7 one to one, so the runtime has no `system-xi-mpfs-*.ads` of its own. The `light` profile has no tasking and no interrupt handlers of this kind.

| Ada | PLIC | Where |
|---|---|---|
| `Interrupt_Priority'First + n - 1` (n = 1 .. 7) | level n | `RISCV_PLIC.Level_Of`, `Priority_Of_Level` (the one place of the mapping) |
| a task priority (`Priority`, 0 .. 248) | level 0 | `Level_Of` clamps below `Interrupt_Priority'First` |
| the priority of an `Attach_Handler` source: the ceiling of its protected object | the level of the source (`Set_Priority`, at `Attach_Handler` through `Install_Interrupt_Handler`); read back by `Priority_Of_Interrupt` | `s-bbbosu.adb`, `s-bbripl.adb` |
| the active priority of the hart (`Set_Current_Priority`: the ceiling while a task is inside a protected object, its own priority otherwise, a task priority outside any) | the threshold of the context of the hart (`Set_Priority_Threshold`); read back as an Ada priority by `Threshold` | `s-bbripl.adb` |

So while a hart runs at the ceiling of a handler the PLIC holds back that interrupt and every one of equal or lower level, and an interrupt of a higher ceiling still comes through; at a task priority the threshold is 0 and every source with a level of 1 or more is taken. `Threshold` and `Priority_Of_Interrupt` both return Ada priorities (`Threshold` returned the raw register, so the assertion in `External_Interrupt_Trap_Handler` compared an Ada priority with a PLIC level and could never fail); `Priority_Of_Level (0)` is `Priority'Last`, the priority of a threshold of 0. The body of `s-bbripl.adb` stops the build (`pragma Compile_Time_Error`) if `Interrupt_Priority` is not exactly seven priorities wide, so a profile with another `system.ads` cannot silently shift the mapping.

`examples/interrupt_test` checks the mapping on the hart (and the generated names, see "Interrupt names"): the levels of the first and of the last interrupt priority and of a task priority, and the threshold for each of the seven interrupt priorities (read back from the register of the context and through `Threshold`) and for a task priority.

