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
| `mpfs_rts.gpr` | Abstract project: `Runtime_Path` and `Target` from the scenario variables `MPFS_PROFILE`, `MPFS_HART`, `MPFS_CPUS`, `MPFS_PRIV` (and `MPFS_RTS_ROOT` for the root of the variants). |
| `mpfs/` | Own port units, laid over the pack by `gen_runtime.sh` (`gnat/`, `gnarl/` below it): `gnat/start.S` (P1.3), `gnat/s-bbbopa.ads`, `gnarl/s-bbripl.ad[sb]`, `gnarl/s-bbsuti.adb`, `gnarl/s-bbhart.ad[sb]` and `gnarl/s-bbricl.ad[sb]` (P1.4). `mpfs/remove.list` names the files of the pack that an own unit replaces under another name (`gnat/start-ram.S`) or that must stay out of the library (`embedded: gnat/unwind-dw2-fde-bb.c`: a line `<profile>: <path>` applies to that profile's pack only). |
| `overlays/<name>/` | Overlays, laid over the pack after the port units (`gnat/`, `gnarl/`, `ld/` below each). The directory does not exist yet. |
| `ld/` | The linker scripts (P1.3): `mpfs-memory.ld`, `place-lim.ld`, `place-scratchpad.ld`, `place-envm.ld`, `sections.ld` (the shared `SECTIONS`) and `app-sections.ld` (the empty hook of the application). `gen_runtime.sh` puts them into `ld/` of every variant. |
| `mpfs_link.gpr` | Abstract project with the link switches of an image: the placement script of the variant and the partition data as `--defsym` values (scenario variables `MPFS_PLACEMENT`, `MPFS_BOOT_ROLE`, `MPFS_HARTS`, `MPFS_APP_LD`, `MPFS_STACK_SIZE`, `MPFS_INTERRUPT_STACK_SIZE`), for the examples and tests until the partition generator (P1.12) writes the values. |
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
2. deletes the files that `mpfs/remove.list` names, lays the own port units (`mpfs/`) and then the overlays (`overlays/<name>/`, in the order of their names) over the pack: `gnat/*` and `gnarl/*` replace or add sources, `ld/*` goes to `ld/`; then the register packages the port units use (`MPFS_Registers`, `MPFS_Registers.PLIC` and `MPFS_Registers.CLINT` of `libs/mpfs_pac/src/generated`, byte for byte: an application that compiles the PAC itself has the same units, and the binder compares their checksums) go to `gnat/`: they are compiled into `libgnat.a` and are in `adainclude/`, and the PAC is their only source. The PAC is not committed, only its hash (`libs/mpfs_pac/MPFS_Registers.sha256`), like the packs: unless `--pac-dir DIR` names a directory, which is then used as it is and never generated, `gen_runtime.sh` first runs `tools/pac.sh ensure` (what `./x pac ensure` does: nothing if `libs/mpfs_pac/src/generated` has the recorded hash, otherwise a generation with the pinned svd2ada, `./x toolchain install pac`; `--check` does not generate: a missing package is "not up to date"). The pack compiles with `-gnatg`, whose style check rejects the 90-character header line of the generated files, so `gen_runtime.sh` adds `-gnatyM120` (line length 120, the other style checks stay) to the `ADAFLAGS` of the pack's `target_options.gpr`; then the linker scripts of `ld/` of this crate go to `ld/` of the variant;
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

Start, in this order: `mtvec` to the trap stub, `gp` and `sp`; `mstatus.MIE` and `mie` cleared; hart gate; `.data` copied from `__data_load` if that differs from `__data_start`; `.bss` cleared; `mstatus.FS` (U54 images); the constructor arrays (`.preinit_array`, then `.init_array`, called in order with no arguments); `main`; then `__gnat_exit`, which resets the MSS on a primary image and halts on a secondary one. A hart whose bit is clear in `__mpfs_harts_mask` is parked in `wfi`; on a primary image with `mie.MSIE` set (prepared for the release of P8), on a secondary image without it.

**Deliberate deviation (hart gate):** foreign harts are parked on every image, also on a secondary one. Step 1.3 of the work package (#44) and the reference runtime gate on the primary image only. But QEMU's reset code sends every hart to the entry point and has no hart gate of its own, so an ungated secondary image would run on all harts; on hardware only the release of the right hart reaches it and the gate costs nothing. The cost: a foreign hart reaching a secondary image has its `mtvec`, `mie` and `mstatus.MIE` written, as every hart does before the gate.

**Memory initialisation:** the LIM is ECC memory that is uninitialised at power-up, so every store of the start code and of the trap stub is a whole 64-bit word (the trap record is written with 64-bit stores only), and `start.S` clears `.bss`, the interrupt stacks and the stack of the environment task (a partial store into a never-written word is a read-modify-write of garbage; on hardware it would show as an ECC fault). `.noinit` and the heap are deliberately not cleared: whether the LIM needs zeroing as a whole is a hardware question (P1.8, P1.14).

The trap stub runs every trap until the runtime installs its own handler. It uses no stack and no `gp`, writes `mcause`, `mepc`, `mtval` (64 bit each), the magic `0x54524150` and `mhartid` (32 bit each) to the 32 bytes at `__mpfs_trap_record`, which are the last 32 bytes of the RAM region of the placement (the same place for a given partition, whatever the image; the heap stops in front of them), and halts. An image that defines `__mpfs_early_trap_hook` gets control there instead of the halt, with the address of the record in `a0`: a test seam for `examples/trap_test`, not for the runtime.

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
| `s-bbbopa.ads` | `System.BB.Board_Parameters`: the clock (1 MHz `mtime`) and the console base until P1.9. The bases and the layout of the PLIC and the CLINT are the PAC's (`MPFS_Registers.PLIC_Base`, `.CLINT_Base`), not repeated here. |
| `s-bbripl.ad[sb]` | `System.BB.RISCV_PLIC`: `Context_Of (Hart)` (hart 0 is context 0, hart n is context 2n-1: the E51 has no S mode, every U54 has M and S); enable block, threshold and claim/complete of the context. The registers are the PAC types (`ENABLE_H0_M_Registers`, `THRESHOLD_H0_M_Register`: 32 bits, `Volatile_Full_Access`) at "the address of the registers of context 0 plus context times the distance between context 0 and context 1", taken from the PAC components themselves (`Enable_Address`, `Threshold_Address` and `Claim_Address (Hart)` export them; `examples/interrupt_test` compares them with the named registers `ENABLE_H<n>_M` and so on for all five harts). One 32-bit access per register, loops per word, no aggregate: a 64-bit store to the PLIC is an error of the SoC (and of QEMU). `Initialize` resets only the own context: threshold (7 while it works, then 0), enables, an open claim. It does not clear the priorities (later `mpfs_boot` sets them statically) and does not touch the enables, thresholds or sources of other harts, which in an AMP system are theirs. |
| `s-bbricl.ad[sb]` | `System.BB.RISCV_CLINT`: `Mtime`, `Mtimecmp (Hart)` and `Set_Mtimecmp` (`0x4000 + 8 * Hart`, one 64-bit access), `MSIP (Hart)` and `Clear_MSIP (Hart)` (`4 * Hart`; for P8). |
| `s-bbsuti.adb` | `Board_Support.Time`: `Read_Clock` from `Mtime`, `Set_Alarm` and `Clear_Alarm_Interrupt` write the `mtimecmp` of the executing hart, with one 64-bit store (RV64) instead of the three-word sequence of RV32. The tick and idle logic is P1.6. |

`tools/check_plic_stores.py` disassembles objects, libraries or images with the pinned `riscv64-elf-objdump` and fails if it finds a 64-bit store (`sd`, `fsd`, `amo*.d`, `sc.d`) whose base register holds an address of the window `0x0C00_0000` .. `0x1000_0000` of the PLIC: a register is "in the window" after a `lui` into it and stays so through the arithmetic that builds an address (`addi`, `add`, `slli`, `mv`, ...), a load or `csrr` gives an ordinary value, the analysis follows the branches of a function (also the back edge of a loop) and ends at a call (limit: an address that a called function returns is not followed), and stores through `sp` are stack accesses. The real compiler does write `Enables := (others => 0)` for an array of PLIC registers with three `sd`: `tests/host/rts_plic/fixtures/aggregate.adb` is the proof, and the suite `tests/host/rts_plic` runs the check over the six runtime variants and over the images of `interrupt_test` and `tasking_test`, with assembler fixtures that must fail (constant base, base computed from a hart, base set at the end of a loop, atomic, floating-point store, edge of the window) and that must pass.

**QEMU and the harts.** The default of QEMU's `microchip-icicle-kit` has the E51 and one U54 (`-smp 2`; `info cpus` shows `CPU #0 sifive-e51` and `CPU #1 sifive-u54`). An image linked for hart 2 to 4 would be started on a machine without that hart and print nothing. `tests/qemu/run_tests.sh` and `./x qemu` pass `-smp 5`. Its PLIC has the contexts `M, MS, MS, MS, MS` (context 0 is hart 0, context 2n-1 the M mode of hart n) and its CLINT the `mtimecmp` at `0x4000 + 8 * hart`, as the SoC does; both accept 32-bit accesses to the PLIC only.

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
constants) and, if nothing else allocates, newlib's `malloc` (about 4 KiB with its data). The images are in
`metrics.golden`: `exceptions_test` 61.8 KiB (E51) and 63.1 KiB (U54) of `text` (code and constants), `unhandled_test` 48.2 and 49.5 KiB. A search
function of our own (fallback (a) of the work package) would save the 5.5 KiB of `unwind-dw2-fde.o` and the `malloc`; it is not needed to make exceptions work.

**For other work packages.**

- P1.8 (heap): libgcc calls `malloc` and `free` by name. A TLSF `s-memory` that replaces newlib's `malloc` must still
  define both symbols, or libgcc's `unwind-dw2-fde.o` does not link.
- P8 (SMP): `start.S` runs the constructor arrays on every hart that runs the image. `frame_dummy` registers once; a
  second registration of the same object corrupts libgcc's list. Only the first hart of the mask may run them.
- The switch to the v16 runtime sources (#41, section 3a): its `link-zcx.spec` still passes `--eh-frame-hdr`, its start
  code calls `__libc_init_array`. This crate's spec, `remove.list` and `start.S` replace both; `gen_runtime.sh` stops
  with a message if the pack no longer has `gnat/unwind-dw2-fde-bb.c`.
- The unhandled exception ends in `Ada.Exceptions.Last_Chance_Handler`: it prints with `System.IO` and calls
  `System.Machine_Reset.Stop` (MSS reset on a primary image). An application may define `__gnat_last_chance_handler`
  itself (`examples/exceptions_test/src/last_chance.ads`).
