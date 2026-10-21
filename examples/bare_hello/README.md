# bare_hello

The smallest image there is: no runtime, no binder, no elaboration code. It checks the toolchain, the
linker script, the hart gate and the ABI of both hart classes before anything bigger exists.

- `start.S` sets `gp`, `sp` and `mtvec` (a trap loop), lets only the harts of the image's mask
  continue (`__mpfs_harts_mask`, set at link time with `--defsym`: 1 for the E51, 2 for U54 hart 1),
  clears `.bss` and calls `main`.
- `src/bare_hello.adb` is `main`, written with `pragma Restrictions (No_Elaboration_Code)`. It reads
  `mhartid` and writes `bare hello E51 hart 0` or `bare hello U54 hart 1` to the transmit register of
  MMUART0 (`0x2000_0000`, polled). QEMU ignores the baud divisor, so the port is not initialised.
- `build.sh` (see `../common/bare_build.sh`): `gprbuild -c` compiles `start.S` and the Ada sources,
  `riscv64-elf-gcc -nostdlib` links them with `../common/ld/place-lim.ld` (everything in the L2 LIM). The
  light-polarfiresoc runtime is selected only for its `system.ads`; none of its units is bound or linked.

| Hart | `-march` | `-mabi` | Mask |
|---|---|---|---|
| E51 | `rv64imac_zicsr_zifencei` | `lp64` | 1 |
| U54 | `rv64imafdc_zicsr_zifencei` | `lp64d` | 2 (`--harts 1`; 4, 8, 16 for U54 harts 2 to 4) |

The ABI is in the ELF: `riscv64-elf-readelf -h -A bin-e51/bare_hello.elf` shows e_flags `0x1, RVC,
soft-float ABI` and an architecture string without `f` and `d`; the U54 image shows `0x5` and
`double-float ABI`. `metrics.golden` records both.

    ./x build bare_hello                  # E51
    ./x build bare_hello --hart u54
    ./x qemu bare_hello [--hart 1]
    ./x test qemu                         # the smoke test of all images
