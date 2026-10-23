# float_test

Floating point on both hart classes of the runtime `crates/mpfs_rts` (work package P1.5 of #41; the full `float_test` of
P1.13 adds the profiles `light-tasking` and `embedded`). Linked with the `light` runtime.

| | E51 | U54 |
|---|---|---|
| ISA and ABI | `rv64imac`, `lp64`: no FPU, every operation is a call into libgcc | `rv64imafdc`, `lp64d`: FPU, `mstatus.FS` set by `start.S` |
| `Sqrt` | the software square root of the runtime (`s-lidosq.adb`, `s-lisisq.adb`: reciprocal square root by Newton-Raphson), within 2 ulp | `fsqrt.d` and `fsqrt.s`, exact |

| Check | What it proves |
|---|---|
| `1.5 + 2.25`, `10.0 / 4.0`, `0.1 + 0.2` (the double `0.30000000000000004`), `1.0 / 3.0`, `2**53 + 1` (rounds to even), `1.5 * (-0.1) * 10.0`, all compared bit for bit | arithmetic and round to nearest even on `Long_Float` |
| the same for `Float` (`2**24 + 1`, `1.0 / 3.0`), `Long_Float (0.1 as Float)`, `Float (0.1 as Long_Float)` | single precision and the conversions between the two |
| `Integer (2.5)` and `Integer (-2.5)`, `Truncation`, `Floor`, `Ceiling` and `Rounding` of `-2.7`, `Long_Long_Integer (123456789012.0)`, `Long_Float (-7)` | the conversions and the rounding attributes (Ada rounds half away from zero) |
| `Sqrt (16.0) = 4.0`, `Sqrt (0.25) = 0.5`, `Sqrt (2.0)` as `Long_Float` and as `Float` (exact on the U54, within 2 ulp on the E51) | the square root of both hart classes |
| `'Image` of `Long_Float` (`1.5`, `-0.1`, `2.0**60`, `1.4142135623730951`) and `Float` (`3.75`, `1.0E10`, `0.1`, `Sqrt (2.0)`) | the text of the reference run (the native compiler 15.3.1 on the host) |

The expected values are the correctly rounded IEEE 754 results (bit patterns computed outside the program, `Image` texts
from a run of the native compiler); the operands are volatile, so nothing is folded at compile time.

**Measured:** the software `Sqrt (2.0)` of the E51 is `16#3FF6_A09E_667F_3BCC#`, one ulp below the correctly rounded
`...3BCD` that `fsqrt.d` gives; `Long_Float'Image` of it prints `1.41421356237309E+00`, the exact value prints
`...310E+00`. Hence the tolerance of 2 ulp on the E51 and an `Image` check of a constant instead of the square root.
`libgnat-patched` (ada-machine's software square root, a source of work package P1.11) is not needed for this test: the
square root of the runtime itself (the Ada Cert Math sources of the pack) works on the E51.

    ./x build float_test --hart e51          # bin-e51/
    ./x build float_test --hart u54          # bin-u54/
    ./x test qemu tests float_test_e51 float_test_u54

The images report as `float_test_e51` and `float_test_u54`; `console.expected` holds the `ok:` lines that both hart
classes print (the two lines that name the square root differ).
