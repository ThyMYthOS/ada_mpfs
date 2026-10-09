# `svd/patches/`

- **Purpose:** Per-peripheral corrections in svdtools format, one file per peripheral, named after it (mandatory header: source/status/owner). A patch for a peripheral that does not exist fails `./x svd check`. Every file must be listed in `svd/device.yaml`.
- **License:** CC-BY-4.0

Limits and open points:

- svdtools applies a device-level `_modify` (a peripheral property such as `baseAddress`) before it adds the peripherals of the base fragments, so such a patch does not change a base peripheral and is not reported. Patch registers and fields inside the peripheral (`PERIPH: _modify: REG: ...`) instead.
- svdtools rejects a `resetValue` with bits outside `resetMask`.
- `QSPIXIP.CONTROL.CLKRATE` is documented as "0: not supported, N: SPICLK = HCLK/(2*N), N from 2 to 15" while the reset value 0x1000400 sets it to 1. The files do not show which of the two is right, so it is not patched; verify on silicon with `./x svd probe QSPIXIP`.
