# `svd/patches/`

- **Purpose:** Per-peripheral corrections in svdtools format, one file per peripheral, named after it (mandatory header: source/status/owner). A patch for a peripheral that does not exist fails `./x svd check`. Every file must be listed in `svd/device.yaml`.
- **License:** CC-BY-4.0
